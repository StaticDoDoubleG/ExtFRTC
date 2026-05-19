import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/peer.dart';
import '../utils/hash_util.dart';
import 'device_identity.dart';

/// Wire protocol over RTCDataChannel:
///
///   Sender → Receiver  text:   {"type":"header","filename":"...","size":N,"sha256":"..."}
///   Sender → Receiver  binary: <raw chunk> × N  (16 KB each)
///   Sender → Receiver  text:   {"type":"done"}
///   Receiver → Sender  text:   {"type":"ack","sha256":"...","ok":true|false}
///
/// Signaling (small JSON only, via WebSocket to server):
///
///   {"type":"join","id":"<self-id>"}
///   {"type":"offer","from":"A","to":"B","sdp":"...","sdpType":"offer"}
///   {"type":"answer","from":"B","to":"A","sdp":"...","sdpType":"answer"}
///   {"type":"ice","from":"A","to":"B","candidate":{...}}

const _chunkSize = 16 * 1024;

/// Wait until the SCTP send buffer has drained.
Future<void> _drainOutbound(RTCDataChannel dc) async {
  try {
    for (var i = 0; i < 30000; i++) {
      final pending = await dc.getBufferedAmount();
      if (pending == null || pending <= 0) return;
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  } catch (e) {
    dev.log('Error draining outbound: $e');
  }
}

/// Avoid growing the send queue without bound.
Future<void> _backpressure(RTCDataChannel dc, {int maxPending = 256 * 1024}) async {
  try {
    for (var i = 0; i < 30000; i++) {
      final pending = await dc.getBufferedAmount();
      if (pending == null || pending < maxPending) return;
      await Future<void>.delayed(const Duration(milliseconds: 4));
    }
  } catch (e) {
    dev.log('Error in backpressure: $e');
  }
}

class TransferService {
  final String signalingBaseUrl;
  final String? manualIp;

  String? _selfId;
  WebSocketChannel? _ws;
  bool _disposed = false;
  bool _isConnecting = false;
  int _connectionEpoch = 0;
  DateTime? _lastPongAt;
  Completer<void>? _signalingReady;
  String? _selfLabel;
  String? _selfIpAddress;

  void Function(String fileName, Uint8List data)? _onReceived;
  void Function(String text)? _onClipboardReceived;
  Future<bool> Function(String fromName, String fileName, int size)? _onTransferRequest;
  List<String>? Function(String peerId)? _onResolvePeerIp;

  final _outbound = <String, _OutboundSession>{};
  final _inbound = <String, _InboundSession>{};
  final _pendingRequests = <String, Completer<bool>>{};
  final _pendingIceCandidates = <String, List<RTCIceCandidate>>{};

  // Debug log stream
  final _logController = StreamController<String>.broadcast();
  Stream<String> get logStream => _logController.stream;

  void _log(String msg) {
    dev.log(msg);
    _logController.add('${DateTime.now().toString().split(' ').last} $msg');
  }

  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  StreamSubscription<dynamic>? _wsSubscription;
  String? _activeWsUrl;
  Map<String, dynamic> _iceConfig = _defaultIceConfig();

  TransferService({required this.signalingBaseUrl, this.manualIp});

  Future<void> startServer({
    required void Function(String fileName, Uint8List data) onReceived,
    void Function(String text)? onClipboardReceived,
    Future<bool> Function(String fromName, String fileName, int size)? onTransferRequest,
    List<String>? Function(String peerId)? onResolvePeerIp,
  }) async {
    _disposed = false;
    _onReceived = onReceived;
    _onClipboardReceived = onClipboardReceived;
    _onTransferRequest = onTransferRequest;
    _onResolvePeerIp = onResolvePeerIp;
    _selfId = await DeviceIdentity.getOrCreate();
    _selfLabel = 'peer-${_selfId!.substring(0, 8)}';
    _log('[Transfer] Starting server with ID: $_selfId');
    await _loadRtcConfig();
    await _connectSignaling();
  }

  Future<void> stopServer() async {
    _log('[Transfer] Stopping server');
    _disposed = true;
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _wsSubscription?.cancel();
    _wsSubscription = null;
    try {
      await _ws?.sink.close();
    } catch (_) {}
    _ws = null;
    for (final s in _inbound.values) {
      await s.close();
    }
    for (final s in _outbound.values) {
      await s.close();
    }
    _inbound.clear();
    _outbound.clear();
    for (final pending in _pendingRequests.values) {
      if (!pending.isCompleted) {
        pending.complete(false);
      }
    }
    _pendingRequests.clear();
  }

  Future<void> _connectSignaling() async {
    if (_disposed || _isConnecting) return;
    _isConnecting = true;
    _selfId ??= await DeviceIdentity.getOrCreate();
    _selfLabel ??= 'peer-${_selfId!.substring(0, 8)}';

    _connectionEpoch++;
    final epoch = _connectionEpoch;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    await _wsSubscription?.cancel();
    _wsSubscription = null;

    try {
      await _ws?.sink.close();
    } catch (_) {}
    _ws = null;
    _heartbeatTimer?.cancel();
    _signalingReady = Completer<void>();

    final wsUrl = _buildSignalingWsUrl(signalingBaseUrl);
    if (wsUrl == null) {
      _log('[Transfer] Invalid signaling base URL: "$signalingBaseUrl"');
      final ready = _signalingReady;
      if (ready != null && !ready.isCompleted) {
        ready.completeError(ArgumentError('invalid signaling URL'));
      }
      _ws = null;
      _scheduleReconnect();
      _isConnecting = false;
      return;
    }

    await _probeSignalingHttp();

    _log('[Transfer] Connecting to signaling at $wsUrl');
    _activeWsUrl = wsUrl;

    try {
      final channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      _ws = channel;
      _lastPongAt = DateTime.now();

      _wsSubscription = channel.stream.listen(
        _onMessage,
        onError: (e) {
          if (epoch != _connectionEpoch) return;
          _log('[Transfer] Signaling error (${e.runtimeType}) on $_activeWsUrl: $e');
          final ready = _signalingReady;
          if (ready != null && !ready.isCompleted) {
            ready.completeError(e);
          }
          _ws = null;
          _scheduleReconnect();
        },
        onDone: () {
          if (epoch != _connectionEpoch) return;
          _log('[Transfer] Signaling connection closed on $_activeWsUrl');
          if (!(_signalingReady?.isCompleted ?? true)) {
            _signalingReady?.completeError(StateError('signaling closed'));
          }
          _ws = null;
          _scheduleReconnect();
        },
        cancelOnError: true,
      );

      final joinMsg = {'type': 'join', 'id': _selfId};
      if (manualIp != null && manualIp!.isNotEmpty) {
        joinMsg['manualIp'] = manualIp!;
      }
      channel.sink.add(jsonEncode(joinMsg));
      _startHeartbeat();
    } catch (e) {
      if (epoch == _connectionEpoch) {
        _log('[Transfer] Signaling connection failed (${e.runtimeType}) on $wsUrl: $e');
        final ready = _signalingReady;
        if (ready != null && !ready.isCompleted) {
          ready.completeError(e);
        }
        _ws = null;
        _scheduleReconnect();
      }
    } finally {
      _isConnecting = false;
    }
  }

  Future<void> _ensureSignalingReady() async {
    if (_disposed) {
      throw StateError('transfer service stopped');
    }
    if (_ws == null) {
      await _connectSignaling();
    }
    final ready = _signalingReady;
    if (ready == null) {
      throw StateError('signaling is not initialized');
    }
    await ready.future.timeout(const Duration(seconds: 10));

    // Pre-fetch and cache self IP asynchronously if not already cached
    if (_selfIpAddress == null) {
      _fetchSelfIp().then((ip) {
        if (ip.isNotEmpty) {
          _selfIpAddress = ip;
          _log('[Transfer] Cached self IP on startup: $_selfIpAddress');
        }
      }).catchError((_) {});
    }
  }

  Future<void> _probeSignalingHttp() async {
    var normalized = signalingBaseUrl.trim();
    if (normalized.isEmpty) return;
    if (!normalized.startsWith('http://') && !normalized.startsWith('https://')) {
      normalized = 'http://$normalized';
    }

    final uri = Uri.tryParse(normalized);
    if (uri == null || uri.host.isEmpty) return;
    final pingUri = uri.replace(path: '/myip', query: null, fragment: null);

    try {
      final res = await http.get(pingUri).timeout(const Duration(seconds: 2));
      _log('[Transfer] HTTP probe $pingUri => ${res.statusCode}');
    } catch (e) {
      _log('[Transfer] HTTP probe failed $pingUri (${e.runtimeType}): $e');
    }

    final wsPathUri = uri.replace(path: '/signal/ws', query: null, fragment: null);
    try {
      final res = await http.get(wsPathUri).timeout(const Duration(seconds: 2));
      final body = res.body.length > 120 ? '${res.body.substring(0, 120)}...' : res.body;
      _log('[Transfer] HTTP probe $wsPathUri => ${res.statusCode} body="$body"');
      if (res.statusCode == 404) {
        _log(
          '[Transfer] Signaling route missing on server. The running server may be an older build that does not expose /signal/ws yet.',
        );
      }
    } catch (e) {
      _log('[Transfer] HTTP probe failed $wsPathUri (${e.runtimeType}): $e');
    }
  }

  Future<void> _loadRtcConfig() async {
    var normalized = signalingBaseUrl.trim();
    if (normalized.isEmpty) return;
    if (!normalized.startsWith('http://') && !normalized.startsWith('https://')) {
      normalized = 'http://$normalized';
    }

    final uri = Uri.tryParse(normalized);
    if (uri == null || uri.host.isEmpty) return;

    final rtcConfigUri = uri.replace(path: '/rtc-config', query: null, fragment: null);
    try {
      final res = await http.get(rtcConfigUri).timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) {
        _log('[Transfer] RTC config probe $rtcConfigUri => ${res.statusCode}');
        return;
      }

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final servers = (body['iceServers'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((server) {
            final map = Map<String, dynamic>.from(server);
            final urls = map['urls'];
            return <String, dynamic>{
              'urls': urls is List ? List<String>.from(urls) : urls,
              if ((map['username'] as String?)?.isNotEmpty == true)
                'username': map['username'],
              if ((map['credential'] as String?)?.isNotEmpty == true)
                'credential': map['credential'],
            };
          })
          .toList();

      if (servers.isNotEmpty) {
        _iceConfig = {
          'iceServers': servers,
          'sdpSemantics': 'unified-plan',
        };
        _log('[Transfer] RTC config loaded with ${servers.length} ICE server entries');
      }
    } catch (e) {
      _log('[Transfer] RTC config probe failed $rtcConfigUri (${e.runtimeType}): $e');
    }
  }

  String? _buildSignalingWsUrl(String base) {
    var normalized = base.trim();
    if (normalized.isEmpty) return null;
    if (!normalized.startsWith('http://') && !normalized.startsWith('https://')) {
      normalized = 'http://$normalized';
    }
    final uri = Uri.tryParse(normalized);
    if (uri == null || uri.host.isEmpty) return null;

    final wsScheme = uri.scheme == 'https' ? 'wss' : 'ws';
    return uri
        .replace(
          scheme: wsScheme,
          path: '/signal/ws',
          query: null,
          fragment: null,
        )
        .toString();
  }

  static Map<String, dynamic> _defaultIceConfig() {
    return {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
      'sdpSemantics': 'unified-plan',
    };
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    if (_disposed) return;
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      if (_disposed) {
        timer.cancel();
        return;
      }
      final ws = _ws;
      if (ws == null) {
        timer.cancel();
        return;
      }

      final lastPong = _lastPongAt;
      if (lastPong != null &&
          DateTime.now().difference(lastPong) > const Duration(seconds: 45)) {
        _log('[Transfer] Heartbeat timeout, reconnecting signaling');
        _ws = null;
        timer.cancel();
        _scheduleReconnect();
        return;
      }

      try {
        ws.sink.add(jsonEncode({'type': 'ping'}));
      } catch (e) {
        _log('[Transfer] Heartbeat failed: $e');
        _ws = null;
        timer.cancel();
        _scheduleReconnect();
      }
    });
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    if (_reconnectTimer?.isActive == true) return;
    _reconnectTimer = Timer(const Duration(seconds: 2), () async {
      _reconnectTimer = null;
      if (!_disposed && _ws == null) {
        await _connectSignaling();
      }
    });
  }

  void _signal(Map<String, dynamic> msg) {
    final ws = _ws;
    if (ws == null) {
      _log('[Transfer] Cannot signal, WebSocket is null');
      return;
    }
    try {
      ws.sink.add(jsonEncode(msg));
    } catch (e) {
      _log('[Transfer] Signaling send failed: $e');
      _ws = null;
      _scheduleReconnect();
    }
  }

  void _logCandidate(String prefix, RTCIceCandidate candidate) {
    final raw = candidate.candidate ?? '';
    final type = _extractCandidateType(raw);
    if (type == null) return;
    _log('[Transfer] $prefix ICE candidate type: $type');
  }

  String? _extractCandidateType(String raw) {
    final match = RegExp(r'\btyp\s+([a-zA-Z0-9]+)\b').firstMatch(raw);
    return match?.group(1);
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    late final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final type = msg['type'] as String?;
    final from = msg['from'] as String? ?? '';
    _log('[Transfer] Signaling msg: $type from $from');
    _lastPongAt = DateTime.now();

    switch (type) {
      case 'joined':
        final ready = _signalingReady;
        if (ready != null && !ready.isCompleted) {
          ready.complete();
        }
        return;
      case 'pong':
        _lastPongAt = DateTime.now();
        return;
      case 'error':
        _log('[Transfer] Signaling server error: ${msg['error']}');
        return;
      case 'request':
        _handleRequest(msg, from);
        return;
      case 'accept':
        _pendingRequests[from]?.complete(true);
        _pendingRequests.remove(from);
        return;
      case 'decline':
        _pendingRequests[from]?.complete(false);
        _pendingRequests.remove(from);
        return;
      case 'offer':
        final resolved = _onResolvePeerIp?.call(from);
        final senderIp = (resolved != null && resolved.isNotEmpty) ? resolved.first : msg['senderIp'] as String?;
        if (senderIp != null && senderIp.isNotEmpty) {
          final sdp = msg['sdp'] as String?;
          if (sdp != null) {
            msg['sdp'] = sdp.replaceAll(RegExp(r'[a-zA-Z0-9-]+\.local'), senderIp);
          }
        }
        _handleOffer(msg, from);
        return;
      case 'answer':
        final resolved = _onResolvePeerIp?.call(from);
        final senderIp = (resolved != null && resolved.isNotEmpty) ? resolved.first : msg['senderIp'] as String?;
        if (senderIp != null && senderIp.isNotEmpty) {
          final sdp = msg['sdp'] as String?;
          if (sdp != null) {
            msg['sdp'] = sdp.replaceAll(RegExp(r'[a-zA-Z0-9-]+\.local'), senderIp);
          }
        }
        _outbound[from]?.resolveAnswer(RTCSessionDescription(
          msg['sdp'] as String?,
          msg['sdpType'] as String? ?? 'answer',
        ));
        return;
      case 'ice':
        final c = _parseCandidate(msg['candidate']);
        if (c != null) {
          _logCandidate('Remote', c);
          final outSession = _outbound[from];
          final inSession = _inbound[from];
          
          if (outSession == null && inSession == null) {
            _log('[Transfer] Session not ready for $from, queueing ICE candidate');
            _pendingIceCandidates.putIfAbsent(from, () => []).add(c);
            
            final resolved = _onResolvePeerIp?.call(from);
            final ips = <String>[
              if (resolved != null) ...resolved,
              if (msg['senderIp'] != null) msg['senderIp'] as String,
            ];
            final raw = c.candidate;
            if (raw != null && raw.contains('.local') && ips.isNotEmpty) {
              final uniqueIps = ips.where((ip) => ip.isNotEmpty).toSet().toList();
              for (final ip in uniqueIps) {
                final patchedRaw = raw.replaceAll(RegExp(r'[a-zA-Z0-9-]+\.local'), ip);
                final patchedC = RTCIceCandidate(patchedRaw, c.sdpMid, c.sdpMLineIndex);
                _pendingIceCandidates[from]!.add(patchedC);
              }
            }
            return;
          }

          outSession?.addCandidate(c);
          inSession?.addCandidate(c);

          final knownTargetIp = outSession?.targetIp ?? inSession?.targetIp;
          final resolved = _onResolvePeerIp?.call(from);
          final ips = <String>[
            if (knownTargetIp != null && knownTargetIp.isNotEmpty) knownTargetIp,
            if (resolved != null) ...resolved,
            if (msg['senderIp'] != null) msg['senderIp'] as String,
          ];
          final raw = c.candidate;
          if (raw != null && raw.contains('.local') && ips.isNotEmpty) {
            final uniqueIps = ips.where((ip) => ip.isNotEmpty).toSet().toList();
            for (final ip in uniqueIps) {
              final patchedRaw = raw.replaceAll(RegExp(r'[a-zA-Z0-9-]+\.local'), ip);
              final patchedC = RTCIceCandidate(patchedRaw, c.sdpMid, c.sdpMLineIndex);
              _logCandidate('Remote (Patched IP: $ip)', patchedC);
              outSession?.addCandidate(patchedC);
              inSession?.addCandidate(patchedC);
            }
          }
        }
        return;
      case 'relay_fallback':
        final relayId = msg['relayId'] as String?;
        final fileName = msg['fileName'] as String?;
        final fileSize = msg['size'] as int? ?? 0;
        if (relayId != null && fileName != null) {
          _log('[Transfer] WebRTC failed, falling back to Server Relay for $fileName');
          _downloadViaRelay(relayId, fileName, fileSize);
        }
        return;
      default:
        return;
    }
  }

  RTCIceCandidate? _parseCandidate(dynamic raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    
    // Handle potential nulls or type mismatches in candidate map
    final candidate = m['candidate'] as String?;
    final sdpMid = m['sdpMid'] as String?;
    final idx = m['sdpMLineIndex'];
    
    int? mLineIndex;
    if (idx is int) {
      mLineIndex = idx;
    } else if (idx is num) {
      mLineIndex = idx.toInt();
    }
    
    if (candidate == null) return null;
    
    return RTCIceCandidate(candidate, sdpMid, mLineIndex);
  }

  Future<void> _handleRequest(Map<String, dynamic> msg, String from) async {
    final fileName = msg['fileName'] as String? ?? 'Unknown file';
    final fileSize = msg['size'] as int? ?? 0;
    final fromName = msg['fromName'] as String? ?? 'Unknown Device';
    final aliasId = msg['to'] as String?;

    _log('[Transfer] Incoming request from $fromName ($from) for $fileName');

    final accepted = await _onTransferRequest?.call(fromName, fileName, fileSize) ?? false;

    _signal({
      'type': accepted ? 'accept' : 'decline',
      'from': aliasId ?? _selfId,
      'to': from,
    });
  }

  Future<void> _handleOffer(Map<String, dynamic> msg, String from) async {
    if (from.isEmpty) return;
    _log('[Transfer] Handling offer from $from');
    final aliasId = msg['to'] as String?;

    final stale = _inbound.remove(from);
    if (stale != null) {
      await stale.close();
    }

    final pc = await createPeerConnection(_iceConfig);
    final resolved = _onResolvePeerIp?.call(from);
    final targetIp = (resolved != null && resolved.isNotEmpty) ? resolved.first : msg['senderIp'] as String?;
    final session = _InboundSession(
      pc: pc,
      targetIp: targetIp,
    );
    _inbound[from] = session;

    final pendingIce = _pendingIceCandidates.remove(from);
    if (pendingIce != null) {
      _log('[Transfer] Draining ${pendingIce.length} queued ICE candidates for $from');
      for (final c in pendingIce) {
        session.addCandidate(c);
      }
    }

    pc.onConnectionState = (state) {
      _log('[Transfer] Inbound PC state from $from: $state');
    };
    pc.onIceConnectionState = (state) {
      _log('[Transfer] Inbound ICE state from $from: $state');
    };

    pc.onIceCandidate = (c) {
      _logCandidate('Inbound local', c);
      _signal({
        'type': 'ice',
        'from': aliasId ?? _selfId,
        'to': from,
        'candidate': c.toMap(),
      });
    };

    pc.onDataChannel = (dc) {
      _log('[Transfer] Data channel received from $from');
      session.attachDataChannel(
        dc,
        _onReceived,
        () async {
          _inbound.remove(from);
          await session.close();
        },
        onClipboardReceived: _onClipboardReceived,
        logger: _log,
      );
    };

    try {
      await pc.setRemoteDescription(RTCSessionDescription(
        msg['sdp'] as String?,
        msg['sdpType'] as String? ?? 'offer',
      ));
      await session.flushCandidates();

      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);

      _signal({
        'type': 'answer',
        'from': aliasId ?? _selfId,
        'to': from,
        'sdp': answer.sdp,
        'sdpType': answer.type,
      });
    } catch (e) {
      _log('[Transfer] Error handling offer: $e');
      await session.close();
      _inbound.remove(from);
    }
  }

  Future<bool> sendFile(Peer peer, String fileName, Uint8List data, {void Function(String)? onStatusUpdate}) async {
    _log('[Transfer] === STARTING TRANSFER ===');
    _log('[Transfer] File: $fileName (${data.length} bytes)');
    _log('[Transfer] Target Peer Info -> ID: "${peer.id}", IP: "${peer.ip}", wgIp: "${peer.wgIp ?? ''}"');
    _log('[Transfer] My VPN Manual IP: "${manualIp ?? ''}"');
    
    onStatusUpdate?.call('Checking network routing barriers...');

    _selfId ??= await DeviceIdentity.getOrCreate();
    _selfLabel ??= 'peer-${_selfId!.substring(0, 8)}';
    await _ensureSignalingReady();

    // 🌟 1. Strict subnet check for proactive Server Relay (Pre-empts and bypasses all signaling & WebRTC)
    bool forceRelay = false;
    _log('[Transfer] Checking routing barriers for P2P... (manualIp is "${manualIp ?? ''}")');
    if (manualIp == null || manualIp!.isEmpty) {
      try {
        final selfIp = _selfIpAddress ?? await _fetchSelfIp();
        
        final senderClass = _classifyIp(selfIp);
        final receiverClass = (peer.wgIp != null && peer.wgIp!.isNotEmpty)
            ? _classifyIp(peer.wgIp!)
            : _classifyIp(peer.ip);

        // Sender is LOCAL if their IP is LOCAL, or if selfIp is empty (we assume local)
        final isSenderLocal = selfIp.isEmpty || senderClass == 'LOCAL';

        // Receiver is VPN if wgIp or ip is VPN
        final isReceiverVpn = (peer.wgIp != null && peer.wgIp!.isNotEmpty && _isVpnAddress(peer.wgIp!)) ||
                              _isVpnAddress(peer.ip);

        // Server Relay is ONLY forced when we are Local -> VPN!
        final isLocalToVpn = isSenderLocal && isReceiverVpn;

        _log('[Transfer] PROACTIVE EVALUATION DETAILS:\n'
             '  - Sender IP: "$selfIp" (Class: $senderClass, isSenderLocal: $isSenderLocal)\n'
             '  - Receiver IP: "${peer.ip}", VPN IP: "${peer.wgIp ?? ''}" (Class: $receiverClass, isReceiverVpn: $isReceiverVpn)\n'
             '  - Is Local-to-VPN (FORCED RELAY CRITERIA): $isLocalToVpn');

        if (isLocalToVpn) {
          _log('[Harness] [Relay] DECISION: Local-to-VPN transfer detected! Bypassing WebRTC and forcing Server Relay immediately!');
          forceRelay = true;
        } else {
          _log('[Transfer] DECISION: Not a Local-to-VPN transfer (VPN-to-Local or same subnet). Bypassing Server Relay, allowing standard WebRTC.');
        }
      } catch (e) {
        _log('[Transfer] Error doing strict proactive routing check: $e. Proceeding with WebRTC check.');
      }
    } else {
      _log('[Transfer] DECISION: VPN Manual IP is configured ("$manualIp"). Skipping routing check, assuming P2P works.');
    }

    _log('[Transfer] final forceRelay value: $forceRelay');

    if (forceRelay) {
      onStatusUpdate?.call('Local -> VPN barrier detected. Forcing Server Relay...');
      _log('[Transfer] Routing match detected! Bypassing the WebRTC request flow completely and starting Server Relay upload.');
      return await _sendFileViaRelay(peer, fileName, data, onStatusUpdate);
    }

    onStatusUpdate?.call('P2P path approved. Requesting permission...');

    // 🌟 2. Step 1: Send Request (Standard WebRTC flow for compatible peers)
    final requestCompleter = Completer<bool>();
    _pendingRequests[peer.id] = requestCompleter;

    _signal({
      'type': 'request',
      'from': _selfId,
      'fromName': _selfLabel,
      'to': peer.id,
      'fileName': fileName,
      'size': data.length,
    });

    try {
      final accepted = await requestCompleter.future.timeout(const Duration(seconds: 60));
      _log('[Harness] Sender received transfer response from ${peer.id}: accepted=$accepted');
      if (!accepted) {
        _log('[Transfer] Request declined by ${peer.id}');
        return false;
      }
    } catch (e) {
      _log('[Transfer] Request timed out or failed: $e');
      _pendingRequests.remove(peer.id);
      return false;
    }

    // Step 2: Proceed with WebRTC
    _log('[Transfer] Request accepted, starting WebRTC for $fileName');
    onStatusUpdate?.call('Request accepted. Establishing WebRTC connection...');

    RTCPeerConnection? pc;
    try {
      pc = await createPeerConnection(_iceConfig);
      final dc = await pc.createDataChannel(
        'file',
        RTCDataChannelInit()..ordered = true,
      );
      dc.bufferedAmountLowThreshold = 256 * 1024;

      final session = _OutboundSession(pc: pc, targetIp: peer.transferAddress);
      _outbound[peer.id] = session;

      pc.onConnectionState = (state) {
        _log('[Transfer] Outbound PC state to ${peer.id}: $state');
      };
      pc.onIceConnectionState = (state) {
        _log('[Transfer] Outbound ICE state to ${peer.id}: $state');
      };

      pc.onIceCandidate = (c) {
        _logCandidate('Outbound local', c);
        _signal({
          'type': 'ice',
          'from': _selfId,
          'to': peer.id,
          'candidate': c.toMap(),
        });
      };

      final dcOpen = Completer<void>();
      final ackCompleter = Completer<bool>();

      dc.onDataChannelState = (state) {
        _log('[Transfer] Data channel state: $state');
        if (state == RTCDataChannelState.RTCDataChannelOpen &&
            !dcOpen.isCompleted) {
          dcOpen.complete();
        }
      };

      dc.onMessage = (msg) {
        if (!msg.isBinary && !ackCompleter.isCompleted) {
          try {
            final frame = jsonDecode(msg.text ?? '') as Map<String, dynamic>;
            if (frame['type'] == 'ack') {
              _log('[Transfer] Received ACK: ${frame['ok']}');
              ackCompleter.complete(frame['ok'] == true);
            }
          } catch (_) {}
        }
      };

      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);

      _signal({
        'type': 'offer',
        'from': _selfId,
        'to': peer.id,
        'sdp': offer.sdp,
        'sdpType': offer.type,
      });

      final answer =
          await session.answerFuture.timeout(const Duration(seconds: 30));
      await pc.setRemoteDescription(answer);
      await session.flushCandidates();

      await dcOpen.future.timeout(const Duration(seconds: 30));

      final hash = await HashUtil.sha256Hex(data);

      _log('[Transfer] Sending header...');
      await _backpressure(dc);
      await dc.send(RTCDataChannelMessage(jsonEncode({
        'type': 'header',
        'filename': fileName,
        'size': data.length,
        'sha256': hash,
      })));
      
      _log('[Transfer] Sending binary data (${data.length} bytes)...');
      var lastLogged = 0;
      for (var offset = 0; offset < data.length; offset += _chunkSize) {
        final end = (offset + _chunkSize).clamp(0, data.length).toInt();
        await _backpressure(dc);
        
        // Zero-copy binary chunk extraction
        final chunkLength = end - offset;
        final chunk = Uint8List.view(data.buffer, data.offsetInBytes + offset, chunkLength);
        await dc.send(RTCDataChannelMessage.fromBinary(chunk));
        
        // Periodically yield to event loop to prevent UI freezing (every 50 chunks)
        if (offset ~/ _chunkSize % 50 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        
        final progress = (offset / data.length * 100).toInt();
        if (progress >= lastLogged + 5) {
          _log('[Transfer] Sending: $progress%');
          onStatusUpdate?.call('$progress% Transmitted');
          lastLogged = progress;
        }
      }
      await _drainOutbound(dc);

      _log('[Transfer] Sending done...');
      await _backpressure(dc);
      await dc.send(RTCDataChannelMessage(jsonEncode({'type': 'done'})));
      await _drainOutbound(dc);

      return await ackCompleter.future.timeout(const Duration(seconds: 60));
    } catch (e) {
      _log('[Transfer] WebRTC send failed: $e. Falling back to Server Relay...');
      onStatusUpdate?.call('WebRTC failed. Falling back to Server Relay...');
      return await _sendFileViaRelay(peer, fileName, data, onStatusUpdate);
    } finally {
      _pendingRequests.remove(peer.id);
      _outbound.remove(peer.id);
      await pc?.close();
    }
  }

  Future<bool> _sendFileViaRelay(
    Peer peer,
    String fileName,
    Uint8List data,
    void Function(String)? onStatusUpdate,
  ) async {
    final relayId = 'relay-${DateTime.now().millisecondsSinceEpoch}-${_selfId}';
    _log('[Harness] [Relay] Initiating Server Relay upload for $fileName (ID: $relayId)...');
    onStatusUpdate?.call('Uploading file to Server Relay...');

    _signal({
      'type': 'relay_fallback',
      'from': _selfId,
      'to': peer.id,
      'relayId': relayId,
      'fileName': fileName,
      'size': data.length,
    });

    try {
      final url = '$signalingBaseUrl/relay/upload?relayId=$relayId&to=${peer.id}&from=$_selfId';
      _log('[Harness] [Relay] Uploading $fileName (${data.length} bytes) to server...');
      final response = await http.post(
        Uri.parse(url),
        body: data,
      ).timeout(const Duration(minutes: 30));

      if (response.statusCode == 200) {
        _log('[Harness] [Relay] Upload to server completed successfully.');
        onStatusUpdate?.call('File transferred via Server Relay!');
        return true;
      } else {
        _log('[Harness] [Relay] Relay upload failed with status: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      _log('[Harness] [Relay] Relay upload failed: $e');
      return false;
    }
  }

  Future<void> _downloadViaRelay(String relayId, String fileName, int fileSize) async {
    final url = '$signalingBaseUrl/relay/download?relayId=$relayId';
    _log('[Harness] [Relay] Download started for $fileName (Size: $fileSize bytes) via Server Relay...');

    // Retry loop for up to 60 seconds to allow the Sender's large upload to initialize
    http.Response? response;
    for (int attempt = 1; attempt <= 60; attempt++) {
      try {
        _log('[Harness] [Relay] Attempting download (attempt $attempt/60)...');
        final res = await http.get(Uri.parse(url)).timeout(const Duration(minutes: 30));
        if (res.statusCode == 200) {
          response = res;
          break;
        } else if (res.statusCode == 404) {
          // Session not ready yet, wait and retry
          _log('[Harness] [Relay] Session not ready (404). Waiting 1 second...');
          await Future<void>.delayed(const Duration(seconds: 1));
        } else {
          _log('[Harness] [Relay] Received unexpected error code: ${res.statusCode}');
          break;
        }
      } catch (e) {
        _log('[Harness] [Relay] Download attempt error: $e');
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }

    if (response != null && response.statusCode == 200) {
      final bytes = response.bodyBytes;
      _log('[Harness] [Relay] Download completed successfully (${bytes.length} bytes). Triggering save...');
      _onReceived?.call(fileName, bytes);
    } else {
      _log('[Harness] [Relay] Relay download failed after retries.');
    }
  }

  Future<String> _fetchSelfIp() async {
    try {
      var url = signalingBaseUrl.trim();
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        url = 'http://$url';
      }
      final res = await http.get(Uri.parse('$url/myip')).timeout(const Duration(seconds: 3));
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        return (body['ip'] as String?) ?? '';
      }
    } catch (_) {}
    return '';
  }

  bool _isVpnAddress(String ip) {
    if (ip.isEmpty) return false;
    return ip.startsWith('10.') || ip.startsWith('100.');
  }

  bool _isLocalAddress(String ip) {
    if (ip.isEmpty) return false;
    return ip.startsWith('192.168.') || 
           RegExp(r'^172\.(1[6-9]|2\d|3[0-1])\.').hasMatch(ip);
  }

  String _classifyIp(String ip) {
    if (ip.isEmpty) return 'UNKNOWN';
    if (_isLocalAddress(ip)) return 'LOCAL';
    if (_isVpnAddress(ip)) return 'VPN';
    return 'UNKNOWN';
  }

  bool _areOnSameSubnet(String ip1, String ip2) {
    if (ip1.isEmpty || ip2.isEmpty) return false;
    final parts1 = ip1.split('.');
    final parts2 = ip2.split('.');
    if (parts1.length < 3 || parts2.length < 3) return false;
    return parts1[0] == parts2[0] &&
           parts1[1] == parts2[1] &&
           parts1[2] == parts2[2];
  }

  Future<bool> sendClipboard(Peer peer, String text) async {
    _log('[Transfer] Sending clipboard text (${text.length} chars) to ${peer.id}');
    _selfId ??= await DeviceIdentity.getOrCreate();
    _selfLabel ??= 'peer-${_selfId!.substring(0, 8)}';
    await _ensureSignalingReady();

    RTCPeerConnection? pc;
    try {
      pc = await createPeerConnection(_iceConfig);
      final dc = await pc.createDataChannel(
        'clipboard',
        RTCDataChannelInit()..ordered = true,
      );

      final session = _OutboundSession(pc: pc, targetIp: peer.transferAddress);
      _outbound[peer.id] = session;

      pc.onConnectionState = (state) {
        _log('[Transfer] Clipboard PC state to ${peer.id}: $state');
      };
      pc.onIceConnectionState = (state) {
        _log('[Transfer] Clipboard ICE state to ${peer.id}: $state');
      };

      pc.onIceCandidate = (c) {
        _logCandidate('Clipboard local', c);
        _signal({
          'type': 'ice',
          'from': _selfId,
          'to': peer.id,
          'candidate': c.toMap(),
        });
      };

      final dcOpen = Completer<void>();

      dc.onDataChannelState = (state) {
        if (state == RTCDataChannelState.RTCDataChannelOpen &&
            !dcOpen.isCompleted) {
          dcOpen.complete();
        }
      };

      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);

      _signal({
        'type': 'offer',
        'from': _selfId,
        'to': peer.id,
        'sdp': offer.sdp,
        'sdpType': offer.type,
      });

      final answer =
          await session.answerFuture.timeout(const Duration(seconds: 20));
      await pc.setRemoteDescription(answer);
      await session.flushCandidates();

      await dcOpen.future.timeout(const Duration(seconds: 20));

      await dc.send(RTCDataChannelMessage(jsonEncode({
        'type': 'clipboard',
        'text': text,
      })));

      await _drainOutbound(dc);
      // Wait a bit to ensure the message is processed before closing
      await Future<void>.delayed(const Duration(milliseconds: 500));
      return true;
    } catch (e) {
      _log('[Transfer] Send clipboard failed: $e');
      return false;
    } finally {
      _outbound.remove(peer.id);
      await pc?.close();
    }
  }
}

