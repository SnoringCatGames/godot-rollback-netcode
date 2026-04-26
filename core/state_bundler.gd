class_name StateBundler
extends Node
## Bundles per-frame ReconcilableState into single
## packets to reduce SCTP packet count for WebRTC.
##
## Uses raw byte packing instead of var_to_bytes to
## eliminate temporary Array allocations (GC pressure
## in WASM) and reduce data size by ~50%.
##
## Bundle format:
##   [1 byte: entity_count]
##   For each entity:
##     [1 byte: entity_type]
##     [1 byte: player_id (unsigned)]
##     [2 bytes: data_length (little-endian)]
##     [data_length bytes: raw packed state]
##       Standard properties packed per the node's
##       _pack_types layout (Vector2=8B, int=4B,
##       float=4B), then frame_authority (1B) and
##       frame_index (4B). Input nodes may append
##       redundant frames (1B count + 8B per frame).


## Cached node lookup by (entity_type, player_id) for
## fast dispatch on receive. Cleared when players
## join or leave.
var _node_lookup: Dictionary = {}


## Collect pending states from all nodes, serialize
## into bundles, and send to peers.
func _send_bundles() -> void:
	var nodes: Array[ReconcilableState] = (
		Netcode.frame_driver._networked_state_nodes
	)

	# Collect all pending states and pre-serialize
	# using raw byte packing.
	var entries: Array = []
	for node in nodes:
		if not is_instance_valid(node):
			continue
		var states: Array = (
			node.consume_pending_bundle_states()
		)
		if states.is_empty():
			continue
		for state in states:
			var state_bytes := _encode_state(
				state, node._pack_types,
			)
			ArrayPool.release(state)
			entries.append({
				"type": node._get_type(),
				"player_id": node.player_id,
				"state_bytes": state_bytes,
				"peer_id": node.peer_id,
			})

	if entries.is_empty():
		return

	if Netcode.runs_server_logic:
		_send_server_bundles(entries)
	elif Netcode.is_client:
		_send_client_bundle(entries)


func _send_server_bundles(
	entries: Array,
) -> void:
	var peer_ids := multiplayer.get_peers()
	for target_peer_id in peer_ids:
		var bundle := _build_bundle_for_peer(
			entries, target_peer_id,
		)
		if bundle.is_empty():
			continue
		_client_rpc_receive_bundle.rpc_id(
			target_peer_id, bundle,
		)


func _send_client_bundle(
	entries: Array,
) -> void:
	var bundle := _build_bundle_all(entries)
	if bundle.is_empty():
		return
	_server_rpc_receive_input_bundle.rpc_id(
		NetworkConnector.SERVER_ID, bundle,
	)


## Build a bundle for a specific peer, filtering
## out ForwardedInput entries owned by that peer.
func _build_bundle_for_peer(
	entries: Array,
	target_peer_id: int,
) -> PackedByteArray:
	var filtered: Array = []
	for entry in entries:
		var is_forwarded: bool = (
			entry.type
			== ReconcilableState
				.ReconcilableStateType
				.FORWARDED_INPUT
		)
		if (
			is_forwarded
			and entry.peer_id == target_peer_id
		):
			continue
		filtered.append(entry)

	return _serialize_entries(filtered)


## Build a bundle from all entries (no filtering).
func _build_bundle_all(
	entries: Array,
) -> PackedByteArray:
	return _serialize_entries(entries)


## Serialize entries into a PackedByteArray bundle.
func _serialize_entries(
	entries: Array,
) -> PackedByteArray:
	if entries.is_empty():
		return PackedByteArray()

	var bundle := PackedByteArray()
	bundle.append(entries.size())
	for entry in entries:
		bundle.append(entry.type)
		bundle.append(entry.player_id & 0xFF)
		var state_bytes: PackedByteArray = (
			entry.state_bytes
		)
		var length := state_bytes.size()
		bundle.append(length & 0xFF)
		bundle.append((length >> 8) & 0xFF)
		bundle.append_array(state_bytes)

	return bundle


@rpc(
	"authority", "call_remote", "unreliable",
	NetworkConnector.RPC_CHANNEL_DEFAULT,
)
func _client_rpc_receive_bundle(
	bundle_data: PackedByteArray,
) -> void:
	_unpack_and_dispatch(bundle_data)


@rpc(
	"any_peer", "call_remote", "unreliable",
	NetworkConnector.RPC_CHANNEL_DEFAULT,
)
func _server_rpc_receive_input_bundle(
	bundle_data: PackedByteArray,
) -> void:
	_unpack_and_dispatch(bundle_data)


