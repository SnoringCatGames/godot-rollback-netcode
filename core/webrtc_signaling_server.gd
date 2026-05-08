class_name WebRTCSignalingServer
extends Node
## Lightweight WebSocket server for WebRTC signaling.
##
## Runs on the game server alongside the game. Handles
## SDP/ICE exchange so clients can establish WebRTC
## DataChannel connections.
##
## Lifecycle:
## 1. start() begins listening for WebSocket connections.
## 2. Clients connect, send SDP offers, receive answers.
## 3. ICE candidates are exchanged bidirectionally.
## 4. Once the DataChannel opens, the signaling
##    WebSocket is closed.
## 5. stop() shuts down the signaling server.

## Emitted when a client completes WebRTC signaling.
## peer_connection is the configured WebRTCPeerConnection.
## peer_id is the multiplayer peer ID for the client.
signal peer_signaled(
	peer_connection: WebRTCPeerConnection,
	peer_id: int,
)

const _SIGNALING_TIMEOUT_SEC := 30.0

var _tcp_server: TCPServer
var _ws_peers: Array[WebSocketPeer] = []
var _port: int = 0
var _is_running := false

# Maps WebSocket peer index to assigned multiplayer
# peer ID. Populated from the client's offer message.
var _ws_to_peer_id: Dictionary = {}

# Maps WebSocket peer index to its
# WebRTCPeerConnection.
var _ws_to_rtc: Dictionary = {}

# Tracks which ws_index peers have already emitted
# the peer_signaled signal.
var _ws_signaled: Dictionary = {}

# Tracks connection start time per WebSocket peer for
# timeout detection.
var _ws_connect_time: Dictionary = {}

# Buffers client ICE candidates that arrive before
# the offer is processed (before the
# WebRTCPeerConnection exists). Applied after
# _handle_offer creates the RTC.
var _ws_buffered_ice: Dictionary = {}

# External host UDP port the deploy platform mapped to the
# game-data container port. Used to rewrite STUN-reflected
# srflx ICE candidates (which carry the container port, since
# Edgegap uses port-preserving NAT inside the container). Set
# from Netcode.settings.host_udp_port at offer time; falls
# back to (client_server_port - 1) for legacy GameLift-style
# deploys where signaling and game ports were contiguous.
# Zero means no rewriting.
var _host_udp_port: int = 0

## The single ICE container port. All
## WebRTCPeerConnections share this port via
## libdatachannel's libjuice mux mode.
var _ice_port: int = 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func start(port: int) -> void:
	_port = port
	_tcp_server = TCPServer.new()
	var result := _tcp_server.listen(port)
	if result != OK:
		Netcode.log.error(
			"WebRTC signaling server failed to"
			+ " listen on port %d: error=%d"
			% [port, result],
			NetworkLogger.CATEGORY_CONNECTIONS,
		)
		return

	_is_running = true
	Netcode.log.print(
		"WebRTC signaling server started on"
		+ " port %d" % port,
		NetworkLogger.CATEGORY_CONNECTIONS,
	)


func stop() -> void:
	_is_running = false

	for ws in _ws_peers:
		if ws.get_ready_state() != WebSocketPeer.STATE_CLOSED:
			ws.close()
	_ws_peers.clear()
	_ws_to_peer_id.clear()
	_ws_to_rtc.clear()
	_ws_signaled.clear()
	_ws_connect_time.clear()
	_ws_buffered_ice.clear()
	_host_udp_port = 0
	_ice_port = 0

	if _tcp_server != null:
		_tcp_server.stop()
		_tcp_server = null

	Netcode.log.print(
		"WebRTC signaling server stopped",
		NetworkLogger.CATEGORY_CONNECTIONS,
	)


