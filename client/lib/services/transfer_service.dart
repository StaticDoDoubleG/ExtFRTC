/// Platform-independent P2P file transfer via WebRTC DataChannel (FR-03 / FR-05).
///
/// [flutter_webrtc] delegates to the browser's native RTCPeerConnection on web
/// (no extra bundle bytes) and to libwebrtc on native targets. A single
/// implementation covers all platforms.
///
/// The signaling server only exchanges SDP offers/answers and ICE candidates
/// (a few KB of JSON per session).  File data never passes through it.
export 'webrtc_transfer_service.dart';
