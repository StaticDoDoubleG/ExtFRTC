/// Platform-adaptive background service.
///
/// On native (Android / iOS): delegates to [background_service_native.dart]
/// which uses flutter_background_service to keep transfers alive when the
/// app is backgrounded (FR-04).
///
/// On web: delegates to [background_service_web.dart] — a no-op stub,
/// because the browser keeps Dart code running as long as the tab is open.
export 'background_service_web.dart'
    if (dart.library.io) 'background_service_native.dart';
