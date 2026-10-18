# TitleScreen —— 游戏主菜单屏幕
# 职责：只是"按钮面板"，不切场景、不改 Global、不读地图数据 —— 按钮 → emit 信号 → GameRoot 做事。
# 位置：GameRoot.show_title() 实例化后挂到 UIRoot（CanvasLayer）下，是常驻主场景的一个"屏幕"。
# 数据流：GameRoot 先写 screen.last_result 再 add_child，本文件在 _ready() 里显示到副标题。
# 键盘：↑↓/Enter/空格 走 Godot 内置 ui_* + GUI 焦点（_ready() 末尾 grab_focus 第一个可用按钮）；
#   W/S/E 走 _unhandled_input + Global 的工具；Esc 刻意不做任何事（主菜单没有上一级）。
# 坑：last_result 必须在 add_child 之前赋值；%控件 都是 @onready，_init() 里别访问。
extends Control
class_name TitleScreen

# ── 对外信号（GameRoot 在 show_title() 里 connect）──
## 点了「新的征程」。无参数 —— 从哪张图开始由 GameRoot 按 maps/start_map_id 决定。
signal new_game_requested
## 点了「退出游戏」。GameRoot 接的是 get_tree().quit()。
signal quit_requested

# ── 输入数据（由 GameRoot 在 add_child 之前写入）──
## 上一场的结算文案，显示在副标题上；空串 = 显示常规副标题。必须 add_child 之前赋值，_ready() 才读得到。
var last_result := ""

## 焦点环：按视觉顺序排列的可点按钮。_ready() 建好并聚焦第一个，W/S 用它循环、E 用它确认。
var _focus_ring: Array[Control] = []

# ── 节点引用（% = unique_name_in_owner）──
## 副标题标签：显示 last_result，没有则显示玩法说明。
@onready var subtitle_label: Label = %SubtitleLabel
## 「新的征程」按钮。
@onready var new_game_button: Button = %NewGameButton
## 「继续游戏」按钮。目前恒为 disabled（没有存档系统）。
@onready var continue_button: Button = %ContinueButton
## 「退出游戏」按钮 → quit_requested。
@onready var quit_button: Button = %QuitButton


## 进入树时执行一次：配置副标题与按钮、连信号、建焦点环并聚焦第一个可用项。
## 副作用：改 subtitle_label.text / continue_button.disabled，connect 两个按钮的 pressed。
## 换屏时本实例被移除，连接随之销毁，不需要手动 disconnect（也不会重复连接）。
func _ready() -> void:
	# 有上一局结果就优先显示它（玩家一眼能看到刚才打赢了/输了）。
	subtitle_label.text = last_result if not last_result.is_empty() else "回合制战斗 · 关卡 → 战斗 → 结算（队长用 GameRoot.default_leader）"

	# TODO: 存档系统做好后，这里改成"有存档才可点"；现在宁可禁用也不做假按钮。
	continue_button.disabled = true

	# 只连真正有处理函数的两个按钮；continue_button 没有对应信号，纯摆设。
	new_game_button.pressed.connect(_on_new_game_pressed)
	quit_button.pressed.connect(_on_quit_pressed)

	# ⚠ 顺序：必须在 continue_button.disabled = true 之后收集 —— 置灰按钮进环会让 W/S 停住不动。
	# ⚠ 没有末尾的 grab_focus()，方向键按下去会"没人可动"（焦点为空），主菜单以前不支持键盘正是这个原因。
	var buttons: Array[Button] = [new_game_button, continue_button, quit_button]
	_focus_ring.clear()
	for button in buttons:
		if Global.can_focus(button):
			_focus_ring.append(button)
	if not _focus_ring.is_empty():
		_focus_ring[0].grab_focus()


## 未被子控件消费的输入：补 W S（move_up / move_down）与 E（交互键）。
## ↑↓/Enter/空格 由 Godot 的 GUI 焦点系统更早消费，这里收不到；Esc 刻意不处理。
## ⚠ E 之后本屏幕可能立刻被 queue_free，所以两个分支都是"先做动作、再 set_input_as_handled"。
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("move_up"):
		Global.step_focus(self, _focus_ring, -1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("move_down"):
		Global.step_focus(self, _focus_ring, 1)
		get_viewport().set_input_as_handled()
	elif Global.is_interact_event(event):
		if Global.activate_focused(self):
			get_viewport().set_input_as_handled()


## 「新的征程」回调：播 UI 音效 + emit new_game_requested。
func _on_new_game_pressed() -> void:
	_click()
	new_game_requested.emit()


## 「退出游戏」回调：播 UI 音效 + emit quit_requested（真正退出由 GameRoot 接的 get_tree().quit()）。
func _on_quit_pressed() -> void:
	_click()
	quit_requested.emit()


## 统一的按钮点击音效（三处调用一致，以后换音效只改这里）。
## ⚠ SoundManager 池子只有 10 个播放器，同一帧点太多按钮会静默丢音（不影响逻辑）。
func _click() -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
