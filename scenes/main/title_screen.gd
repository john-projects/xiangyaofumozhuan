# ═══════════════════════════════════════════════════════════════════════════
# TitleScreen —— 游戏主菜单屏幕
# ═══════════════════════════════════════════════════════════════════════════
# 在系统里的位置：
#   游戏启动后 GameRoot._ready() 会 await show_title()，于是本屏幕被实例化并
#   add_child 到 main.tscn 的 UIRoot(CanvasLayer) 下面 —— 也就是说主菜单是常驻主场景的
#   一个"屏幕"，而不是独立场景；GameRoot 用 UIRoot/WorldRoot 的换子节点实现"换屏"。
#
# 职责边界：
#   本文件**不切场景、不改 Global、不读地图数据**。它只是个"按钮面板"：
#   按钮按下 → emit 对应的信号 → GameRoot 收到后做真正的事（开始新游戏 / 退出）。
#   这样菜单不需要知道游戏有几种模式，加模式只加信号 + GameRoot 里加一个处理函数。
#   注：竞技场（经典模式）已经移除，主菜单现在只有「新的征程 / 继续游戏 / 退出游戏」。
#
# 数据流：GameRoot.show_title() 会把上一局的结算文案写进 screen.last_result，
#         本文件在 _ready() 里把它显示到副标题上（所以必须在 add_child 之前赋值 —— 见下）。
#
# 键盘操作（和世界地图同一套约定，细节见 Global 的"UI 键盘焦点工具"一节）：
#   · ↑↓ / Enter / 空格 —— Godot 内置的 ui_* 动作 + GUI 焦点系统直接就能用，
#     但前提是"有控件拿着焦点" —— 所以 _ready() 末尾会 grab_focus() 第一个可用按钮；
#   · W S / E —— 工程自己的动作，GUI 不认，由本文件的 _unhandled_input 调 Global 的工具补上；
#   · 置灰的「继续游戏」不进焦点环（没有存档系统，它永远是灰的），所以 W/S 不会停在它上面；
#   · Esc 在主菜单**刻意不做事**：这里没有"上一级"可退，免得手滑直接退出游戏。
#
# 按钮与信号对应关系：
#   新的征程 → new_game_requested → GameRoot.start_new_game()
#   继续游戏 → （暂时禁用，没有存档系统）
#   退出游戏 → quit_requested     → GameRoot 里接的是 get_tree().quit()
#
# 坑：
#   · last_result 必须在 add_child（即 _ready() 执行）**之前**赋值，否则 _ready() 读到的
#     还是默认空串。GameRoot.show_title() 正是"先 screen.last_result = ...，再 await _swap(screen)"。
#   · 本文件所有 %控件 都是 @onready，_ready() 之前为 null，别在 _init() 里访问。

extends Control
class_name TitleScreen

## 主菜单：新的征程 / 继续游戏 / 退出

# ───────────────────────────────────────────────────────────────────────────
#  ── 对外信号（由 GameRoot 在 show_title() 里 connect）──
# ───────────────────────────────────────────────────────────────────────────
## 点了「新的征程」。无参数 —— 从哪张图开始由 GameRoot 按 maps/start_map_id 决定。
signal new_game_requested
## 点了「退出游戏」。GameRoot 接的是 get_tree().quit()。
signal quit_requested

# ───────────────────────────────────────────────────────────────────────────
#  ── 输入数据（由 GameRoot 在 add_child 之前写入）──
# ───────────────────────────────────────────────────────────────────────────
## 上一局/上一场战斗的结算文案，显示在副标题上（例如"建邺城：战斗胜利！获得 40 金币"）。
## 默认空串 = 显示常规副标题。注意它必须在实例化后、add_child 之前赋值才能在 _ready() 里读到。
var last_result := ""

## 主菜单的"焦点环"：按视觉顺序排列的可点按钮。
## _ready() 里建好并聚焦第一个；_unhandled_input 里的 W/S 用它循环、E 用它确认。
var _focus_ring: Array[Control] = []

