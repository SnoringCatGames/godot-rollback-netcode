extends GutTest
## Unit tests for StateBundler raw byte encoding and
## decoding. Verifies round-trip fidelity for all
## property types and redundant input handling.


func before_each():
	ArrayPool.clear_all_pools()


func after_each():
	ArrayPool.clear_all_pools()


# =============================================================
# Encode/decode round-trip tests
# =============================================================


class TestEncodeDecodeRoundTrip:
	extends GutTest

	func before_each():
		ArrayPool.clear_all_pools()

	func after_each():
		ArrayPool.clear_all_pools()

	func test_int_properties_round_trip():
		var pack_types: Array[int] = [
			ReconcilableState.PackType.INT,
			ReconcilableState.PackType.INT,
			ReconcilableState.PackType.INT,
		]
		var state := [42, -7, 0, 1, 100]
		# state: [prop0, prop1, prop2, frame_auth, frame_idx]

		var encoded := StateBundler._encode_state(
			state, pack_types,
		)
		var decoded: Array = StateBundler._decode_state(
			encoded, 0, encoded.size(), pack_types,
		)

		assert_eq(decoded.size(), 5)
		assert_eq(decoded[0], 42)
		assert_eq(decoded[1], -7)
		assert_eq(decoded[2], 0)
		assert_eq(decoded[3], 1, "frame_authority")
		assert_eq(decoded[4], 100, "frame_index")

		ArrayPool.release(decoded)

	func test_float_properties_round_trip():
		var pack_types: Array[int] = [
			ReconcilableState.PackType.FLOAT,
			ReconcilableState.PackType.FLOAT,
		]
		var state := [3.14, -0.5, 2, 500]

		var encoded := StateBundler._encode_state(
			state, pack_types,
		)
		var decoded: Array = StateBundler._decode_state(
			encoded, 0, encoded.size(), pack_types,
		)

		assert_eq(decoded.size(), 4)
		assert_almost_eq(
			decoded[0], 3.14, 0.001,
			"float property 0",
		)
		assert_almost_eq(
			decoded[1], -0.5, 0.001,
			"float property 1",
		)
		assert_eq(decoded[2], 2, "frame_authority")
		assert_eq(decoded[3], 500, "frame_index")

		ArrayPool.release(decoded)

	func test_vector2_properties_round_trip():
		var pack_types: Array[int] = [
			ReconcilableState.PackType.VECTOR2,
			ReconcilableState.PackType.VECTOR2,
		]
		var pos := Vector2(123.456, -789.012)
		var vel := Vector2(0.0, 50.5)
		var state := [pos, vel, 0, 1234]

		var encoded := StateBundler._encode_state(
			state, pack_types,
		)
		var decoded: Array = StateBundler._decode_state(
			encoded, 0, encoded.size(), pack_types,
		)

		assert_eq(decoded.size(), 4)
		assert_almost_eq(
			decoded[0], pos, Vector2(0.01, 0.01),
			"position",
		)
		assert_almost_eq(
			decoded[1], vel, Vector2(0.01, 0.01),
			"velocity",
		)
		assert_eq(decoded[2], 0, "frame_authority")
		assert_eq(decoded[3], 1234, "frame_index")

		ArrayPool.release(decoded)

	func test_mixed_types_round_trip():
		# Matches CharacterStateFromServer layout:
		# position, velocity, surfaces,
		# interaction_type, interaction_frame,
		# interaction_pos, interaction_vel.
		var pack_types: Array[int] = [
			ReconcilableState.PackType.VECTOR2,
			ReconcilableState.PackType.VECTOR2,
			ReconcilableState.PackType.INT,
			ReconcilableState.PackType.INT,
			ReconcilableState.PackType.INT,
			ReconcilableState.PackType.VECTOR2,
			ReconcilableState.PackType.VECTOR2,
		]
		var state := [
			Vector2(100.0, 200.0),
			Vector2(-50.0, 10.0),
			3,
			0,
			-1,
			Vector2.ZERO,
			Vector2.ZERO,
			1,   # frame_authority (AUTHORITATIVE)
			5678, # frame_index
		]

		var encoded := StateBundler._encode_state(
			state, pack_types,
		)
		var decoded: Array = StateBundler._decode_state(
			encoded, 0, encoded.size(), pack_types,
		)

		assert_eq(decoded.size(), 9)
		assert_almost_eq(
			decoded[0],
			Vector2(100.0, 200.0),
			Vector2(0.01, 0.01),
		)
		assert_almost_eq(
			decoded[1],
			Vector2(-50.0, 10.0),
			Vector2(0.01, 0.01),
		)
		assert_eq(decoded[2], 3)
		assert_eq(decoded[3], 0)
		assert_eq(decoded[4], -1)
		assert_almost_eq(
			decoded[5],
			Vector2.ZERO,
			Vector2(0.01, 0.01),
		)
		assert_almost_eq(
			decoded[6],
			Vector2.ZERO,
			Vector2(0.01, 0.01),
		)
		assert_eq(decoded[7], 1, "frame_authority")
		assert_eq(decoded[8], 5678, "frame_index")

		ArrayPool.release(decoded)

	func test_negative_frame_index():
		var pack_types: Array[int] = [
			ReconcilableState.PackType.INT,
		]
		var state := [0, 2, -1]

		var encoded := StateBundler._encode_state(
			state, pack_types,
		)
		var decoded: Array = StateBundler._decode_state(
			encoded, 0, encoded.size(), pack_types,
		)

		assert_eq(decoded[2], -1, "negative frame_index")

		ArrayPool.release(decoded)

	func test_large_frame_index():
		var pack_types: Array[int] = [
			ReconcilableState.PackType.INT,
		]
		var state := [42, 0, 999999]

		var encoded := StateBundler._encode_state(
			state, pack_types,
		)
		var decoded: Array = StateBundler._decode_state(
			encoded, 0, encoded.size(), pack_types,
		)

		assert_eq(
			decoded[2], 999999,
			"large frame_index",
		)

		ArrayPool.release(decoded)

	func test_decode_at_nonzero_offset():
		var pack_types: Array[int] = [
			ReconcilableState.PackType.INT,
		]
		var state := [77, 1, 200]

		var encoded := StateBundler._encode_state(
			state, pack_types,
		)

		# Prepend junk bytes to simulate bundle
		# header offset.
		var padded := PackedByteArray([0, 0, 0])
		padded.append_array(encoded)

		var decoded: Array = StateBundler._decode_state(
			padded, 3, encoded.size(), pack_types,
		)

		assert_eq(decoded[0], 77)
		assert_eq(decoded[1], 1)
		assert_eq(decoded[2], 200)

		ArrayPool.release(decoded)


