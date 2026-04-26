@tool
extends GutTest
## Unit tests for send rate throttling infrastructure.


func before_each():
	ArrayPool.clear_all_pools()


func after_each():
	ArrayPool.clear_all_pools()


class TestStateSendInterval:
	extends GutTest
	## Tests FrameDriver.state_send_interval
	## computation from settings.

	var frame_driver: FrameDriver
	var _original_send_fps: float
	var _original_network_fps: float
	var _original_enet_fps: float
	var _original_ws_fps: float
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
			Netcode.settings.websocket_state_send_fps)
		_original_transport = (
			Netcode.settings.transport_type)
		# Zero out per-transport overrides so tests
		# exercise the global setting in isolation.
		Netcode.settings.enet_state_send_fps = 0.0
		Netcode.settings.websocket_state_send_fps = 0.0


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
		Netcode.settings.transport_type = (
			_original_transport)
		if is_instance_valid(frame_driver):
			frame_driver.free()


	func test_default_zero_returns_interval_one():
		Netcode.settings.target_state_send_fps = 0.0
		assert_eq(
			frame_driver.state_send_interval, 1,
			"Default 0 should mean every frame",
		)


	func test_send_fps_equal_to_sim_fps_returns_one():
		Netcode.settings.target_network_fps = 60.0
		Netcode.settings.target_state_send_fps = 60.0
		assert_eq(
			frame_driver.state_send_interval, 1,
			"Same rate should send every frame",
		)


	func test_send_fps_greater_than_sim_returns_one():
		Netcode.settings.target_network_fps = 60.0
		Netcode.settings.target_state_send_fps = 120.0
		assert_eq(
			frame_driver.state_send_interval, 1,
			"Higher send rate clamps to every frame",
		)


	func test_send_fps_30_at_60_sim_returns_two():
		Netcode.settings.target_network_fps = 60.0
		Netcode.settings.target_state_send_fps = 30.0
		assert_eq(
			frame_driver.state_send_interval, 2,
			"60/30 = 2 frame interval",
		)


	func test_send_fps_20_at_60_sim_returns_three():
		Netcode.settings.target_network_fps = 60.0
		Netcode.settings.target_state_send_fps = 20.0
		assert_eq(
			frame_driver.state_send_interval, 3,
			"60/20 = 3 frame interval",
		)


	func test_send_fps_15_at_60_sim_returns_four():
		Netcode.settings.target_network_fps = 60.0
		Netcode.settings.target_state_send_fps = 15.0
		assert_eq(
			frame_driver.state_send_interval, 4,
			"60/15 = 4 frame interval",
		)


	func test_send_fps_10_at_60_sim_returns_six():
		Netcode.settings.target_network_fps = 60.0
		Netcode.settings.target_state_send_fps = 10.0
		assert_eq(
			frame_driver.state_send_interval, 6,
			"60/10 = 6 frame interval",
		)


	func test_negative_send_fps_returns_one():
		Netcode.settings.target_state_send_fps = -5.0
		assert_eq(
			frame_driver.state_send_interval, 1,
			"Negative should mean every frame",
		)


	func test_fractional_send_fps_rounds_correctly():
		Netcode.settings.target_network_fps = 60.0
		Netcode.settings.target_state_send_fps = 25.0
		# 60/25 = 2.4, rounds to 2.
		assert_eq(
			frame_driver.state_send_interval, 2,
			"60/25 rounds to 2",
		)


class TestIsStateSendFrame:
	extends GutTest
	## Tests FrameDriver.is_state_send_frame().

	var frame_driver: FrameDriver
	var _original_send_fps: float
	var _original_network_fps: float
	var _original_enet_fps: float
	var _original_ws_fps: float


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
			Netcode.settings.websocket_state_send_fps)
		# Zero out per-transport overrides so tests
		# exercise the global setting in isolation.
		Netcode.settings.enet_state_send_fps = 0.0
		Netcode.settings.websocket_state_send_fps = 0.0


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
		if is_instance_valid(frame_driver):
			frame_driver.free()


	func test_every_frame_when_interval_one():
		Netcode.settings.target_state_send_fps = 0.0
		for i in range(10):
			frame_driver.server_frame_index = i
			assert_true(
				frame_driver.is_state_send_frame(),
				"Frame %d should send" % i,
			)


	func test_every_other_frame_when_interval_two():
		Netcode.settings.target_network_fps = 60.0
		Netcode.settings.target_state_send_fps = 30.0
		for i in range(10):
			frame_driver.server_frame_index = i
			var expected := (i % 2) == 0
			assert_eq(
				frame_driver.is_state_send_frame(),
				expected,
				"Frame %d send=%s" % [i, expected],
			)


	func test_every_third_frame_when_interval_three():
		Netcode.settings.target_network_fps = 60.0
		Netcode.settings.target_state_send_fps = 20.0
		for i in range(10):
			frame_driver.server_frame_index = i
			var expected := (i % 3) == 0
			assert_eq(
				frame_driver.is_state_send_frame(),
				expected,
				"Frame %d send=%s" % [i, expected],
			)


	func test_frame_zero_always_sends():
		Netcode.settings.target_network_fps = 60.0
		Netcode.settings.target_state_send_fps = 10.0
		frame_driver.server_frame_index = 0
		assert_true(
			frame_driver.is_state_send_frame(),
			"Frame 0 should always send",
		)


