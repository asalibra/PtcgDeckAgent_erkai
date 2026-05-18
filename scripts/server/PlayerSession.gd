## 玩家会话 - 跟踪连接状态、断线、重连
class_name PlayerSession
extends RefCounted

var peer_id: int = -1
var session_token: String = ""
var player_name: String = ""
var room_id: String = ""
var player_index: int = -1
var connected: bool = true
var disconnect_time: float = 0.0
var deck_id: int = -1
var ready: bool = false

const GRACE_PERIOD_SECONDS := 300.0


func generate_token() -> String:
	session_token = "%s_%s" % [str(randi()), str(Time.get_ticks_msec())]
	return session_token


func mark_disconnected() -> void:
	connected = false
	disconnect_time = Time.get_ticks_msec() / 1000.0


func mark_reconnected(new_peer_id: int) -> void:
	peer_id = new_peer_id
	connected = true
	disconnect_time = 0.0


func is_expired() -> bool:
	if connected:
		return false
	var now := Time.get_ticks_msec() / 1000.0
	return (now - disconnect_time) > GRACE_PERIOD_SECONDS


func get_info() -> Dictionary:
	return {
		"player_name": player_name,
		"player_index": player_index,
		"connected": connected,
		"ready": ready,
		"deck_id": deck_id,
	}
