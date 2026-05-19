import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

import 'package:http/http.dart' as http;
import '../models/peer.dart';
import 'candidate_ip_probe.dart';
import 'device_identity.dart';

/// Web-compatible peer discovery — HTTP signaling server only.
/// mDNS (L2) is not available in the browser (no raw socket access).
class DiscoveryService {
  static const _discoveryTimeout = Duration(seconds: 15);
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

  /// Registers this browser session with the signaling server.
  /// Calls GET /myip first so the server's perspective of this client's IP
  /// is embedded in the registration body — browsers cannot read their own
  /// network interface addresses, but the server sees the source IP of each
  /// HTTP request and can reflect it back.
  Future<void> register() async {
    try {
      _selfId = await DeviceIdentity.getOrCreate();

      final ip = await _fetchMyIp();
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
              'hostname': _browserHostLabel(),
              'ip': ip,
              'wg_ip': '',
              'platform': _detectPlatform(),
              'client': _detectBrowser(),
              'candidate_ips': candidateIps,
              // 49160: web-client sentinel — no TCP server is bound at this
              // port; a value in the 40000s is used so peer parsing treats
              // this as a valid (non-zero) port and shows the peer in the list.
              'port': 49160,
            }),
          )
          .timeout(const Duration(seconds: 5));

      _startHeartbeat();
    } catch (_) {}
  }

  /// Asks the signaling server what IP it sees for this connection.
  Future<String> _fetchMyIp() async {
    try {
      final res = await http
          .get(Uri.parse('$signalingBaseUrl/myip'))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        return (body['ip'] as String?) ?? '';
      }
    } catch (_) {}
    return '';
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

  /// Runs one discovery round via the signaling server.
  Future<void> discover() async {
    _peers.clear();
    await _discoverViaSignaling().timeout(_discoveryTimeout, onTimeout: () {});
    _emit();
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
          if (peer.id == _selfId) continue; // 자기 자신 제외
          _peers.putIfAbsent(peer.id, () => peer);
        }
      }
    } catch (_) {
      // Signaling server unreachable
    }
  }

  void _emit() => _controller.add(currentPeers);

  String _browserHostLabel() {
    final browser = _detectBrowser();
    return '$browser-${_selfId!.substring(0, 8)}';
  }

  String _detectBrowser() {
    final ua = html.window.navigator.userAgent.toLowerCase();
    if (ua.contains('fxios') || ua.contains('firefox')) return 'Firefox';
    if (ua.contains('edgios') || ua.contains('edg/')) return 'Edge';
    if (ua.contains('crios') || (ua.contains('chrome') && !ua.contains('edg/'))) {
      return 'Chrome';
    }
    if (ua.contains('safari') && !ua.contains('chrome') && !ua.contains('crios')) {
      return 'Safari';
    }
    return 'Browser';
  }

  String _detectPlatform() {
    final ua = html.window.navigator.userAgent.toLowerCase();
    if (ua.contains('iphone') || ua.contains('ipad')) return 'iOS';
    if (ua.contains('android')) return 'Android';
    if (ua.contains('windows')) return 'Windows';
    if (ua.contains('mac os x') || ua.contains('macintosh')) return 'macOS';
    if (ua.contains('linux')) return 'Linux';
    return 'Web';
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