func _process(_delta: float) -> void:
	if not _is_running:
		return

	# Accept new TCP connections.
	while _tcp_server.is_connection_available():
		var tcp := _tcp_server.take_connection()
		if tcp == null:
			continue
		var ws := WebSocketPeer.new()
		ws.accept_stream(tcp)
		var index := _ws_peers.size()
		_ws_peers.append(ws)
		_ws_connect_time[index] = (
			Time.get_ticks_msec())
		Netcode.log.print(
			"Signaling: new WebSocket connection"
			+ " (index %d)" % index,
			NetworkLogger.CATEGORY_CONNECTIONS,
		)

	# Poll existing WebSocket peers.
	var to_remove: Array[int] = []
	for i in range(_ws_peers.size()):
		var ws: WebSocketPeer = _ws_peers[i]
		ws.poll()

		var state := ws.get_ready_state()
		if state == WebSocketPeer.STATE_CLOSED:
			to_remove.append(i)
			continue

		if state != WebSocketPeer.STATE_OPEN:
			# Check timeout for connecting peers.
			var elapsed: float = (
				(Time.get_ticks_msec()
					- _ws_connect_time.get(i, 0))
				/ 1000.0)
			if elapsed > _SIGNALING_TIMEOUT_SEC:
				Netcode.log.warning(
					"Signaling: peer %d timed out"
					% i,
					NetworkLogger
						.CATEGORY_CONNECTIONS,
				)
				ws.close()
				to_remove.append(i)
			continue

		# Read all available messages.
		while ws.get_available_packet_count() > 0:
			var packet := ws.get_packet()
			var text := packet.get_string_from_utf8()
			_handle_message(i, ws, text)

	# Poll RTC peer connections that have NOT yet
	# been handed off to WebRTCGamePeer. After
	# peer_signaled (add_peer), the custom peer
	# owns the connection and handles polling.
	# Double-polling causes instability.
	for ws_idx in _ws_to_rtc:
		if _ws_signaled.has(ws_idx):
			continue
		var rtc_peer: WebRTCPeerConnection = (
			_ws_to_rtc[ws_idx])
		rtc_peer.poll()

	# Clean up closed peers (reverse order to
	# preserve indices).
	to_remove.reverse()
	for i in to_remove:
		_cleanup_ws_peer(i)


func _handle_message(
	ws_index: int,
	ws: WebSocketPeer,
	text: String,
) -> void:
	var data = JSON.parse_string(text)
	if data == null or not data is Dictionary:
		Netcode.log.warning(
			"Signaling: invalid JSON from peer %d"
			% ws_index,
			NetworkLogger.CATEGORY_CONNECTIONS,
		)
		return

	var msg_type: String = data.get("type", "")
	match msg_type:
		"offer":
			_handle_offer(ws_index, ws, data)
		"ice":
			_handle_client_ice(ws_index, data)
		_:
			Netcode.log.warning(
				"Signaling: unknown message type"
				+ " '%s' from peer %d"
				% [msg_type, ws_index],
				NetworkLogger.CATEGORY_CONNECTIONS,
			)


