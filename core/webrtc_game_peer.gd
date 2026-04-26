class_name WebRTCGamePeer
extends MultiplayerPeerExtension
## Custom MultiplayerPeer using raw WebRTC DataChannels.
##
## Replaces WebRTCMultiplayerPeer with 2 negotiated
## DataChannels instead of 6-8 SCTP streams. Fewer
## SCTP streams means less congestion window
## contention. The unreliable channel uses
## ordered=false + maxRetransmits=0 for true
## fire-and-forget delivery.

## DataChannel SCTP IDs (negotiated, must match on
## both sides).
const _CHANNEL_ID_RELIABLE := 1
const _CHANNEL_ID_UNRELIABLE := 2

const _MAX_PACKET_SIZE := 65536

## Per-peer connection state.
class PeerState:
	var rtc: WebRTCPeerConnection
	var reliable: WebRTCDataChannel
	var unreliable: WebRTCDataChannel
	var is_connected := false
	## Tracks last logged ICE connection state for
	## change detection.
	var last_ice_state: int = -1

## Queued incoming packet.
class IncomingPacket:
	var data: PackedByteArray
	var from_peer: int
	var channel: int
	var transfer_mode: int

var _unique_id: int = 0
var _is_server := false
var _is_active := false
var _refuse_connections := false

## Maps peer_id -> PeerState.
var _peers: Dictionary = {}

## Incoming packet FIFO queue.
var _incoming: Array[IncomingPacket] = []

## Current transfer settings for put_packet.
var _transfer_mode: int = (
	MultiplayerPeer.TRANSFER_MODE_RELIABLE)
var _transfer_channel: int = 0
var _target_peer: int = 0


## Create this peer in server mode (unique_id = 1).
func create_server() -> void:
	_unique_id = 1
	_is_server = true
	_is_active = true


## Create this peer in client mode with the given ID.
func create_client(client_id: int) -> void:
	_unique_id = client_id
	_is_server = false
	_is_active = true


## Add a WebRTCPeerConnection and create the 2
## negotiated DataChannels (reliable + unreliable).
## Call after ICE setup, before signaling progresses.
func add_peer(
	rtc: WebRTCPeerConnection,
	peer_id: int,
) -> void:
	if _peers.has(peer_id):
		Netcode.log.warning(
			"WebRTCGamePeer: peer %d already"
			+ " exists" % peer_id,
			NetworkLogger.CATEGORY_CONNECTIONS,
		)
		return

	var state := PeerState.new()
	state.rtc = rtc

	# Create 2 negotiated DataChannels. Both sides
	# create them independently with matching IDs.
	state.reliable = rtc.create_data_channel(
		"reliable", {
			"negotiated": true,
			"id": _CHANNEL_ID_RELIABLE,
			"ordered": true,
		})
	state.unreliable = rtc.create_data_channel(
		"unreliable", {
			"negotiated": true,
			"id": _CHANNEL_ID_UNRELIABLE,
			"ordered": false,
			"maxRetransmits": 0,
		})

	_peers[peer_id] = state

	Netcode.log.print(
		"WebRTCGamePeer: added peer %d"
		% peer_id,
		NetworkLogger.CATEGORY_CONNECTIONS,
	)


## Remove and close a specific peer.
func remove_peer(peer_id: int) -> void:
	if not _peers.has(peer_id):
		return
	var state: PeerState = _peers[peer_id]
	if state.reliable != null:
		state.reliable.close()
	if state.unreliable != null:
		state.unreliable.close()
	if state.rtc != null:
		state.rtc.close()
	_peers.erase(peer_id)


# =============================================================
# MultiplayerPeerExtension virtual methods
# =============================================================