# =============================================================
# Redundant input tests
# =============================================================


class TestRedundantInput:
	extends GutTest

	func before_each():
		ArrayPool.clear_all_pools()

	func after_each():
		ArrayPool.clear_all_pools()

	func test_state_without_redundant_input():
		var pack_types: Array[int] = [
			ReconcilableState.PackType.INT,
			ReconcilableState.PackType.INT,
			ReconcilableState.PackType.INT,
			ReconcilableState.PackType.VECTOR2,
			ReconcilableState.PackType.VECTOR2,
		]
		# Standard input state (no redundant data).
		var state := [
			15,  # actions
			0,   # interaction_type
			-1,  # interaction_frame
			Vector2.ZERO,
			Vector2.ZERO,
			1,   # frame_authority
			300, # frame_index
		]

		var encoded := StateBundler._encode_state(
			state, pack_types,
		)
		var decoded: Array = StateBundler._decode_state(
			encoded, 0, encoded.size(), pack_types,
		)

		assert_eq(decoded.size(), 7, "standard size")
		assert_eq(decoded[0], 15, "actions")
		assert_eq(decoded[5], 1, "frame_authority")
		assert_eq(decoded[6], 300, "frame_index")

		ArrayPool.release(decoded)

	func test_state_with_redundant_input():
		var pack_types: Array[int] = [
			ReconcilableState.PackType.INT,
			ReconcilableState.PackType.INT,
			ReconcilableState.PackType.INT,
			ReconcilableState.PackType.VECTOR2,
			ReconcilableState.PackType.VECTOR2,
		]
		# Extended state with 3 redundant frames.
		var state := [
			15,  # actions
			0,   # interaction_type
			-1,  # interaction_frame
			Vector2.ZERO,
			Vector2.ZERO,
			1,   # frame_authority
			300, # frame_index
			# Redundant input:
			3,   # redundant_count
			299, 12,  # frame 299, actions 12
			298, 8,   # frame 298, actions 8
			297, 0,   # frame 297, actions 0
		]

		var encoded := StateBundler._encode_state(
			state, pack_types,
		)
		var decoded: Array = StateBundler._decode_state(
			encoded, 0, encoded.size(), pack_types,
		)

		assert_eq(
			decoded.size(), 14,
			"standard + redundant",
		)
		# Standard part.
		assert_eq(decoded[0], 15, "actions")
		assert_eq(decoded[5], 1, "frame_authority")
		assert_eq(decoded[6], 300, "frame_index")
		# Redundant part.
		assert_eq(
			decoded[7], 3, "redundant_count",
		)
		assert_eq(decoded[8], 299, "hist frame 0")
		assert_eq(decoded[9], 12, "hist actions 0")
		assert_eq(decoded[10], 298, "hist frame 1")
		assert_eq(decoded[11], 8, "hist actions 1")
		assert_eq(decoded[12], 297, "hist frame 2")
		assert_eq(decoded[13], 0, "hist actions 2")

		ArrayPool.release(decoded)

	func test_redundant_count_zero_is_standard():
		var pack_types: Array[int] = [
			ReconcilableState.PackType.INT,
		]
		# State with explicit zero redundant count.
		var state := [5, 0, 100, 0]
		# [prop, frame_auth, frame_idx, redundant_count=0]

		var encoded := StateBundler._encode_state(
			state, pack_types,
		)
		var decoded: Array = StateBundler._decode_state(
			encoded, 0, encoded.size(), pack_types,
		)

		# Redundant count=0 means extra_size=1, so
		# decoded includes the count byte.
		assert_eq(decoded[0], 5)
		assert_eq(decoded[1], 0, "frame_authority")
		assert_eq(decoded[2], 100, "frame_index")
		assert_eq(decoded[3], 0, "redundant_count")

		ArrayPool.release(decoded)