func _handle_offer(
	ws_index: int,
	ws: WebSocketPeer,
	data: Dictionary,
) -> void:
	# Determine the external host UDP port for ICE
	# srflx-candidate rewriting.
	#
	# Preferred: Netcode.settings.host_udp_port set
	# from the deploy env at boot (Edgegap exposes
	# this as ARBITRARIUM_PORT_4433_UDP_EXTERNAL).
	# Direct env-driven path is correct on platforms
	# like Edgegap where the signaling and game
	# ports are not contiguous.
	#
	# Legacy fallback: derive from the client-supplied
	# WSS port assuming WSS = UDP + 1 (GameLift's
	# contiguous-pair allocation). Wrong on Edgegap;
	# kept only for backwards compatibility with
	# older deploy environments.
	if _host_udp_port == 0:
		var configured := int(
			Netcode.settings.host_udp_port)
		if configured > 0:
			_host_udp_port = configured
			Netcode.log.print(
				("Signaling: host UDP port = %d"
				+ " (from env / settings)")
				% _host_udp_port,
				NetworkLogger.CATEGORY_CONNECTIONS,
			)
	var client_server_port: int = data.get(
		"server_port", 0)
	if (client_server_port > 0
			and _host_udp_port == 0):
		_host_udp_port = client_server_port - 1
		Netcode.log.print(
			("Signaling: host UDP port = %d"
			+ " (legacy GameLift fallback;"
			+ " from client WSS port %d)")
			% [_host_udp_port, client_server_port],
			NetworkLogger.CATEGORY_CONNECTIONS,
		)

	var peer_id: int = data.get("peer_id", 0)
	if peer_id <= 0:
		Netcode.log.warning(
			"Signaling: offer missing peer_id",
			NetworkLogger.CATEGORY_CONNECTIONS,
		)
		return

	var sdp: String = data.get("sdp", "")
	if sdp.is_empty():
		Netcode.log.warning(
			"Signaling: offer missing SDP",
			NetworkLogger.CATEGORY_CONNECTIONS,
		)
		return

	_ws_to_peer_id[ws_index] = peer_id

	Netcode.log.print(
		"Signaling: received offer from"
		+ " peer_id=%d (ws_index=%d)"
		% [peer_id, ws_index],
		NetworkLogger.CATEGORY_CONNECTIONS,
	)

	# Create a WebRTCPeerConnection for this client.
	var rtc := WebRTCPeerConnection.new()

	# Connect signals BEFORE initialize so we
	# don't miss early ICE candidates.
	rtc.ice_candidate_created.connect(
		_on_server_ice_candidate.bind(ws_index))
	rtc.session_description_created.connect(
		_on_session_description.bind(ws_index))

	# Initialize ICE agent with STUN server.
	# Must happen before add_peer.
	#
	# All WebRTCPeerConnections share the same ICE
	# port via libdatachannel's libjuice mux mode.
	# When portRangeBegin == portRangeEnd, libjuice
	# creates a shared UDP socket that multiplexes
	# STUN traffic across agents using ufrag.
	if _ice_port == 0:
		_ice_port = Netcode.server_port

	var init_err := rtc.initialize({
		"iceServers": [
			{"urls": ["stun:stun.l.google.com:19302"]},
		],
		"portRangeBegin": _ice_port,
		"portRangeEnd": _ice_port,
		"enableIceUdpMux": true,
	})
	if init_err != OK:
		Netcode.log.error(
			("Signaling: initialize failed"
			+ " for ws_index=%d: %d")
			% [ws_index, init_err],
			NetworkLogger.CATEGORY_CONNECTIONS,
		)
	else:
		Netcode.log.print(
			("Signaling: RTC initialized for"
			+ " ws_index=%d, ICE port=%d")
			% [ws_index, _ice_port],
			NetworkLogger.CATEGORY_CONNECTIONS,
		)

	# Emit peer_signaled so the custom peer can
	# call add_peer() and create DataChannels.
	_ws_to_rtc[ws_index] = rtc
	peer_signaled.emit(rtc, peer_id)
	# Mark as handed off so we stop polling this
	# RTC. WebRTCGamePeer owns it now.
	_ws_signaled[ws_index] = true

	# Set the remote description (client's offer).
	# Log the SDP length and first line for
	# debugging format differences between
	# libdatachannel (native) and browser WebRTC.
	Netcode.log.print(
		("Signaling: calling"
		+ " set_remote_description for"
		+ " ws_index=%d, sdp_len=%d,"
		+ " first_line='%s'")
		% [
			ws_index,
			sdp.length(),
			sdp.get_slice("\r\n", 0)
				.left(60),
		],
		NetworkLogger.CATEGORY_CONNECTIONS,
	)
	var desc_err := rtc.set_remote_description(
		"offer", sdp)
	if desc_err != OK:
		Netcode.log.error(
			("Signaling: set_remote_description"
			+ " failed for ws_index=%d: %d")
			% [ws_index, desc_err],
			NetworkLogger.CATEGORY_CONNECTIONS,
		)
	else:
		Netcode.log.print(
			("Signaling: set_remote_description"
			+ " OK for ws_index=%d,"
			+ " gathering=%d, signaling=%d")
			% [
				ws_index,
				rtc.get_gathering_state(),
				rtc.get_signaling_state(),
			],
			NetworkLogger.CATEGORY_CONNECTIONS,
		)

	# Flush buffered client ICE candidates that
	# arrived before the offer.
	if _ws_buffered_ice.has(ws_index):
		var buffered: Array = (
			_ws_buffered_ice[ws_index])
		_ws_buffered_ice.erase(ws_index)
		Netcode.log.print(
			"Signaling: flushing %d buffered"
			+ " ICE candidates for ws_index=%d"
			% [buffered.size(), ws_index],
			NetworkLogger.CATEGORY_CONNECTIONS,
		)
		for ice_data in buffered:
			_handle_client_ice(ws_index, ice_data)


