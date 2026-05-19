/// Platform-adaptive peer discovery.
///
/// On native: delegates to [discovery_service_native.dart] which uses
/// mDNS (L2) + HTTP signaling server (L3) in parallel (FR-01).
///
/// On web: delegates to [discovery_service_web.dart] which uses HTTP
/// signaling server only — browsers have no raw socket access for mDNS.
export 'discovery_service_web.dart'
    if (dart.library.io) 'discovery_service_native.dart';
