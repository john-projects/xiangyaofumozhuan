extends Control
class_name TitleScreen

## 主菜单：新的征程 / 继续游戏 / 经典模式 / 退出

signal new_game_requested
signal arena_requested
signal quit_requested

var last_result := ""

@onready var subtitle_label: Label = %SubtitleLabel
@onready var new_game_button: Button = %NewGameButton
@onready var continue_button: Button = %ContinueButton
@onready var arena_button: Button = %ArenaButton
@onready var quit_button: Button = %QuitButton


func _ready() -> void:
	subtitle_label.text = last_result if not last_result.is_empty() else "回合制战斗 · 选人 → 关卡 → 战斗 → 结算"

	# TODO: 存档系统做好后，这里改成"有存档才可点"
	continue_button.disabled = true

	new_game_button.pressed.connect(_on_new_game_pressed)
	arena_button.pressed.connect(_on_arena_pressed)
	quit_button.pressed.connect(_on_quit_pressed)


func _on_new_game_pressed() -> void:
	_click()
	new_game_requested.emit()


func _on_arena_pressed() -> void:
	_click()
	arena_requested.emit()


func _on_quit_pressed() -> void:
	_click()
	quit_requested.emit()


func _click() -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