# ── 节点引用（% = unique_name_in_owner）──────────────────────────────────────
## 副标题标签：显示 last_result，没有则显示玩法说明。
@onready var subtitle_label: Label = %SubtitleLabel
## 「新的征程」按钮。
@onready var new_game_button: Button = %NewGameButton
## 「继续游戏」按钮。目前恒为 disabled（没有存档系统）。
@onready var continue_button: Button = %ContinueButton
## 「退出游戏」按钮 → quit_requested。
@onready var quit_button: Button = %QuitButton


## 生命周期：进树时执行一次，配置副标题与按钮。
## 参数：无。返回值：无。
## 副作用：改 subtitle_label.text、continue_button.disabled，
##        并把两个可用按钮的 pressed 连接到本文件的回调。
## 说明：本屏幕随 GameRoot._clear_screens() 被移除，信号连接随之销毁，
##   不需要手动 disconnect；也不会重复连接（每次换屏都是新实例）。
func _ready() -> void:
	# 有上一局结果就优先显示它（玩家一眼能看到刚才打赢了/输了）。
	subtitle_label.text = last_result if not last_result.is_empty() else "回合制战斗 · 关卡 → 战斗 → 结算（队长用 GameRoot.default_leader）"

	# TODO: 存档系统做好后，这里改成"有存档才可点"
	# 现在还没有存档，所以「继续游戏」永远不可点（宁可禁用也不要做个假按钮）。
	continue_button.disabled = true

	# 只连真正有处理函数的两个按钮；continue_button 没有对应信号，纯摆设。
	new_game_button.pressed.connect(_on_new_game_pressed)
	quit_button.pressed.connect(_on_quit_pressed)

	# ── 键盘操作：先建焦点环，再聚焦第一个可用项 ──
	# ⚠ 顺序：必须在 continue_button.disabled = true **之后**收集 —— 置灰的按钮要是进了环，
	#   W/S 会在它上面"停住不动"（grab_focus() 对置灰按钮无效，焦点压根不会动）。
	# ⚠ 没有最后那句 grab_focus() 的话，方向键按下去会"没人可动"（焦点是空的）——
	#   这正是主菜单以前不支持键盘的原因：按钮本身是可聚焦的，只是没人给它焦点。
	var buttons: Array[Button] = [new_game_button, continue_button, quit_button]
	_focus_ring.clear()
	for button in buttons:
		if Global.can_focus(button):
			_focus_ring.append(button)
	if not _focus_ring.is_empty():
		_focus_ring[0].grab_focus()


## 未被子控件消费掉的输入在这里处理（和世界地图的 _overlay_nav 是同一套思路）。
## 参数 event：引擎派发的输入事件。
## 返回值：无。
## 副作用：可能切换焦点、可能按下当前焦点的按钮（那会 emit 对应信号 → GameRoot 换屏）。
## 处理范围：只补 W S（move_up / move_down）与 E（交互键）——
##   ↑↓ / Enter / 空格由 Godot 的 GUI 焦点系统在更早的阶段消费掉，这里根本收不到，也不用管。
##   也**不处理 Esc**：主菜单没有"上一级"可退，按 Esc 什么都不做是刻意的（免得手滑退出游戏）。
## 注意 E 按下后本屏幕可能立刻被 queue_free（新的征程会换屏）：
##   所以两个分支里都是"先做动作、再 set_input_as_handled"，不依赖之后的自身状态。
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


## 「新的征程」按钮回调。
## 参数：无。返回值：无。副作用：播 UI 音效 + emit new_game_requested。
func _on_new_game_pressed() -> void:
	_click()
	new_game_requested.emit()


## 「退出游戏」按钮回调。
## 参数：无。返回值：无。副作用：播 UI 音效 + emit quit_requested；
##   真正退出由 GameRoot 那边接的 get_tree().quit() 执行（本文件不直接退，保持"只发信号"的约定）。
func _on_quit_pressed() -> void:
	_click()
	quit_requested.emit()


## 统一的按钮点击音效。
## 参数：无。返回值：无。副作用：占用 SoundManager 播放器池里的一个播放器播 UI 音。
## 抽成函数是为了三处调用写法一致（以后换音效只改这里）。
## 注意：SoundManager 的池子只有 10 个播放器，同一帧点太多按钮会静默丢音（不影响逻辑）。
func _click() -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
