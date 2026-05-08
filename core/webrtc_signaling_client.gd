class_name WebRTCSignalingClient
extends Node
## Client-side WebRTC signaling via WebSocket.
##
## Connects to the game server's signaling WebSocket,
## exchanges SDP offer/answer and ICE candidates, then
## signals completion with the configured
## WebRTCPeerConnection ready for gameplay.
##
## Includes automatic retry for the Firefox DTLS bug
## in webrtc-native v1.0.9 (mbedTLS lacks ClientHello
## defragmentation).

## Emitted when the WebRTCPeerConnection is created
## (STATE_NEW), before signaling begins. The
## multiplayer peer must add_peer at this point.
signal peer_created(
	peer_connection: WebRTCPeerConnection,
)

## Emitted when signaling completes and the
## DataChannel is open.
signal completed(
	peer_connection: WebRTCPeerConnection,
)

## Emitted when signaling fails after all retries.
signal failed(error: String)

const _ATTEMPT_TIMEOUT_SEC := 10.0
const _MAX_RETRY_ATTEMPTS := 12
# Delay between attempts. The deploy backend (Edgegap)
# returns READY as soon as the container starts, but the
# Godot WebSocket server inside that container needs ~1s to
# bind. Without a delay, all 5 retries fire inside 500 ms and
# all hit a not-yet-bound server. With 750 ms spacing × 12
# attempts = ~9 seconds of patience, which absorbs even a
# cold-start under load.
const _RETRY_DELAY_MSEC := 750

var _ws: WebSocketPeer
var _rtc: WebRTCPeerConnection
var _peer_added := false
var _signaling_url := ""
var _peer_id: int = 0
var _server_port: int = 0
var _attempt_count := 0
var _attempt_start_msec := 0
var _next_attempt_at_msec: int = 0
var _is_active := false
var _is_completed := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


## Begin signaling. url is the WebSocket URL to the
## server's signaling endpoint. peer_id is the
## multiplayer peer ID assigned to this client.
func start(
	url: String,
	peer_id: int = 0,
	server_port: int = 0,
) -> void:
	_signaling_url = url
	_peer_id = peer_id
	_server_port = server_port
	_attempt_count = 0
	_is_completed = false
	_attempt_connect()


func stop() -> void:
	_is_active = false
	_is_completed = true
	_cleanup()


func _attempt_connect() -> void:
	_attempt_count += 1
	_is_active = true

	if _attempt_count > _MAX_RETRY_ATTEMPTS:
		_is_active = false
		Netcode.log.error(
			("WebRTC signaling failed after %d"
			+ " attempts") % _MAX_RETRY_ATTEMPTS,
			NetworkLogger.CATEGORY_CONNECTIONS,
		)
		failed.emit(
			("WebRTC signaling failed after %d"
			+ " attempts") % _MAX_RETRY_ATTEMPTS)
		return

	Netcode.log.print(
		"WebRTC signaling attempt %d/%d: %s"
		% [
			_attempt_count,
			_MAX_RETRY_ATTEMPTS,
			_signaling_url,
		],
		NetworkLogger.CATEGORY_CONNECTIONS,
	)

	_cleanup()

	# Create WebSocket connection to signaling
	# server.
	_ws = WebSocketPeer.new()
	var result := _ws.connect_to_url(_signaling_url)
	if result != OK:
		Netcode.log.error(
			"WebSocket connect failed: %d"
			% result,
			NetworkLogger.CATEGORY_CONNECTIONS,
		)
		_retry_or_fail()
		return

	_attempt_start_msec = Time.get_ticks_msec()