class _OutboundSession {
  final RTCPeerConnection pc;
  final String? targetIp;
  final _answerCompleter = Completer<RTCSessionDescription>();
  final _pending = <RTCIceCandidate>[];
  bool _remoteSet = false;

  _OutboundSession({required this.pc, this.targetIp});

  Future<RTCSessionDescription> get answerFuture => _answerCompleter.future;

  void resolveAnswer(RTCSessionDescription desc) {
    if (!_answerCompleter.isCompleted) _answerCompleter.complete(desc);
  }

  void addCandidate(RTCIceCandidate c) {
    if (_remoteSet) {
      pc.addCandidate(c);
    } else {
      _pending.add(c);
    }
  }

  Future<void> flushCandidates() async {
    _remoteSet = true;
    for (final c in _pending) {
      await pc.addCandidate(c);
    }
    _pending.clear();
  }

  Future<void> close() => pc.close();
}

class _InboundSession {
  final RTCPeerConnection pc;
  final String? targetIp;
  final _pending = <RTCIceCandidate>[];
  bool _remoteSet = false;

  _InboundSession({required this.pc, this.targetIp});

  void addCandidate(RTCIceCandidate c) {
    if (_remoteSet) {
      pc.addCandidate(c);
    } else {
      _pending.add(c);
    }
  }