func _on_session_description(
	type: String,
	sdp: String,
	ws_index: int,
) -> void:
	Netcode.log.print(
		("Signaling: session_description_created"
		+ " type=%s ws_index=%d sdp_len=%d")
		% [type, ws_index, sdp.length()],
		NetworkLogger.CATEGORY_CONNECTIONS,
	)
	if not _ws_to_rtc.has(ws_index):
		return

	var rtc: WebRTCPeerConnection = (
		_ws_to_rtc[ws_index])

	if type == "answer":
		# Set local description and send answer to
		# client.
		rtc.set_local_description(type, sdp)

		var ws_idx := ws_index
		if ws_idx >= _ws_peers.size():
			return
		var ws: WebSocketPeer = _ws_peers[ws_idx]
		if (ws.get_ready_state()
				!= WebSocketPeer.STATE_OPEN):
			return

		var answer := JSON.stringify({
			"type": "answer",
			"sdp": sdp,
		})
		ws.send_text(answer)

		Netcode.log.print(
			"Signaling: sent answer to"
			+ " ws_index=%d" % ws_index,
			NetworkLogger.CATEGORY_CONNECTIONS,
		)


func _on_server_ice_candidate(
	media: String,
	index: int,
	candidate_name: String,
	ws_index: int,
) -> void:
	if ws_index >= _ws_peers.size():
		Netcode.log.warning(
			"Signaling: server ICE candidate"
			+ " dropped (ws_index %d >="
			+ " peers.size %d): %s"
			% [ws_index, _ws_peers.size(),
				candidate_name],
			NetworkLogger.CATEGORY_CONNECTIONS,
		)
		return
	var ws: WebSocketPeer = _ws_peers[ws_index]
	if (ws.get_ready_state()
			!= WebSocketPeer.STATE_OPEN):
		Netcode.log.warning(
			"Signaling: server ICE candidate"
			+ " dropped (ws_state=%d): %s"
			% [ws.get_ready_state(),
				candidate_name],
			NetworkLogger.CATEGORY_CONNECTIONS,
		)
		return

	# Rewrite the srflx candidate port to the external
	# host port. The ICE agent binds to the container
	# port (4433); clients must connect to the host
	# port the deploy platform forwarded that container
	# port to (e.g., Edgegap's ARBITRARIUM_PORT_4433_
	# UDP_EXTERNAL → 32574).
	var rewritten := candidate_name
	if (_host_udp_port > 0
			and "typ srflx" in candidate_name):
		var parts := candidate_name.split(" ")
		if parts.size() >= 6:
			var old_port := parts[5]
			parts[5] = str(_host_udp_port)
			rewritten = " ".join(parts)
			Netcode.log.print(
				("Signaling: rewrote srflx port"
				+ " %s -> %d")
				% [old_port, _host_udp_port],
				NetworkLogger.CATEGORY_CONNECTIONS,
			)

	Netcode.log.print(
		"Signaling: sending server ICE"
		+ " candidate to ws_index=%d: %s"
		% [ws_index, rewritten],
		NetworkLogger.CATEGORY_CONNECTIONS,
	)
	var msg := JSON.stringify({
		"type": "ice",
		"candidate": rewritten,
		"mid": media,
		"index": index,
	})
	ws.send_text(msg)


