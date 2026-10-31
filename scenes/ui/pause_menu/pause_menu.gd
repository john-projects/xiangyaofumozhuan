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
## 「背包」：进入二级页（WorldMap 打开 BagPanel）。地图上按 B 也能直接开，不用先按 Esc。
signal bag_requested
## 「角色属性」：进入二级页（WorldMap 打开 StatsPanel）。地图上按 C 也能直接开。
signal stats_requested
## 「进入战斗」：与地图右下角那个按钮同一条通路（WorldMap._on_battle_pressed）。
signal battle_requested
## 「返回主菜单」：与地图左下角那个按钮同一条通路（WorldMap._on_back_pressed）。
signal title_requested

@onready var resume_button: Button = %ResumeButton
@onready var party_button: Button = %PartyButton
@onready var bag_button: Button = %BagButton
@onready var stats_button: Button = %StatsButton
@onready var title_button: Button = %TitleButton


func _ready() -> void:
	hide()
	# 接在代码里而不是 .tscn 的 [connection]：按钮名和信号名都在这一屏能看全，
	# 少一处"改了名字忘了改连线"的隐患（本工程的 UI 节点大多这么做）。
	resume_button.pressed.connect(_emit_resume)
	party_button.pressed.connect(_emit_party)
	bag_button.pressed.connect(_emit_bag)
	stats_button.pressed.connect(_emit_stats)
	title_button.pressed.connect(_emit_title)


## 打开菜单。
## 参数 battle_enabled：保留签名兼容调用方；「进入战斗」已从本菜单移除，不再使用。
## 副作用：show() 并把焦点放到「继续游戏」。
func open(_battle_enabled := true) -> void:
	show()
	resume_button.grab_focus()


## 按视觉顺序返回可聚焦的按钮（给 WorldMap 做 W/S 循环切换用）。
## 跳过 disabled 的按钮：置灰按钮 grab_focus() 无效，混在环里会让 W/S 卡住不动。
func focus_ring() -> Array[Control]:
	var out: Array[Control] = []
	var buttons: Array[Button] = [resume_button, party_button, bag_button, stats_button,
			title_button]
	for button in buttons:
		if not button.disabled:
			out.append(button)
	return out


func _emit_resume() -> void:
	resume_requested.emit()


func _emit_party() -> void:
	party_requested.emit()


func _emit_bag() -> void:
	bag_requested.emit()


func _emit_stats() -> void:
	stats_requested.emit()


func _emit_battle() -> void:
	battle_requested.emit()


func _emit_title() -> void:
	title_requested.emit()
