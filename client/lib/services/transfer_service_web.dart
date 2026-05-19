import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/peer.dart';
import '../utils/hash_util.dart';

/// WebSocket message protocol — same as native (FR-03 / FR-05):
///
///   Sender → Receiver  text:   {"type":"header","filename":"...","size":N,"sha256":"..."}
///   Sender → Receiver  binary: <raw file chunk> × N  (64 KB each)
///   Sender → Receiver  text:   {"type":"done"}
///   Receiver → Sender  text:   {"type":"ack","sha256":"...","ok":true|false}
///
/// Web limitation: browsers cannot bind TCP ports, so [startServer] is a
/// no-op. A web client can SEND files to a native peer (which hosts the
/// WebSocket server), but cannot RECEIVE files directly.

const _wsPort = 49152;
const _chunkSize = 64 * 1024; // 64 KB

/// FR-03 / FR-05: P2P WebSocket file transfer — send-only on web.
class TransferService {
  // ── Receiver (not available on web) ──────────────────────────

  /// No-op on web: browsers cannot bind TCP ports.
  Future<void> startServer({
    required void Function(String fileName, Uint8List data) onReceived,
  }) async {
    // Receiving is handled by native peers; web is send-only in this MVP.
  }

  // ── Sender (WebSocket client) ─────────────────────────────────

  /// Connects to [peer]'s WebSocket endpoint via the browser's native
  /// WebSocket, streams [data], and waits for the receiver's ACK.
  /// Returns true when the receiver confirms the SHA-256 hash.
  Future<bool> sendFile(Peer peer, String fileName, Uint8List data) async {
    final hash = HashUtil.sha256Hex(data);

    final uri = Uri.parse('ws://${peer.transferAddress}:$_wsPort');
    final channel = WebSocketChannel.connect(uri);

    final ackCompleter = Completer<bool>();

    channel.stream.listen(
      (message) {
        if (message is String && !ackCompleter.isCompleted) {
          final frame = jsonDecode(message) as Map<String, dynamic>;
          if (frame['type'] == 'ack') {
            ackCompleter.complete(frame['ok'] == true);
          }
        }
      },
      onError: (e) {
        if (!ackCompleter.isCompleted) ackCompleter.completeError(e);
      },
      onDone: () {
        if (!ackCompleter.isCompleted) ackCompleter.complete(false);
      },
    );

    try {
      // 1. Header frame
      channel.sink.add(jsonEncode({
        'type': 'header',
        'filename': fileName,
        'size': data.length,
        'sha256': hash,
      }));

      // 2. Binary payload frames (chunked)
      for (var offset = 0; offset < data.length; offset += _chunkSize) {
        final end = (offset + _chunkSize).clamp(0, data.length);
        channel.sink.add(data.sublist(offset, end));
      }

      // 3. Done signal — triggers receiver-side verification
      channel.sink.add(jsonEncode({'type': 'done'}));

      // 4. Await ACK (30s timeout for large files)
      return await ackCompleter.future.timeout(const Duration(seconds: 30));
    } catch (_) {
      return false;
    } finally {
      await channel.sink.close();
    }
  }

  Future<void> stopServer() async {}
}