func _process(_delta: float) -> void:
	if not _is_active:
		return

	# Between attempts: idle until the retry-backoff window
	# elapses, then re-arm the WebSocket. Lets the server-side
	# Godot WS catch up after Edgegap reports the container
	# READY but before the in-container binds complete.
	if _ws == null:
		if Time.get_ticks_msec() >= _next_attempt_at_msec:
			_attempt_connect()
		return

	_ws.poll()

	var state := _ws.get_ready_state()

	# Check timeout. Applies to the entire
	# signaling attempt, not just the WebSocket
	# connection phase.
	var elapsed: float = (
		(Time.get_ticks_msec()
			- _attempt_start_msec)
		/ 1000.0)
	if elapsed > _ATTEMPT_TIMEOUT_SEC:
		Netcode.log.print(
			("WebRTC signaling attempt %d/%d"
			+ " timed out (%.1fs, ws_state=%d)")
			% [
				_attempt_count,
				_MAX_RETRY_ATTEMPTS,
				elapsed,
				state,
			],
			NetworkLogger.CATEGORY_CONNECTIONS,
		)
		_retry_or_fail()
		return

	if state == WebSocketPeer.STATE_CLOSED:
		if not _is_completed:
			var code := _ws.get_close_code()
			var reason := _ws.get_close_reason()
			Netcode.log.print(
				("Signaling WebSocket closed:"
				+ " code=%d reason='%s'")
				% [code, reason],
				NetworkLogger.CATEGORY_CONNECTIONS,
			)
			_retry_or_fail()
		return

	if state != WebSocketPeer.STATE_OPEN:
		return

	# WebSocket is open. If we haven't created the
	# RTC connection yet, do it now.
	if _rtc == null:
		_create_rtc_and_offer()

	# Poll the RTC peer connection ONLY before
	# add_peer. After peer_created emits (which
	# triggers add_peer), WebRTCGamePeer polls
	# the connection in _poll(). Double-polling
	# corrupts SCTP state.
	if _rtc != null and not _peer_added:
		_rtc.poll()

	# Read messages from signaling server.
	while _ws.get_available_packet_count() > 0:
		var packet := _ws.get_packet()
		var text := packet.get_string_from_utf8()
		_handle_message(text)

	# Check if ICE connection is established.
	if _rtc != null:
		var conn_state := _rtc.get_connection_state()
		if (conn_state
				== WebRTCPeerConnection
					.STATE_CONNECTED):
			_on_connection_established()


func _create_rtc_and_offer() -> void:
	_rtc = WebRTCPeerConnection.new()

	# Connect signals BEFORE initialize so we
	# don't miss early ICE candidates.
	_rtc.ice_candidate_created.connect(
		_on_local_ice_candidate)
	_rtc.session_description_created.connect(
		_on_session_description)

	# Initialize ICE agent with STUN server.
	# Must happen before add_peer and create_offer.
	var init_err := _rtc.initialize({
		"iceServers": [
			{"urls": ["stun:stun.l.google.com:19302"]},
		],
	})
	if init_err != OK:
		Netcode.log.error(
			"WebRTC: initialize failed: %d"
			% init_err,
			NetworkLogger.CATEGORY_CONNECTIONS,
		)

	# Emit peer_created so WebRTCGamePeer can call
	# add_peer() and create negotiated DataChannels.
	# The channels must exist before create_offer
	# so the SDP includes SCTP transport.
	_peer_added = true
	peer_created.emit(_rtc)

	# Create the offer. Requires DataChannels to
	# exist so SDP includes SCTP transport.
	var offer_err := _rtc.create_offer()
	if offer_err != OK:
		Netcode.log.error(
			"WebRTC: create_offer failed: %d"
			% offer_err,
			NetworkLogger.CATEGORY_CONNECTIONS,
		)

	Netcode.log.print(
		"WebRTC: created offer",
		NetworkLogger.CATEGORY_CONNECTIONS,
	)


