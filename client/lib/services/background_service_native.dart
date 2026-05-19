import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io' show Platform;
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'transfer_service.dart';
import '../utils/save_download.dart';

/// FR-04: Android Foreground Service — keeps file transfer alive when the
/// user switches apps or the screen turns off.
class BackgroundService {
  static const _notificationChannelId = 'extfrtc_transfer';
  static const _notificationId = 1;

  static Future<void> initialize() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;

    final service = FlutterBackgroundService();

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: _notificationChannelId,
        initialNotificationTitle: 'ExtFRTC',
        initialNotificationContent: 'Ready',
        foregroundServiceNotificationId: _notificationId,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: _onStart,
        onBackground: _onBackground,
      ),
    );
  }

  static Future<void> start() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    await FlutterBackgroundService().startService();
  }

  static void stop() {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    FlutterBackgroundService().invoke('stop');
  }

  /// Updates the foreground notification text with current transfer progress.
  static void updateStatus(String content) {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    FlutterBackgroundService().invoke('updateStatus', {'content': content});
  }
}

@pragma('vm:entry-point')
void _onStart(ServiceInstance service) async {
  service.on('stop').listen((_) {
    service.stopSelf();
  });

  service.on('updateStatus').listen((data) {
    if (data == null) return;
    final content = data['content'] as String?;
    if (content != null && service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: 'ExtFRTC',
        content: content,
      );
    }
  });

  // Start TransferService in the background to receive files
  final prefs = await SharedPreferences.getInstance();
  final url = prefs.getString('signaling_server_url') ?? 'http://localhost:9090';

  // To avoid shadowing the UI signaling connection, we could use a suffix.
  // However, the best approach is to only run signaling in ONE place.
  // For this MVP, we will use the same ID, but the user should know that 
  // having the background service AND UI active might cause signaling to 
  // route to the background service.
  
  final transfer = TransferService(signalingBaseUrl: url);
  await transfer.startServer(
    onReceived: (fileName, data) async {
      dev.log('[Background] Received $fileName');
      await saveDownload(fileName, data);
      BackgroundService.updateStatus('Received $fileName');
    },
    onTransferRequest: (fromName, fileName, size) async {
      // Auto-accept in background for now, or we could show a notification.
      return true; 
    },
  );
}

@pragma('vm:entry-point')
Future<bool> _onBackground(ServiceInstance service) async => true;
