import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:multicast_dns/multicast_dns.dart';
import '../models/peer.dart';
import 'candidate_ip_probe.dart';
import 'device_identity.dart';

/// FR-01: Hybrid peer discovery — merges mDNS (L2) and signaling server (L3)
/// results into a single peer list within 15 seconds.
class DiscoveryService {
  static const _mdnsServiceType = '_extfrtc._tcp';
  static const _discoveryTimeout = Duration(seconds: 15);
  static const _transferPort = 49152;
  static const _heartbeatInterval = Duration(seconds: 20);

  final String signalingBaseUrl;
  final String? manualIp;

  final _peers = <String, Peer>{};
  final _controller = StreamController<List<Peer>>.broadcast();

  String? _selfId;
  Timer? _heartbeatTimer;

  DiscoveryService({required this.signalingBaseUrl, this.manualIp});

  Stream<List<Peer>> get peerStream => _controller.stream;
  List<Peer> get currentPeers => List.unmodifiable(_peers.values.toList());

  // ── Self-registration ─────────────────────────────────────────

  /// Registers this device with the signaling server and starts the heartbeat
  /// timer so the entry stays alive within the server's TTL window.
  Future<void> register() async {
    try {
      _selfId = await DeviceIdentity.getOrCreate();

      final ip = await _localIp();
      final wgIp = await _wireguardIp();
      final candidateIps = await CandidateIpProbe.collect();
      if (manualIp != null && manualIp!.isNotEmpty) {
        candidateIps.add(manualIp!);
      }

      await http
          .post(
            Uri.parse('$signalingBaseUrl/peers/register'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'id': _selfId,
              'hostname': Platform.localHostname,
              'ip': ip,
              'wg_ip': wgIp ?? '',
              'platform': _platformLabel(),
              'client': 'ExtFRTC App',
              'candidate_ips': candidateIps,
              'port': _transferPort,
            }),
          )
          .timeout(const Duration(seconds: 5));

      _startHeartbeat();
    } catch (_) {
      // Registration failed — discovery still works in L2-only mode
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) async {
      final id = _selfId;
      if (id == null) return;
      try {
        await http
            .post(
              Uri.parse('$signalingBaseUrl/peers/heartbeat'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'id': id}),
            )
            .timeout(const Duration(seconds: 5));
      } catch (_) {}
    });
  }

  // ── Discovery ─────────────────────────────────────────────────

  /// Runs one full discovery round (mDNS + signaling in parallel).
  /// FR-01 target: complete within 15 seconds.
  Future<void> discover() async {
    _peers.clear();
    await Future.wait([
      _discoverViaMdns(),
      _discoverViaSignaling(),
    ]).timeout(_discoveryTimeout, onTimeout: () => []);
    _emit();
  }

  Future<void> _discoverViaMdns() async {
    final client = MDnsClient();
    try {
      await client.start();

      await for (final ptr in client
          .lookup<PtrResourceRecord>(
            ResourceRecordQuery.serverPointer(_mdnsServiceType),
          )
          .timeout(const Duration(seconds: 10))) {
        await for (final srv in client
            .lookup<SrvResourceRecord>(
              ResourceRecordQuery.service(ptr.domainName),
            )
            .timeout(const Duration(seconds: 3))) {
          await for (final ip in client
              .lookup<IPAddressResourceRecord>(
                ResourceRecordQuery.addressIPv4(srv.target),
              )
              .timeout(const Duration(seconds: 3))) {
            final peer = Peer(
              id: srv.target,
              hostname: srv.target,
              ip: ip.address.address,
              port: srv.port,
            );
            if (peer.id == _selfId) continue;
            _peers[peer.id] = peer;
          }
        }
      }
    } finally {
      client.stop();
    }
  }

  Future<void> _discoverViaSignaling() async {
    try {
      final res = await http
          .get(Uri.parse('$signalingBaseUrl/peers'))
          .timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final list = jsonDecode(res.body) as List<dynamic>;
        for (final item in list) {
          final peer = Peer.fromJson(item as Map<String, dynamic>);
          if (peer.id == _selfId) continue; // 자기 자신은 목록에서 제외
          final existing = _peers[peer.id];
          if (existing != null) {
            _peers[peer.id] = existing.copyWith(
              hostname: peer.hostname,
              wgIp: (peer.wgIp != null && peer.wgIp!.isNotEmpty) ? peer.wgIp : existing.wgIp,
              port: peer.port != 0 ? peer.port : existing.port,
              platform: peer.platform,
              client: peer.client,
            );
          } else {
            _peers[peer.id] = peer;
          }
        }
      }
    } catch (_) {
      // Signaling server unreachable — L2-only mode continues
    }
  }

  // ── Network helpers ───────────────────────────────────────────

  /// Returns the first non-loopback IPv4 address of this device.
  Future<String> _localIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return '127.0.0.1';
  }

  /// Returns the WireGuard virtual IP (wg* interface) if present.
  Future<String?> _wireguardIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        if (iface.name.startsWith('wg')) {
          return iface.addresses.firstOrNull?.address;
        }
      }
    } catch (_) {}
    return null;
  }

  void _emit() => _controller.add(currentPeers);

  String _platformLabel() {
    switch (Platform.operatingSystem) {
      case 'windows':
        return 'Windows';
      case 'android':
        return 'Android';
      case 'ios':
        return 'iOS';
      case 'macos':
        return 'macOS';
      case 'linux':
        return 'Linux';
      default:
        return Platform.operatingSystem;
    }
  }

  void dispose() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    // Best-effort unregister on exit (fire-and-forget)
    final id = _selfId;
    _selfId = null;
    if (id != null) {
      http
          .delete(Uri.parse('$signalingBaseUrl/peers/$id'))
          .timeout(const Duration(seconds: 5))
          .catchError((_) {});
    }
    _controller.close();
  }
}
