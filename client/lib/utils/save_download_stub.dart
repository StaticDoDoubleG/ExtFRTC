import 'dart:typed_data';

/// No-op on VM (native app can add file save later).
Future<void> saveDownload(String fileName, Uint8List data) async {}
