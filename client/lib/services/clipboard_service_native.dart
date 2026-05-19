import 'package:clipboard_watcher/clipboard_watcher.dart';
import 'package:flutter/services.dart';

import '../models/peer.dart';
import 'transfer_service.dart';

/// FR-07: Monitors clipboard changes and pushes text to trusted peers.
class ClipboardService with ClipboardListener {
  final TransferService transferService;
  final List<Peer> _trustedPeers = [];
  bool _running = false;

  bool requireConfirmation;
  void Function(String text)? onPendingClipboard;
  String? _pendingText;

  ClipboardService({required this.transferService, this.requireConfirmation = false});

  void setTrustedPeers(List<Peer> peers) {
    _trustedPeers
      ..clear()
      ..addAll(peers);
  }

  void start() {
    if (_running) return;
    clipboardWatcher.addListener(this);
    clipboardWatcher.start();
    _running = true;
  }

  void stop() {
    clipboardWatcher.removeListener(this);
    clipboardWatcher.stop();
    _running = false;
  }

  @override
  void onClipboardChanged() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.isEmpty) return;

    if (requireConfirmation) {
      _pendingText = text;
      onPendingClipboard?.call(text);
    } else {
      await _pushToAll(text);
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
    await transferService.sendClipboard(peer, text);
  }
}
