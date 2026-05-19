/// Platform-adaptive clipboard sync (FR-07).
///
/// On native: delegates to [clipboard_service_native.dart] which uses
/// clipboard_watcher for OS-level clipboard change events.
///
/// On web: delegates to [clipboard_service_web.dart] which polls the
/// browser clipboard every 2 seconds via Flutter's Clipboard API
/// (no platform channel required).
export 'clipboard_service_web.dart'
    if (dart.library.io) 'clipboard_service_native.dart';
