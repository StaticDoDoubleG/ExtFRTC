/// Web stub — foreground services are not applicable in a browser.
/// The Dart/Flutter runtime keeps running as long as the browser tab is open;
/// no OS-level keepalive mechanism is needed for an MVP demo.
class BackgroundService {
  static Future<void> initialize() async {}
  static Future<void> start() async {}
  static void stop() {}
  static void updateStatus(String content) {}
}
