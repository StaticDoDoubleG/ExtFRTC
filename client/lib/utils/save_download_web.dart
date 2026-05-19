import 'dart:html' as html;
import 'dart:typed_data';

/// Triggers a browser download so the received file is not only in memory.
Future<void> saveDownload(String fileName, Uint8List data) async {
  final blob = html.Blob([data]);
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..setAttribute('download', fileName)
    ..click();
  html.Url.revokeObjectUrl(url);
}
