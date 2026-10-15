extends Control
class_name PauseMenu

## 操作菜单（Esc 唤出）。
##
## ── 在系统里的位置 ──
##   纯 UI 场景：由 WorldMap._setup_overlays() 实例化后挂在它的 UI（CanvasLayer）下面。
##   自己不碰任何游戏状态 —— 点哪个按钮只是 emit 对应信号，由 WorldMap / GameRoot 决定做什么
##   （「进入战斗」「返回主菜单」两个信号直接接到 WorldMap 那两条既有通路上，行为与地图上
##   那两个常驻按钮完全一致，不会出现"两处逻辑各写一遍"）。
##
## ── 键盘操作 ──
##   打开时 open() 会把焦点放到「继续游戏」上，之后：
##     · ↑↓（引擎内置 ui_up / ui_down）由 Godot 的 GUI 焦点系统自动换行；
##     · W S（本工程的 move_up / move_down）由 WorldMap._overlay_nav() 换行；
##     · Enter / 空格（内置 ui_accept）由 GUI 系统直接按下当前焦点的按钮；
##     · E（本工程的交互键）由 WorldMap._overlay_nav() 调 _activate_focused() 按下；
##     · Esc 由 WorldMap 处理（关菜单回游戏）。
##   菜单自己的按钮列表通过 focus_ring() 交出去，WorldMap 用它在 W/S 时循环切换。

## 「继续游戏」：关掉菜单回到地图。
signal resume_requested
## 「队伍管理」：进入二级页（WorldMap 打开 PartyPanel）。
signal party_requested
## 「进入战斗」：与地图右下角那个按钮同一条通路（WorldMap._on_battle_pressed）。
signal battle_requested
## 「返回主菜单」：与地图左下角那个按钮同一条通路（WorldMap._on_back_pressed）。
signal title_requested

@onready var resume_button: Button = %ResumeButton
@onready var party_button: Button = %PartyButton
@onready var battle_button: Button = %BattleButton
@onready var title_button: Button = %TitleButton


func _ready() -> void:
	hide()
	# 接在代码里而不是 .tscn 的 [connection]：按钮名和信号名都在这一屏能看全，
	# 少一处"改了名字忘了改连线"的隐患（本工程的 UI 节点大多这么做）。
	resume_button.pressed.connect(_emit_resume)
	party_button.pressed.connect(_emit_party)
	battle_button.pressed.connect(_emit_battle)
	title_button.pressed.connect(_emit_title)


## 打开菜单。
## 参数 battle_enabled：本次所在的图能不能打（纯剧情图把「进入战斗」置灰，与地图上那个按钮一致）。
## 副作用：按 battle_enabled 改「进入战斗」的 disabled、show()、把焦点放到「继续游戏」。
## 注意：必须 grab_focus() 一个**没被置灰**的按钮 —— 置灰的按钮拿不到焦点，
##   要是把它设成初始焦点，菜单一打开键盘就没反应了（这里选「继续游戏」，它永远可用）。
func open(battle_enabled: bool) -> void:
	battle_button.disabled = not battle_enabled
	show()
	resume_button.grab_focus()


## 按视觉顺序返回可聚焦的按钮（给 WorldMap 做 W/S 循环切换用）。
## 跳过 disabled 的按钮：置灰按钮 grab_focus() 无效，混在环里会让 W/S 卡住不动。
func focus_ring() -> Array[Control]:
	var out: Array[Control] = []
	var buttons: Array[Button] = [resume_button, party_button, battle_button, title_button]
	for button in buttons:
		if not button.disabled:
			out.append(button)
	return out


func _emit_resume() -> void:
	resume_requested.emit()


func _emit_party() -> void:
	party_requested.emit()


func _emit_battle() -> void:
	battle_requested.emit()


func _emit_title() -> void:
	title_requested.emit()