  Future<void> flushCandidates() async {
    _remoteSet = true;
    for (final c in _pending) {
      await pc.addCandidate(c);
    }
    _pending.clear();
  }

  void attachDataChannel(
    RTCDataChannel dc,
    void Function(String, Uint8List)? onReceived,
    Future<void> Function() release, {
    void Function(String)? onClipboardReceived,
    void Function(String)? logger,
  }) {
    String? fileName;
    String? expectedHash;
    var expectedSize = 0;
    final builder = BytesBuilder(copy: false);
    var released = false;

    Future<void> finish() async {
      if (released) return;
      released = true;
      await release();
    }

    var receivedBytes = 0;
    var lastLogged = 0;

    dc.onMessage = (msg) {
      if (msg.isBinary) {
        final b = msg.binary;
        if (b != null && b.isNotEmpty) {
          builder.add(b);
          receivedBytes += b.length;
          if (expectedSize > 0) {
            final progress = (receivedBytes / expectedSize * 100).toInt();
            if (progress >= lastLogged + 10) {
              logger?.call('[Transfer] Receiving: $progress%');
              lastLogged = progress;
            }
          }
        }
        return;
      }
      final text = msg.text;
      if (text == null || text.isEmpty) return;
      try {
        final frame = jsonDecode(text) as Map<String, dynamic>;
        switch (frame['type'] as String?) {
          case 'header':
            fileName = frame['filename'] as String?;
            expectedSize = (frame['size'] as num?)?.toInt() ?? 0;
            expectedHash = frame['sha256'] as String?;
            logger?.call('[Transfer] Inbound header: $fileName ($expectedSize bytes)');
            return;
          case 'clipboard':
            final clipText = frame['text'] as String?;
            if (clipText != null) {
              logger?.call('[Transfer] Inbound clipboard: ${clipText.length} chars');
              onClipboardReceived?.call(clipText);
            }
            return;
          case 'done':
            final received = builder.takeBytes();
            
            Future<void> completeInboundTransfer() async {
              final hash = await HashUtil.sha256Hex(received);
              final ok = received.length == expectedSize &&
                  hash == (expectedHash ?? '').toLowerCase();
              
              logger?.call('[Transfer] Inbound done. Valid: $ok');
              
              try {
                await dc.send(RTCDataChannelMessage(jsonEncode({
                  'type': 'ack',
                  'sha256': hash,
                  'ok': ok,
                })));
                await _drainOutbound(dc);
              } catch (e) {
                logger?.call('[Transfer] Error sending ACK: $e');
              }
              if (ok && fileName != null) {
                onReceived?.call(fileName!, received);
              }
              await Future<void>.delayed(const Duration(milliseconds: 400));
              await finish();
            }

            unawaited(completeInboundTransfer());
            return;
          default:
            return;
        }
      } catch (e) {
        logger?.call('[Transfer] Error parsing DC message: $e');
      }
    };
  }

  Future<void> close() => pc.close();
}
