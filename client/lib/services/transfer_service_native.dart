import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/peer.dart';
import '../utils/hash_util.dart';

/// WebSocket message protocol (text frames are JSON):
///
///   Sender → Receiver  text:   {"type":"header","filename":"...","size":N,"sha256":"..."}
///   Sender → Receiver  binary: <raw file chunk> × N  (64 KB each)
///   Sender → Receiver  text:   {"type":"done"}
///   Receiver → Sender  text:   {"type":"ack","sha256":"...","ok":true|false}
///
/// FR-03: No relay — WebSocket endpoint is served directly by the receiver peer.
/// FR-05: SHA-256 is computed by sender, re-verified by receiver, echoed back.

const _wsPort = 49152;
const _chunkSize = 64 * 1024; // 64 KB

/// FR-03 / FR-05: P2P WebSocket file transfer with SHA-256 integrity check.
class TransferService {
  HttpServer? _server;

  // ── Receiver (WebSocket server) ───────────────────────────────

  /// Binds an HTTP server on [_wsPort] and upgrades incoming connections to
  /// WebSocket. [onReceived] fires only when integrity is confirmed.
  Future<void> startServer({
    required void Function(String fileName, Uint8List data) onReceived,
  }) async {
    _server = await HttpServer.bind(InternetAddress.anyIPv4, _wsPort);
    _server!.listen((HttpRequest req) async {
      if (!WebSocketTransformer.isUpgradeRequest(req)) {
        req.response
          ..statusCode = HttpStatus.badRequest
          ..close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      final channel = IOWebSocketChannel(ws);
      _handleIncoming(channel, onReceived);
    });
  }

  void _handleIncoming(
    WebSocketChannel channel,
    void Function(String, Uint8List) onReceived,
  ) {
    String? fileName;
    String? expectedHash;
    int expectedSize = 0;
    final payloadChunks = <int>[];

    channel.stream.listen(
      (message) {
        if (message is String) {
          final frame = jsonDecode(message) as Map<String, dynamic>;
          switch (frame['type'] as String) {
            case 'header':
              fileName = frame['filename'] as String;
              expectedSize = frame['size'] as int;
              expectedHash = frame['sha256'] as String;

            case 'done':
              final data = Uint8List.fromList(payloadChunks);
              final sizeOk = data.length == expectedSize;
              final hashOk = sizeOk && HashUtil.verify(data, expectedHash ?? '');

              channel.sink.add(jsonEncode({
                'type': 'ack',
                'sha256': HashUtil.sha256Hex(data),
                'ok': hashOk,
              }));
              channel.sink.close();

              if (hashOk && fileName != null) {
                onReceived(fileName!, data);
              }
          }
        } else if (message is List<int>) {
          payloadChunks.addAll(message);
        }
      },
      onError: (_) => channel.sink.close(),
    );
  }

  // ── Sender (WebSocket client) ─────────────────────────────────

  /// Connects to [peer]'s WebSocket endpoint, streams the file bytes, and
  /// waits for the receiver's ACK. Returns true when the receiver confirms
  /// the hash.
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
      channel.sink.add(jsonEncode({
        'type': 'header',
        'filename': fileName,
        'size': data.length,
        'sha256': hash,
      }));

      for (var offset = 0; offset < data.length; offset += _chunkSize) {
        final end = (offset + _chunkSize).clamp(0, data.length);
        channel.sink.add(data.sublist(offset, end));
      }

      channel.sink.add(jsonEncode({'type': 'done'}));

      return await ackCompleter.future.timeout(const Duration(seconds: 30));
    } catch (_) {
      return false;
    } finally {
      await channel.sink.close();
    }
  }

  Future<void> stopServer() async {
    await _server?.close();
    _server = null;
  }
}
