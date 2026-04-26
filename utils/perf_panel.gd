class_name PerfPanel
extends Control
## Optional UI component for displaying PerfTracker metrics.
##
## This is a reusable, dependency-free UI component that displays performance
## metrics from a PerfTracker instance. It has no dependencies on any specific
## game architecture (no G singleton, no ScaffolderTime, etc).
##
## ## Usage
##
## 1. Create your own scene with a Control root node
## 2. Attach this script to the root node
## 3. Add Label child nodes with unique names (% syntax) matching the required
##    node names listed below
## 4. Set the `perf_tracker` property to your PerfTracker instance
## 5. Control visibility with the `visible` property
##
## ## Required Label Nodes (using % unique name syntax)
##
## Client metrics:
## - %ClientRenderFPS
## - %ClientPhysicsFPS
## - %ClientNetworkFPS
## - %ClientNetworkPing
## - %ClientRollbacksPerSec
## - %ClientLastRollbackDuration
## - %ClientLastRollbackFrames
## - %ClientFastforwardsPerSec
## - %ClientLastFastforwardDuration
## - %ClientLastFastforwardFrames
##
## Server metrics (optional, for clients viewing server stats):
## - %ServerRenderFPS
## - %ServerPhysicsFPS
## - %ServerNetworkFPS
## - %ServerNetworkPing
## - %ServerRollbacksPerSec
## - %ServerLastRollbackDuration
## - %ServerLastRollbackFrames
## - %ServerFastforwardsPerSec
## - %ServerLastFastforwardDuration
## - %ServerLastFastforwardFrames
##
## ## Features
##
## - Automatic FPS color-coding (red warnings for slow performance)
## - Smooth color fade transitions
## - Current + min/max metric display format: "current (min/max)"
## - Rollback and fastforward metrics with threshold-based warnings
## - Network ping display with latency warnings
## - Server metrics display (for clients monitoring server performance).

# --- UI color-coding thresholds ---

const _SLOW_NETWORK_RTT_THRESHOLD_SEC := 0.1 # 100ms
const _LARGE_FASTFORWARD_THRESHOLD := 2
const _HIGH_FASTFORWARD_RATE_THRESHOLD := 0.2
const _SLOW_RENDER_FPS := 30
const _SLOW_PHYSICS_FPS := 50 # Standard network FPS (60) - 10
const _SLOW_NETWORK_FPS := 30

const _COLOR_FADE_DURATION_SEC := 0.5

# --- Dependencies ---

## PerfTracker instance to read metrics from. Must be set by user.
var perf_tracker: PerfTracker:
	set(value):
		perf_tracker = value

# --- Internal state ---

# Color fade tweens.
var _color_tweens := {}


func _ready() -> void:
	pass

# --- Engine callbacks ---


func _process(_delta: float) -> void:
	if not visible or not perf_tracker:
		return

	_update_render_fps_ui()
	_update_server_ui()
	_update_physics_fps_ui()
	_update_network_ping_ui()
	_update_network_fps_ui()
	_update_rollback_metrics_ui()
	_update_fastforward_metrics_ui()


func _update_render_fps_ui() -> void:
	var current_fps := perf_tracker.get_client_render_fps()
	var min_fps := perf_tracker.get_min_render_fps()

	var min_text := "%.1f" % min_fps if min_fps != INF else "--"
	%ClientRenderFPS.text = "%.1f (%s)" % [current_fps, min_text]

	var is_slow := current_fps > 0.0 and current_fps < _SLOW_RENDER_FPS
	_update_label_color(%ClientRenderFPS, is_slow)


func _update_physics_fps_ui() -> void:
	var current_fps := perf_tracker.get_client_physics_fps()
	var min_fps := perf_tracker.get_min_physics_fps()

	var min_text := "%.1f" % min_fps if min_fps != INF else "--"
	%ClientPhysicsFPS.text = "%.1f (%s)" % [current_fps, min_text]

	var is_slow := current_fps > 0.0 and current_fps < _SLOW_PHYSICS_FPS
	_update_label_color(%ClientPhysicsFPS, is_slow)


func _update_network_fps_ui() -> void:
	var current_fps := perf_tracker.get_client_network_fps()
	var min_fps := perf_tracker.get_min_network_fps()

	var min_text := "%.1f" % min_fps if min_fps != INF else "--"
	%ClientNetworkFPS.text = "%.1f (%s)" % [current_fps, min_text]

	var is_slow := current_fps > 0.0 and current_fps < _SLOW_NETWORK_FPS
	_update_label_color(%ClientNetworkFPS, is_slow)


func _update_network_ping_ui() -> void:
	var current_ping := perf_tracker.get_client_network_ping_ms()
	var max_ping := perf_tracker.get_max_network_ping_ms()

	%ClientNetworkPing.text = "%.1f (%.1f)" % [current_ping, max_ping]

	var is_slow := current_ping > _SLOW_NETWORK_RTT_THRESHOLD_SEC * 1000.0
	_update_label_color(%ClientNetworkPing, is_slow)


func _update_rollback_metrics_ui() -> void:
	var rollbacks_per_sec := perf_tracker.get_client_rollbacks_per_sec()
	var last_duration_ms := perf_tracker.get_client_last_rollback_duration_ms()
	var last_frames := perf_tracker.get_client_last_rollback_frames()
	var max_rollbacks := perf_tracker.get_max_rollbacks_per_sec()
	var max_duration := perf_tracker.get_max_last_rollback_duration_ms()
	var max_frames := perf_tracker.get_max_last_rollback_frames()

	%ClientRollbacksPerSec.text = "%.1f (%.1f)" % [rollbacks_per_sec, max_rollbacks]
	%ClientLastRollbackDuration.text = "%.2f (%.2f)" % [last_duration_ms, max_duration]
	%ClientLastRollbackFrames.text = "%d (%d)" % [last_frames, max_frames]


