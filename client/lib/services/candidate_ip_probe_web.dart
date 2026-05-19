import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

class CandidateIpProbe {
  static Future<List<String>> collect() async {
    final seen = <String>{};
    RTCPeerConnection? pc;
    RTCDataChannel? dc;
    try {
      pc = await createPeerConnection({
        'iceServers': const [],
        'sdpSemantics': 'unified-plan',
      });
      dc = await pc.createDataChannel('probe', RTCDataChannelInit()..ordered = true);

      final done = Completer<void>();
      pc.onIceCandidate = (candidate) {
        final raw = candidate.candidate ?? '';
        final ip = _extractCandidateIP(raw);
        if (ip != null && _isPrivateIPv4(ip)) {
          seen.add(ip);
        }
        if (raw.isEmpty && !done.isCompleted) {
          done.complete();
        }
      };

      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);

      Future<void>.delayed(const Duration(seconds: 3), () {
        if (!done.isCompleted) {
          done.complete();
        }
      });

      await done.future;
    } catch (_) {
      // ignore and fall back to what we found
    } finally {
      await dc?.close();
      await pc?.close();
    }

    final out = seen.toList()..sort();
    return out;
  }

  static String? _extractCandidateIP(String raw) {
    final parts = raw.split(' ');
    if (parts.length < 5) {
      return null;
    }
    final host = parts[4].trim();
    if (host.isEmpty || host.endsWith('.local')) {
      return null;
    }
    return host;
  }

  static bool _isPrivateIPv4(String ip) {
    return ip.startsWith('10.') ||
        ip.startsWith('192.168.') ||
        RegExp(r'^172\.(1[6-9]|2\d|3[0-1])\.').hasMatch(ip) ||
        RegExp(r'^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.').hasMatch(ip);
  }
}
