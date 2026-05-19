import 'dart:developer' as dev;
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// Saves the received file to the device's downloads or documents directory.
Future<void> saveDownload(String fileName, Uint8List data) async {
  Directory? dir;
  try {
    if (Platform.isAndroid) {
      dir = Directory('/storage/emulated/0/Download');
      if (!await dir.exists()) {
        dir = await getExternalStorageDirectory();
      }
    } else if (Platform.isIOS || Platform.isMacOS) {
      dir = await getApplicationDocumentsDirectory();
    } else {
      dir = await getDownloadsDirectory();
    }

    dir ??= await getApplicationDocumentsDirectory();

    final filePath = p.join(dir.path, fileName);
    dev.log('[Download] Saving to: $filePath');
    final file = File(filePath);
    await file.writeAsBytes(data);
    dev.log('[Download] Saved successfully');
  } catch (e) {
    dev.log('[Download] Error saving file: $e');
  }
}
