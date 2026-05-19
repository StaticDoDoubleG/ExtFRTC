import 'dart:isolate';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// FR-05: SHA-256 integrity verification helpers (Native).
class HashUtil {
  HashUtil._();

  /// Returns lowercase hex-encoded SHA-256 digest of [data] asynchronously.
  /// Uses Isolate to avoid blocking the main UI thread during heavy computation.
  static Future<String> sha256Hex(Uint8List data) async {
    // Run the expensive hashing operation in a separate Isolate
    return await Isolate.run(() {
      return sha256.convert(data).toString();
    });
  }

  /// Returns true if [data] matches the given [expectedHex] digest.
  static Future<bool> verify(Uint8List data, String expectedHex) async {
    final hash = await sha256Hex(data);
    return hash == expectedHex.toLowerCase();
  }
}