func _on_session_description(
	type: String,
	sdp: String,
) -> void:
	if type == "offer":
		_rtc.set_local_description(type, sdp)

		# Send offer to signaling server. Include
		# the server's WSS port so the server can
		# derive the GameLift host UDP port for ICE
		# candidate rewriting.
		var msg := JSON.stringify({
			"type": "offer",
			"sdp": sdp,
			"peer_id": _peer_id,
			"server_port": _server_port,
		})
		if (_ws != null
				and _ws.get_ready_state()
					== WebSocketPeer.STATE_OPEN):
			_ws.send_text(msg)
			Netcode.log.print(
				"WebRTC: sent offer to server",
				NetworkLogger.CATEGORY_CONNECTIONS,
			)


func _on_local_ice_candidate(
	media: String,
	index: int,
	candidate_name: String,
) -> void:
	Netcode.log.print(
		"WebRTC: local ICE candidate: %s"
		% candidate_name,
		NetworkLogger.CATEGORY_CONNECTIONS,
	)
	if (_ws == null
			or _ws.get_ready_state()
				!= WebSocketPeer.STATE_OPEN):
		Netcode.log.warning(
			"WebRTC: WS not open, can't send ICE",
			NetworkLogger.CATEGORY_CONNECTIONS,
		)
		return

	var msg := JSON.stringify({
		"type": "ice",
		"candidate": candidate_name,
		"mid": media,
		"index": index,
	})
	_ws.send_text(msg)


func _handle_message(text: String) -> void:
	var data = JSON.parse_string(text)
	if data == null or not data is Dictionary:
		return

	var msg_type: String = data.get("type", "")
	match msg_type:
		"answer":
			_handle_answer(data)
		"ice":
			_handle_server_ice(data)
		"connected":
			_handle_connected(data)


func _handle_answer(data: Dictionary) -> void:
	var sdp: String = data.get("sdp", "")
	if sdp.is_empty() or _rtc == null:
		return

	_rtc.set_remote_description("answer", sdp)
	Netcode.log.print(
		"WebRTC: received answer from server",
		NetworkLogger.CATEGORY_CONNECTIONS,
	)


func _handle_server_ice(data: Dictionary) -> void:
	if _rtc == null:
		return

	var candidate: String = data.get("candidate", "")
	var mid: String = data.get("mid", "")
	var index: int = data.get("index", 0)

	if candidate.is_empty():
		return

	Netcode.log.print(
		"WebRTC: remote ICE candidate: %s"
		% candidate,
		NetworkLogger.CATEGORY_CONNECTIONS,
	)
	_rtc.add_ice_candidate(mid, index, candidate)


func _handle_connected(_data: Dictionary) -> void:
	Netcode.log.print(
		"WebRTC: server confirmed connection",
		NetworkLogger.CATEGORY_CONNECTIONS,
	)
	# The server may send this before the
	# DataChannel is fully open on the client side.
	# The _process loop checks DataChannel state.


func _on_connection_established() -> void:
	if _is_completed:
		return
	_is_completed = true
	_is_active = false

	Netcode.log.print(
		"WebRTC: ICE connected,"
		+ " signaling complete",
		NetworkLogger.CATEGORY_CONNECTIONS,
	)

	# Close the signaling WebSocket.
	if (_ws != null
			and _ws.get_ready_state()
				!= WebSocketPeer.STATE_CLOSED):
		_ws.close()

	completed.emit(_rtc)


func _retry_or_fail() -> void:
	_cleanup()
	if _attempt_count < _MAX_RETRY_ATTEMPTS:
		# Schedule the next attempt; _process will fire it
		# once the backoff window elapses. Keeps _is_active
		# true so we stay in the loop.
		_next_attempt_at_msec = (
			Time.get_ticks_msec() + _RETRY_DELAY_MSEC)
	else:
		_is_active = false
		failed.emit(
			("WebRTC signaling failed after %d"
			+ " attempts") % _MAX_RETRY_ATTEMPTS)


func _cleanup() -> void:
	if (_ws != null
			and _ws.get_ready_state()
				!= WebSocketPeer.STATE_CLOSED):
		_ws.close()
	_ws = null

	if _rtc != null and not _is_completed:
		_rtc.close()
	if not _is_completed:
		_rtc = null
		_peer_added = false