class TestPerTransportSendRate:
	extends GutTest
	## Tests per-transport send rate resolution.

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
			Netcode.settings.websocket_state_send_fps)
		_original_webrtc_fps = (
			Netcode.settings.webrtc_state_send_fps)
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


	func test_enet_override_used_when_transport_is_enet():
		Netcode.settings.transport_type = (
			NetworkSettings.TransportType.ENET)
		Netcode.settings.target_state_send_fps = 30.0
		Netcode.settings.enet_state_send_fps = 20.0
		# ENet override (20) should win over global (30).
		# 60/20 = 3.
		assert_eq(
			frame_driver.state_send_interval, 3,
			"ENet override should produce interval 3",
		)


	func test_websocket_override_used_when_transport_is_websocket():
		Netcode.settings.transport_type = (
			NetworkSettings.TransportType.WEBSOCKET)
		Netcode.settings.target_state_send_fps = 30.0
		Netcode.settings.websocket_state_send_fps = 15.0
		# WS override (15) should win over global (30).
		# 60/15 = 4.
		assert_eq(
			frame_driver.state_send_interval, 4,
			"WebSocket override should produce interval 4",
		)


	func test_falls_back_to_global_when_override_is_zero():
		Netcode.settings.transport_type = (
			NetworkSettings.TransportType.ENET)
		Netcode.settings.target_state_send_fps = 20.0
		Netcode.settings.enet_state_send_fps = 0.0
		# Override is 0, falls back to global (20).
		# 60/20 = 3.
		assert_eq(
			frame_driver.state_send_interval, 3,
			"Should fall back to global when override is 0",
		)


	func test_global_zero_with_no_override_returns_one():
		Netcode.settings.transport_type = (
			NetworkSettings.TransportType.ENET)
		Netcode.settings.target_state_send_fps = 0.0
		Netcode.settings.enet_state_send_fps = 0.0
		assert_eq(
			frame_driver.state_send_interval, 1,
			"All zero should mean every frame",
		)


	func test_webrtc_override_used_when_transport_is_webrtc():
		Netcode.settings.transport_type = (
			NetworkSettings.TransportType.WEBRTC)
		Netcode.settings.target_state_send_fps = 20.0
		Netcode.settings.webrtc_state_send_fps = 15.0
		# WebRTC override (15) should win over
		# global (20). 60/15 = 4.
		assert_eq(
			frame_driver.state_send_interval, 4,
			"WebRTC override should produce"
			+ " interval 4",
		)


	func test_webrtc_falls_back_to_global_when_zero():
		Netcode.settings.transport_type = (
			NetworkSettings.TransportType.WEBRTC)
		Netcode.settings.target_state_send_fps = 20.0
		Netcode.settings.webrtc_state_send_fps = 0.0
		# Override is 0, falls back to global (20).
		# 60/20 = 3.
		assert_eq(
			frame_driver.state_send_interval, 3,
			"Should fall back to global when"
			+ " WebRTC override is 0",
		)


class TestBackPressure:
	extends GutTest
	## Tests buffer back-pressure helper.

	func before_each():
		ArrayPool.clear_all_pools()


	func after_each():
		ArrayPool.clear_all_pools()


	func test_is_peer_buffer_overloaded_returns_false_for_enet():
		# Default transport is ENet. The method
		# should return false for non-WebSocket.
		assert_false(
			Netcode.connector
				.is_peer_buffer_overloaded(1),
			"ENet peers cannot be buffer-overloaded",
		)


	func test_back_pressure_filter_returns_true_when_not_overloaded():
		# Create a minimal ReconcilableState-like
		# test to verify the filter returns true
		# when the peer is not overloaded (ENet).
		# We cannot easily test WebSocket buffer
		# levels without a real connection.
		assert_false(
			Netcode.connector
				.is_peer_buffer_overloaded(42),
			"Non-existent peer should not be overloaded",
		)
