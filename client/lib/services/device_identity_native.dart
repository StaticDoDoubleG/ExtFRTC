import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Stable device id (persisted) for native apps.
class DeviceIdentity {
  DeviceIdentity._();

  static const _key = 'device_id';
  static Future<String>? _memo;

  static Future<String> getOrCreate() {
    return _memo ??= _load();
  }

  static Future<String> _load() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_key);
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      await prefs.setString(_key, id);
    }
    return id;
  }
}