## Unpack a bundle and dispatch each entity's state
## to the corresponding ReconcilableState node.
## Decodes raw bytes directly into pool-acquired
## Arrays (zero GC-triggering allocations).
func _unpack_and_dispatch(
	bundle_data: PackedByteArray,
) -> void:
	if bundle_data.size() < 1:
		return

	var offset := 0
	var entity_count: int = bundle_data[offset]
	offset += 1

	for _i in entity_count:
		# Need at least 4 bytes for header.
		if offset + 4 > bundle_data.size():
			Netcode.log.warning(
				"StateBundler: bundle truncated"
				+ " at entity header",
				NetworkLogger
					.CATEGORY_NETWORK_SYNC,
			)
			return

		var entity_type: int = (
			bundle_data[offset]
		)
		offset += 1

		var player_id_byte: int = (
			bundle_data[offset]
		)
		offset += 1
		# Convert unsigned byte to signed.
		var player_id: int = (
			player_id_byte
			if player_id_byte < 128
			else player_id_byte - 256
		)

		var data_length: int = (
			bundle_data[offset]
			| (bundle_data[offset + 1] << 8)
		)
		offset += 2

		if offset + data_length > bundle_data.size():
			Netcode.log.warning(
				"StateBundler: entity data"
				+ " truncated",
				NetworkLogger
					.CATEGORY_NETWORK_SYNC,
			)
			return

		var node := _find_node(
			entity_type, player_id,
		)
		if node == null:
			if Netcode.log.is_verbose:
				Netcode.log.verbose(
					"StateBundler: no node for"
					+ " type=%d player=%d"
					% [entity_type, player_id],
					NetworkLogger
						.CATEGORY_NETWORK_SYNC,
				)
			# Skip this entity's data.
			offset += data_length
			continue

		var state := _decode_state(
			bundle_data,
			offset,
			data_length,
			node._pack_types,
		)
		offset += data_length

		node._handle_new_state_from_network(state)


# =============================================================
# Raw byte encoding/decoding
# =============================================================


## Encode a state Array into raw bytes using the
## node's type layout. Handles both standard states
## and extended states with redundant input history.
static func _encode_state(
	state: Array,
	pack_types: Array[int],
) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	var standard_size := pack_types.size() + 2

	# Encode synced properties.
	for i in range(pack_types.size()):
		match pack_types[i]:
			ReconcilableState.PackType.VECTOR2:
				var v: Vector2 = state[i]
				buf.put_float(v.x)
				buf.put_float(v.y)
			ReconcilableState.PackType.FLOAT:
				buf.put_float(state[i])
			_:
				buf.put_32(state[i])

	# frame_authority (1 byte).
	buf.put_u8(state[pack_types.size()])
	# frame_index (4 bytes).
	buf.put_32(state[pack_types.size() + 1])

	# Redundant input (if present). Extra elements
	# beyond standard_size are: [count, frame0,
	# actions0, frame1, actions1, ...].
	if state.size() > standard_size:
		var extra_start := standard_size
		var redundant_count: int = (
			state[extra_start]
		)
		buf.put_u8(redundant_count)
		for j in redundant_count:
			var idx := extra_start + 1 + j * 2
			buf.put_32(state[idx])
			buf.put_32(state[idx + 1])

	return buf.data_array


## Decode raw bytes into a pool-acquired state Array.
## Zero temporary allocations. Handles both standard
## and extended (redundant input) formats.
static func _decode_state(
	data: PackedByteArray,
	offset: int,
	data_length: int,
	pack_types: Array[int],
) -> Array:
	var standard_byte_size := 0
	for pt in pack_types:
		if pt == ReconcilableState.PackType.VECTOR2:
			standard_byte_size += 8
		else:
			standard_byte_size += 4
	# frame_authority (1) + frame_index (4).
	standard_byte_size += 5

	var has_redundant := (
		data_length > standard_byte_size
	)
	var redundant_count := 0
	if has_redundant:
		# Peek at redundant count to size the array.
		redundant_count = data[
			offset + standard_byte_size
		]

	var standard_size := pack_types.size() + 2
	var extra_size := (
		(1 + redundant_count * 2)
		if has_redundant
		else 0
	)
	var state := ArrayPool.acquire(
		standard_size + extra_size,
	)
	var pos := offset

	# Decode synced properties.
	for i in range(pack_types.size()):
		match pack_types[i]:
			ReconcilableState.PackType.VECTOR2:
				var x := data.decode_float(pos)
				pos += 4
				var y := data.decode_float(pos)
				pos += 4
				state[i] = Vector2(x, y)
			ReconcilableState.PackType.FLOAT:
				state[i] = data.decode_float(pos)
				pos += 4
			_:
				state[i] = data.decode_s32(pos)
				pos += 4

	# frame_authority (1 byte).
	state[pack_types.size()] = data[pos]
	pos += 1
	# frame_index (4 bytes).
	state[pack_types.size() + 1] = (
		data.decode_s32(pos)
	)
	pos += 4

	# Decode redundant input (if present).
	if has_redundant:
		var idx := standard_size
		state[idx] = redundant_count
		idx += 1
		pos += 1 # Skip redundant_count byte.
		for _j in redundant_count:
			state[idx] = data.decode_s32(pos)
			pos += 4
			idx += 1
			state[idx] = data.decode_s32(pos)
			pos += 4
			idx += 1

	return state


## Find the ReconcilableState node matching the given
## entity type and player ID. Uses a cached lookup
## table for fast dispatch.
func _find_node(
	entity_type: int,
	player_id: int,
) -> ReconcilableState:
	var key := entity_type * 1000 + player_id
	if _node_lookup.has(key):
		var cached: ReconcilableState = (
			_node_lookup[key]
		)
		if is_instance_valid(cached):
			return cached
		_node_lookup.erase(key)

	# Search in frame driver's registered nodes.
	var nodes: Array[ReconcilableState] = (
		Netcode.frame_driver._networked_state_nodes
	)
	for node in nodes:
		if not is_instance_valid(node):
			continue
		if (
			node._get_type() == entity_type
			and node.player_id == player_id
		):
			_node_lookup[key] = node
			return node

	return null


## Clear the lookup cache. Call when players join
## or leave.
func clear_lookup() -> void:
	_node_lookup.clear()
