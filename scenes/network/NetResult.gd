## 网络对战结果页 - 显示对战结果
extends Control

var _winner_index: int = -1
var _reason: String = ""


func _ready() -> void:
	_winner_index = GameManager.net_game_winner
	_reason = GameManager.net_game_reason
	_setup_ui()


func set_result(winner_index: int, reason: String) -> void:
	_winner_index = winner_index
	_reason = reason
	if is_inside_tree():
		_update_display()


func _setup_ui() -> void:
	%BackToLobbyBtn.pressed.connect(_on_back_to_lobby)
	%BackToMenuBtn.pressed.connect(_on_back_to_menu)
	_update_display()


func _update_display() -> void:
	if _winner_index == GameManager.net_player_index:
		%ResultLabel.text = "胜利!"
		%ResultLabel.add_theme_color_override("font_color", Color.GREEN)
	else:
		%ResultLabel.text = "失败"
		%ResultLabel.add_theme_color_override("font_color", Color.RED)
	%ReasonLabel.text = _reason if not _reason.is_empty() else ""


func _on_back_to_lobby() -> void:
	GameManager.clear_saved_net_session()
	GameManager.clear_net_result_state()
	GameManager.goto_net_lobby()


func _on_back_to_menu() -> void:
	GameManager.clear_saved_net_session()
	GameManager.clear_net_result_state()
	GameManager.goto_main_menu()