func _poll() -> void:
	if not _is_active:
		return

	# Two-pass polling: first pass polls connections,
	# drains channels, and detects state changes.
	# Second pass emits signals AFTER all channels
	# are drained. This ensures packets are queued
	# in _incoming before SceneMultiplayer processes
	# peer_connected (which triggers PEER_CONFIG
	# sends and RPC processing).
	var newly_connected: Array[int] = []
	var newly_disconnected: Array[int] = []

	var peer_ids := _peers.keys()
	for peer_id in peer_ids:
		if not _peers.has(peer_id):
			continue
		var state: PeerState = _peers[peer_id]

		# Poll the WebRTCPeerConnection.
		state.rtc.poll()

		# Log ICE connection state changes for
		# debugging port-mapping and NAT issues.
		var ice_state := (
			state.rtc.get_connection_state())
		if ice_state != state.last_ice_state:
			state.last_ice_state = ice_state
			Netcode.log.print(
				("WebRTCGamePeer: peer %d ICE"
				+ " state -> %d") % [
					peer_id, ice_state],
				NetworkLogger.CATEGORY_CONNECTIONS,
			)

		# Check DataChannel readiness.
		var was_connected := state.is_connected
		var all_open := (
			_is_channel_open(state.reliable)
			and _is_channel_open(state.unreliable))

		if all_open and not was_connected:
			state.is_connected = true
			Netcode.log.print(
				("WebRTCGamePeer: peer %d channels"
				+ " open") % peer_id,
				NetworkLogger.CATEGORY_CONNECTIONS,
			)
			newly_connected.append(peer_id)

		if not all_open and was_connected:
			# Check if connection was lost. Include
			# STATE_DISCONNECTED to avoid waiting
			# for the ICE failed timeout (15-30s).
			var conn_state := (
				state.rtc.get_connection_state())
			if (conn_state
					== WebRTCPeerConnection
						.STATE_DISCONNECTED
					or conn_state
					== WebRTCPeerConnection
						.STATE_CLOSED
					or conn_state
					== WebRTCPeerConnection
						.STATE_FAILED):
				state.is_connected = false
				Netcode.log.print(
					("WebRTCGamePeer: peer %d"
					+ " disconnected") % peer_id,
					NetworkLogger
						.CATEGORY_CONNECTIONS,
				)
				newly_disconnected.append(peer_id)

		if not state.is_connected:
			continue

		# Drain incoming packets from all channels.
		_drain_channel(
			state.reliable,
			peer_id,
			MultiplayerPeer.TRANSFER_MODE_RELIABLE,
		)
		_drain_channel(
			state.unreliable,
			peer_id,
			MultiplayerPeer
				.TRANSFER_MODE_UNRELIABLE,
		)

	# Second pass: emit signals after all channels
	# are drained.
	for peer_id in newly_connected:
		emit_signal("peer_connected", peer_id)
	for peer_id in newly_disconnected:
		emit_signal("peer_disconnected", peer_id)



func _get_packet_script() -> PackedByteArray:
	if _incoming.is_empty():
		return PackedByteArray()
	var pkt: IncomingPacket = _incoming[0]
	_incoming.remove_at(0)
	return pkt.data


func _put_packet_script(
	p_buffer: PackedByteArray,
) -> Error:
	if not _is_active:
		return Error.ERR_UNCONFIGURED

	var target := _target_peer
	var mode := _transfer_mode
	var channel := _transfer_channel

	if _is_server:
		if target == 0:
			# Broadcast to all connected peers.
			for peer_id in _peers:
				var state: PeerState = (
					_peers[peer_id])
				if state.is_connected:
					_send_to_peer(
						state, p_buffer,
						mode, channel)
		elif target < 0:
			# Negative = broadcast excluding abs(target).
			var exclude := -target
			for peer_id in _peers:
				if peer_id == exclude:
					continue
				var state: PeerState = (
					_peers[peer_id])
				if state.is_connected:
					_send_to_peer(
						state, p_buffer,
						mode, channel)
		else:
			# Send to specific peer.
			if _peers.has(target):
				var state: PeerState = (
					_peers[target])
				if state.is_connected:
					_send_to_peer(
						state, p_buffer,
						mode, channel)
	else:
		# Client: send to server (peer 1).
		if _peers.has(1):
			var state: PeerState = _peers[1]
			if state.is_connected:
				_send_to_peer(
					state, p_buffer,
					mode, channel)

	return Error.OK


