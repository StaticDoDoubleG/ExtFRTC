import 'dart:html' as html;
import 'dart:js_util' as js_util;
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// FR-05: SHA-256 integrity verification helpers (Web).
class HashUtil {
  HashUtil._();

  /// Returns lowercase hex-encoded SHA-256 digest of [data] asynchronously using browser subtle crypto via JS interop.
  static Future<String> sha256Hex(Uint8List data) async {
    try {
      final crypto = html.window.crypto;
      if (crypto != null) {
        final subtle = js_util.getProperty(crypto, 'subtle');
        if (subtle != null) {
          final buffer = (data.offsetInBytes == 0 && data.length == data.buffer.lengthInBytes)
              ? data.buffer
              : Uint8List.fromList(data).buffer;
          final promise = js_util.callMethod(subtle, 'digest', ['SHA-256', buffer]);
          final arrayBuffer = await js_util.promiseToFuture(promise);
          final bytes = Uint8List.view(arrayBuffer);
          return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
        }
      }
    } catch (_) {}
    
    // Fallback to pure Dart crypto
    return sha256.convert(data).toString();
  }

  /// Returns true if [data] matches the given [expectedHex] digest.
  static Future<bool> verify(Uint8List data, String expectedHex) async {
    final hash = await sha256Hex(data);
    return hash == expectedHex.toLowerCase();
  }
}