func _handle_client_ice(
	ws_index: int,
	data: Dictionary,
) -> void:
	var candidate: String = data.get("candidate", "")
	var mid: String = data.get("mid", "")
	var index: int = data.get("index", 0)

	if candidate.is_empty():
		return

	# Buffer if the RTC connection does not exist
	# yet (candidate arrived before the offer).
	if not _ws_to_rtc.has(ws_index):
		if not _ws_buffered_ice.has(ws_index):
			_ws_buffered_ice[ws_index] = []
		_ws_buffered_ice[ws_index].append(data)
		Netcode.log.print(
			"Signaling: buffered client ICE"
			+ " from ws_index=%d (no RTC yet): %s"
			% [ws_index, candidate],
			NetworkLogger.CATEGORY_CONNECTIONS,
		)
		return

	var rtc: WebRTCPeerConnection = (
		_ws_to_rtc[ws_index])

	Netcode.log.print(
		"Signaling: received client ICE"
		+ " from ws_index=%d: %s"
		% [ws_index, candidate],
		NetworkLogger.CATEGORY_CONNECTIONS,
	)
	rtc.add_ice_candidate(mid, index, candidate)


## Called by NetworkConnector when a WebRTC peer
## finishes signaling and the DataChannel is ready.
## Returns the WebRTCPeerConnection for the given
## multiplayer peer ID, or null if not found.
func get_peer_connection(
	peer_id: int,
) -> WebRTCPeerConnection:
	for ws_index in _ws_to_peer_id:
		if _ws_to_peer_id[ws_index] == peer_id:
			return _ws_to_rtc.get(ws_index)
	return null


## Returns all completed WebRTCPeerConnections mapped
## by their multiplayer peer ID.
func get_all_peer_connections() -> Dictionary:
	var result := {}
	for ws_index in _ws_to_peer_id:
		var pid: int = _ws_to_peer_id[ws_index]
		if _ws_to_rtc.has(ws_index):
			result[pid] = _ws_to_rtc[ws_index]
	return result


## Notify the signaling server that a peer's
## DataChannel is open. Sends a "connected" message
## and closes the signaling WebSocket.
func notify_peer_connected(
	ws_index: int,
	peer_id: int,
) -> void:
	if ws_index >= _ws_peers.size():
		return
	var ws: WebSocketPeer = _ws_peers[ws_index]
	if (ws.get_ready_state()
			!= WebSocketPeer.STATE_OPEN):
		return

	var msg := JSON.stringify({
		"type": "connected",
		"peer_id": peer_id,
	})
	ws.send_text(msg)

	# Close signaling WebSocket after a short delay
	# to ensure the message is sent.
	_close_ws_deferred.call_deferred(ws_index)


func _close_ws_deferred(ws_index: int) -> void:
	if ws_index < _ws_peers.size():
		_ws_peers[ws_index].close()


func _cleanup_ws_peer(index: int) -> void:
	var was_signaled := _ws_signaled.has(index)
	_ws_to_peer_id.erase(index)
	_ws_signaled.erase(index)
	if _ws_to_rtc.has(index):
		# Only close the RTC connection if signaling
		# did not complete. Completed connections are
		# owned by the WebRTCGamePeer.
		if not was_signaled:
			var rtc: WebRTCPeerConnection = (
				_ws_to_rtc[index])
			rtc.close()
		_ws_to_rtc.erase(index)
	_ws_connect_time.erase(index)


## Parses a signaling message from JSON text.
## Returns a Dictionary with type, sdp, candidate,
## mid, index, and peer_id fields. Returns an empty
## Dictionary if parsing fails.
static func parse_message(
	text: String,
) -> Dictionary:
	var data = JSON.parse_string(text)
	if data == null or not data is Dictionary:
		return {}
	return data


## Serializes a signaling message to JSON text.
static func serialize_message(
	data: Dictionary,
) -> String:
	return JSON.stringify(data)