func _get_available_packet_count() -> int:
	return _incoming.size()


func _get_packet_peer() -> int:
	if _incoming.is_empty():
		return 0
	return _incoming[0].from_peer


func _get_packet_channel() -> int:
	if _incoming.is_empty():
		return 0
	return _incoming[0].channel


func _get_packet_mode() -> int:
	if _incoming.is_empty():
		return MultiplayerPeer.TRANSFER_MODE_RELIABLE
	return _incoming[0].transfer_mode


func _get_unique_id() -> int:
	return _unique_id


func _get_connection_status() -> MultiplayerPeer.ConnectionStatus:
	if not _is_active:
		return MultiplayerPeer.CONNECTION_DISCONNECTED

	if _is_server:
		return MultiplayerPeer.CONNECTION_CONNECTED

	# Client: connected when server peer channels
	# are open.
	if _peers.has(1):
		var state: PeerState = _peers[1]
		if state.is_connected:
			return (
				MultiplayerPeer.CONNECTION_CONNECTED)

	return MultiplayerPeer.CONNECTION_CONNECTING


func _set_transfer_mode(p_mode: int) -> void:
	_transfer_mode = p_mode


func _get_transfer_mode() -> int:
	return _transfer_mode


func _set_transfer_channel(p_channel: int) -> void:
	_transfer_channel = p_channel


func _get_transfer_channel() -> int:
	return _transfer_channel


func _set_target_peer(p_peer: int) -> void:
	_target_peer = p_peer


func _get_max_packet_size() -> int:
	return _MAX_PACKET_SIZE


func _is_server_relay_supported() -> bool:
	# SceneMultiplayer handles relay. Clients only
	# connect to server, not to each other.
	return false


func _get_packet_script_channel() -> int:
	return _get_packet_channel()


func _get_packet_script_mode() -> int:
	return _get_packet_mode()


func _close() -> void:
	_is_active = false
	for peer_id in _peers.keys():
		remove_peer(peer_id)
	_peers.clear()
	_incoming.clear()


func _disconnect_peer(p_peer: int, p_force: bool) -> void:
	if not _peers.has(p_peer):
		return
	remove_peer(p_peer)
	emit_signal("peer_disconnected", p_peer)


func _is_refusing_new_connections() -> bool:
	return _refuse_connections


func _set_refuse_new_connections(p_enable: bool) -> void:
	_refuse_connections = p_enable


# =============================================================
# Internal helpers
# =============================================================


func _is_channel_open(
	channel: WebRTCDataChannel,
) -> bool:
	if channel == null:
		return false
	return (channel.get_ready_state()
		== WebRTCDataChannel.STATE_OPEN)


## Drain all available packets from a DataChannel
## and queue them as IncomingPackets.
func _drain_channel(
	channel: WebRTCDataChannel,
	from_peer: int,
	mode: int,
) -> void:
	if channel == null:
		return
	channel.poll()
	while (
		channel.get_available_packet_count() > 0
	):
		var raw := channel.get_packet()
		if raw.size() < 2:
			continue

		# First byte is the Godot transfer channel.
		var ch: int = raw[0]
		var payload := raw.slice(1)

		var pkt := IncomingPacket.new()
		pkt.data = payload
		pkt.from_peer = from_peer
		pkt.channel = ch
		pkt.transfer_mode = mode
		_incoming.append(pkt)


## Send a packet to a specific peer via the
## appropriate DataChannel based on transfer mode.
func _send_to_peer(
	state: PeerState,
	data: PackedByteArray,
	mode: int,
	channel: int,
) -> void:
	# Prepend 1-byte channel header.
	var header := PackedByteArray([channel])
	var packet := header + data

	var target_channel: WebRTCDataChannel
	match mode:
		MultiplayerPeer.TRANSFER_MODE_RELIABLE:
			target_channel = state.reliable
		_:
			target_channel = state.unreliable

	if (target_channel != null
			and _is_channel_open(target_channel)):
		target_channel.put_packet(packet)