func _update_fastforward_metrics_ui() -> void:
	var fastforwards_per_sec := perf_tracker.get_client_fastforwards_per_sec()
	var last_duration_ms := perf_tracker.get_client_last_fastforward_duration_ms()
	var last_frames := perf_tracker.get_client_last_fastforward_frames()
	var max_fastforwards := perf_tracker.get_max_fastforwards_per_sec()
	var max_duration := perf_tracker.get_max_last_fastforward_duration_ms()
	var max_frames := perf_tracker.get_max_last_fastforward_frames()

	%ClientFastforwardsPerSec.text = "%.1f (%.1f)" % [fastforwards_per_sec, max_fastforwards]
	%ClientLastFastforwardDuration.text = "%.2f (%.2f)" % [last_duration_ms, max_duration]
	%ClientLastFastforwardFrames.text = "%d (%d)" % [last_frames, max_frames]

	# Update colors based on thresholds.
	var is_large_fastforward := last_frames >= _LARGE_FASTFORWARD_THRESHOLD
	var is_high_rate := fastforwards_per_sec > _HIGH_FASTFORWARD_RATE_THRESHOLD

	_update_label_color(%ClientLastFastforwardFrames, is_large_fastforward)
	_update_label_color(%ClientFastforwardsPerSec, is_high_rate)

# --- Helper methods ---


func _update_label_color(label: Label, is_slow: bool) -> void:
	var label_path := label.get_path()

	if is_slow:
		if label_path in _color_tweens and _color_tweens[label_path]:
			_color_tweens[label_path].kill()
		label.add_theme_color_override("font_color", Color.RED)
	else:
		# Only start fade tween if we're currently red or have a red tween
		# running.
		var current_color := label.get_theme_color("font_color")
		var should_fade: bool = (
			current_color == Color.RED
			or (label_path in _color_tweens and _color_tweens[label_path])
		)

		if should_fade:
			if label_path in _color_tweens and _color_tweens[label_path]:
				_color_tweens[label_path].kill()
			var tween := create_tween()
			_color_tweens[label_path] = tween
			tween.tween_method(
				func(color: Color):
					label.add_theme_color_override("font_color", color),
				current_color,
				Color.WHITE,
				_COLOR_FADE_DURATION_SEC,
			)
		else:
			# Already white, just ensure no override.
			label.remove_theme_color_override("font_color")


# --- Server UI update ---


func _update_server_ui() -> void:
	# Physics FPS.
	var server_physics_fps := perf_tracker.get_server_physics_fps()
	var server_min_physics_fps := perf_tracker.get_server_min_physics_fps()
	var min_physics_text := "%.1f" % server_min_physics_fps if server_min_physics_fps != INF else "--"
	%ServerPhysicsFPS.text = "%.1f (%s)" % [server_physics_fps, min_physics_text]

	# Render FPS - N/A for headless servers.
	%ServerRenderFPS.text = "N/A"

	# Network FPS.
	var server_network_fps := perf_tracker.get_server_network_fps()
	var server_min_network_fps := perf_tracker.get_server_min_network_fps()
	var min_network_text := "%.1f" % server_min_network_fps if server_min_network_fps != INF else "--"
	%ServerNetworkFPS.text = "%.1f (%s)" % [server_network_fps, min_network_text]

	# Ping - N/A for server (no self-ping).
	%ServerNetworkPing.text = "N/A"

	# Rollback metrics.
	var server_rollbacks_per_sec := perf_tracker.get_server_rollbacks_per_sec()
	var server_max_rollbacks := perf_tracker.get_server_max_rollbacks_per_sec()
	%ServerRollbacksPerSec.text = "%.1f (%.1f)" % [server_rollbacks_per_sec, server_max_rollbacks]

	var server_last_rollback_duration := perf_tracker.get_server_last_rollback_duration_ms()
	var server_max_rollback_duration := perf_tracker.get_server_max_last_rollback_duration_ms()
	%ServerLastRollbackDuration.text = "%.2f (%.2f)" % [server_last_rollback_duration, server_max_rollback_duration]

	var server_last_rollback_frames := perf_tracker.get_server_last_rollback_frames()
	var server_max_rollback_frames := perf_tracker.get_server_max_last_rollback_frames()
	%ServerLastRollbackFrames.text = "%d (%d)" % [server_last_rollback_frames, server_max_rollback_frames]

	# Fastforward metrics.
	var server_fastforwards_per_sec := perf_tracker.get_server_fastforwards_per_sec()
	var server_max_fastforwards := perf_tracker.get_server_max_fastforwards_per_sec()
	%ServerFastforwardsPerSec.text = "%.1f (%.1f)" % [server_fastforwards_per_sec, server_max_fastforwards]

	var server_last_fastforward_duration := perf_tracker.get_server_last_fastforward_duration_ms()
	var server_max_fastforward_duration := perf_tracker.get_server_max_last_fastforward_duration_ms()
	%ServerLastFastforwardDuration.text = "%.2f (%.2f)" % [server_last_fastforward_duration, server_max_fastforward_duration]

	var server_last_fastforward_frames := perf_tracker.get_server_last_fastforward_frames()
	var server_max_fastforward_frames := perf_tracker.get_server_max_last_fastforward_frames()
	%ServerLastFastforwardFrames.text = "%d (%d)" % [server_last_fastforward_frames, server_max_fastforward_frames]
