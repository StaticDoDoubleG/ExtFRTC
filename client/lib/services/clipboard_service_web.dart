import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../models/peer.dart';

/// Web clipboard sync — polls the browser clipboard every 2 seconds.
///
/// Uses Flutter's cross-platform [Clipboard] API (flutter/services.dart)
/// instead of clipboard_watcher, which relies on platform channels
/// unavailable in the browser.
///
/// Note: browsers require the page to be focused for clipboard reads to
/// succeed (Permissions Policy). The poll silently skips when access is
/// denied.
class ClipboardService {
  static const _clipboardPort = 49153;

  final List<Peer> _trustedPeers = [];
  bool _running = false;
  Timer? _pollTimer;
  String? _lastText;

  bool requireConfirmation;
  void Function(String text)? onPendingClipboard;
  String? _pendingText;

  ClipboardService({this.requireConfirmation = false});

  void setTrustedPeers(List<Peer> peers) {
    _trustedPeers
      ..clear()
      ..addAll(peers);
  }

  void start() {
    if (_running) return;
    _running = true;
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  void stop() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _running = false;
  }

  Future<void> _poll() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      if (text == null || text.isEmpty || text == _lastText) return;
      _lastText = text;

      if (requireConfirmation) {
        _pendingText = text;
        onPendingClipboard?.call(text);
      } else {
        await _pushToAll(text);
      }
    } catch (_) {
      // Clipboard access denied by browser — skip silently
    }
  }

  Future<void> confirmAndFlush() async {
    final text = _pendingText;
    _pendingText = null;
    if (text != null && text.isNotEmpty) await _pushToAll(text);
  }

  Future<void> _pushToAll(String text) async {
    for (final peer in _trustedPeers) {
      await _push(peer, text);
    }
  }

  Future<void> _push(Peer peer, String text) async {
    try {
      await http
          .post(
            Uri.parse('http://${peer.transferAddress}:$_clipboardPort/clipboard'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'text': text}),
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
  }
}