# =============================================================
# Byte size tests
# =============================================================


class TestByteSize:
	extends GutTest

	func test_int_only_size():
		var pack_types: Array[int] = [
			ReconcilableState.PackType.INT,
		]
		var state := [42, 1, 100]

		var encoded := StateBundler._encode_state(
			state, pack_types,
		)

		# 1 int (4) + frame_auth (1) + frame_idx (4)
		# = 9 bytes.
		assert_eq(encoded.size(), 9)

	func test_vector2_size():
		var pack_types: Array[int] = [
			ReconcilableState.PackType.VECTOR2,
		]
		var state := [Vector2(1.0, 2.0), 0, 50]

		var encoded := StateBundler._encode_state(
			state, pack_types,
		)

		# 1 vec2 (8) + frame_auth (1) + frame_idx (4)
		# = 13 bytes.
		assert_eq(encoded.size(), 13)

	func test_character_state_layout_size():
		# CharacterStateFromServer: 2 vec2 + 3 int
		# + 2 vec2.
		var pack_types: Array[int] = [
			ReconcilableState.PackType.VECTOR2,
			ReconcilableState.PackType.VECTOR2,
			ReconcilableState.PackType.INT,
			ReconcilableState.PackType.INT,
			ReconcilableState.PackType.INT,
			ReconcilableState.PackType.VECTOR2,
			ReconcilableState.PackType.VECTOR2,
		]
		var state := [
			Vector2.ZERO, Vector2.ZERO,
			0, 0, 0,
			Vector2.ZERO, Vector2.ZERO,
			0, 0,
		]

		var encoded := StateBundler._encode_state(
			state, pack_types,
		)

		# 4*8 + 3*4 + 1 + 4 = 32 + 12 + 5 = 49
		assert_eq(encoded.size(), 49)

	func test_redundant_input_adds_expected_bytes():
		var pack_types: Array[int] = [
			ReconcilableState.PackType.INT,
		]
		# Standard state (no redundant).
		var standard := [0, 0, 0]
		var standard_size := StateBundler._encode_state(
			standard, pack_types,
		).size()

		# With 3 redundant frames.
		var with_redundant := [
			0, 0, 0,
			3,      # count
			1, 2,   # frame, actions
			3, 4,
			5, 6,
		]
		var redundant_size := (
			StateBundler._encode_state(
				with_redundant, pack_types,
			).size()
		)

		# Extra: 1 (count) + 3*8 (frames) = 25.
		assert_eq(
			redundant_size - standard_size,
			25,
			"redundant adds 1 + 3*8 bytes",
		)


# =============================================================
# Pool integration tests
# =============================================================


class TestPoolIntegration:
	extends GutTest

	func before_each():
		ArrayPool.clear_all_pools()

	func after_each():
		ArrayPool.clear_all_pools()

	func test_decoded_array_is_pool_acquired():
		var pack_types: Array[int] = [
			ReconcilableState.PackType.INT,
		]
		var state := [10, 0, 50]

		var encoded := StateBundler._encode_state(
			state, pack_types,
		)
		var decoded: Array = StateBundler._decode_state(
			encoded, 0, encoded.size(), pack_types,
		)

		# Release should succeed without error
		# (array was pool-acquired).
		ArrayPool.release(decoded)

		var stats := ArrayPool.get_pool_stats()
		assert_eq(
			stats.get("total_pooled", 0),
			1,
			"released array should be in pool",
		)
