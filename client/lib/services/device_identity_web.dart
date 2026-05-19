import 'dart:html' as html;

import 'package:uuid/uuid.dart';

/// Per-browser-tab id so multiple tabs on the same origin each get their own
/// signaling slot (the server hub maps one WebSocket per id).
class DeviceIdentity {
  DeviceIdentity._();

  static const _key = 'extfrtc_tab_peer_id';
  static Future<String>? _memo;

  static Future<String> getOrCreate() {
    return _memo ??= Future.microtask(() {
      final storage = html.window.sessionStorage;
      final existing = storage[_key];
      if (existing != null && existing.isNotEmpty) {
        return existing;
      }
      final id = const Uuid().v4();
      storage[_key] = id;
      return id;
    });
  }
}
