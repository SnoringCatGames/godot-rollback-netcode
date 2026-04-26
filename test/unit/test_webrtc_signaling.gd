@tool
extends GutTest
## Unit tests for WebRTC signaling protocol and
## transport type integration.


func before_each():
	ArrayPool.clear_all_pools()


func after_each():
	ArrayPool.clear_all_pools()


class TestSignalingProtocol:
	extends GutTest
	## Tests JSON message parsing and serialization
	## for the WebRTC signaling protocol.

	func before_each():
		ArrayPool.clear_all_pools()


	func after_each():
		ArrayPool.clear_all_pools()


	func test_parse_offer_message():
		var text := JSON.stringify({
			"type": "offer",
			"sdp": "v=0\r\no=...",
			"peer_id": 42,
		})
		var result: Dictionary = (
			WebRTCSignalingServer.parse_message(
				text))
		assert_eq(
			result.get("type"), "offer",
			"Should parse type as offer",
		)
		assert_eq(
			result.get("sdp"), "v=0\r\no=...",
			"Should preserve SDP content",
		)
		assert_eq(
			result.get("peer_id"), 42,
			"Should parse peer_id",
		)


	func test_parse_answer_message():
		var text := JSON.stringify({
			"type": "answer",
			"sdp": "v=0\r\na=...",
		})
		var result: Dictionary = (
			WebRTCSignalingServer.parse_message(
				text))
		assert_eq(
			result.get("type"), "answer",
			"Should parse type as answer",
		)
		assert_eq(
			result.get("sdp"), "v=0\r\na=...",
			"Should preserve SDP content",
		)


	func test_parse_ice_message():
		var text := JSON.stringify({
			"type": "ice",
			"candidate": "candidate:1 1 UDP ...",
			"mid": "0",
			"index": 0,
		})
		var result: Dictionary = (
			WebRTCSignalingServer.parse_message(
				text))
		assert_eq(
			result.get("type"), "ice",
			"Should parse type as ice",
		)
		assert_eq(
			result.get("candidate"),
			"candidate:1 1 UDP ...",
			"Should preserve candidate string",
		)
		assert_eq(
			result.get("mid"), "0",
			"Should parse media id",
		)
		assert_eq(
			result.get("index"), 0,
			"Should parse index",
		)


	func test_serialize_offer_message():
		var data := {
			"type": "offer",
			"sdp": "test_sdp",
			"peer_id": 7,
		}
		var text: String = (
			WebRTCSignalingServer
				.serialize_message(data))
		var parsed = JSON.parse_string(text)
		assert_eq(
			parsed.get("type"), "offer",
			"Serialized offer should round-trip",
		)
		assert_eq(
			parsed.get("sdp"), "test_sdp",
			"SDP should round-trip",
		)


	func test_serialize_answer_message():
		var data := {
			"type": "answer",
			"sdp": "answer_sdp",
		}
		var text: String = (
			WebRTCSignalingServer
				.serialize_message(data))
		var parsed = JSON.parse_string(text)
		assert_eq(
			parsed.get("type"), "answer",
			"Serialized answer should round-trip",
		)


	func test_serialize_ice_message():
		var data := {
			"type": "ice",
			"candidate": "cand",
			"mid": "audio",
			"index": 1,
		}
		var text: String = (
			WebRTCSignalingServer
				.serialize_message(data))
		var parsed = JSON.parse_string(text)
		assert_eq(
			parsed.get("type"), "ice",
			"Serialized ICE should round-trip",
		)
		assert_eq(
			parsed.get("mid"), "audio",
			"Media ID should round-trip",
		)


	func test_invalid_message_type_ignored():
		var result: Dictionary = (
			WebRTCSignalingServer.parse_message(
				"not valid json"))
		assert_eq(
			result.size(), 0,
			"Invalid JSON should return empty dict",
		)


	func test_empty_string_returns_empty_dict():
		var result: Dictionary = (
			WebRTCSignalingServer.parse_message(""))
		assert_eq(
			result.size(), 0,
			"Empty string should return empty dict",
		)


class TestTransportTypeWebRTC:
	extends GutTest
	## Tests that the WEBRTC enum value exists and
	## integrates with send rate settings.

	var frame_driver: FrameDriver
	var _original_send_fps: float
	var _original_network_fps: float
	var _original_enet_fps: float
	var _original_ws_fps: float
	var _original_webrtc_fps: float
	var _original_transport: int


	func before_each():
		ArrayPool.clear_all_pools()
		frame_driver = FrameDriver.new()
		_original_send_fps = (
			Netcode.settings.target_state_send_fps)
		_original_network_fps = (
			Netcode.settings.target_network_fps)
		_original_enet_fps = (
			Netcode.settings.enet_state_send_fps)
		_original_ws_fps = (
			Netcode.settings
				.websocket_state_send_fps)
		_original_webrtc_fps = (
			Netcode.settings
				.webrtc_state_send_fps)
		_original_transport = (
			Netcode.settings.transport_type)
		Netcode.settings.target_network_fps = 60.0


	func after_each():
		ArrayPool.clear_all_pools()
		Netcode.settings.target_state_send_fps = (
			_original_send_fps)
		Netcode.settings.target_network_fps = (
			_original_network_fps)
		Netcode.settings.enet_state_send_fps = (
			_original_enet_fps)
		Netcode.settings.websocket_state_send_fps = (
			_original_ws_fps)
		Netcode.settings.webrtc_state_send_fps = (
			_original_webrtc_fps)
		Netcode.settings.transport_type = (
			_original_transport)
		if is_instance_valid(frame_driver):
			frame_driver.free()


	func test_webrtc_enum_value_exists():
		# Verify the enum value compiles and is
		# distinct from ENET and WEBSOCKET.
		var webrtc: int = (
			NetworkSettings.TransportType.WEBRTC)
		assert_ne(
			webrtc,
			NetworkSettings.TransportType.ENET,
			"WEBRTC should differ from ENET",
		)
		assert_ne(
			webrtc,
			NetworkSettings.TransportType.WEBSOCKET,
			"WEBRTC should differ from WEBSOCKET",
		)


	func test_webrtc_send_rate_default():
		assert_eq(
			Netcode.settings.webrtc_state_send_fps,
			20.0,
			"Default WebRTC send rate should be"
			+ " 20 Hz",
		)


	func test_resolve_send_fps_webrtc_override():
		Netcode.settings.transport_type = (
			NetworkSettings.TransportType.WEBRTC)
		Netcode.settings.target_state_send_fps = (
			20.0)
		Netcode.settings.webrtc_state_send_fps = (
			15.0)
		# WebRTC override (15) should win over
		# global (20). 60/15 = 4.
		assert_eq(
			frame_driver.state_send_interval, 4,
			"WebRTC override should produce"
			+ " interval 4",
		)


	func test_resolve_send_fps_webrtc_fallback_to_global():
		Netcode.settings.transport_type = (
			NetworkSettings.TransportType.WEBRTC)
		Netcode.settings.target_state_send_fps = (
			20.0)
		Netcode.settings.webrtc_state_send_fps = (
			0.0)
		# Override is 0, falls back to global (20).
		# 60/20 = 3.
		assert_eq(
			frame_driver.state_send_interval, 3,
			"Should fall back to global when"
			+ " WebRTC override is 0",
		)
