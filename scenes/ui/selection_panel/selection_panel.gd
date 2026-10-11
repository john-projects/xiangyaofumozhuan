## ═══════════════════════════════════════════════════════════════════════════
## SelectionPanel —— 选人界面：挑 1 个角色 + 1 把初始武器，然后出发
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置（本场景有**两个**使用方，别只看一个）：
##   1) 地图/关卡模式：GameRoot（scenes/main/main.gd）在 show_character_select() 里
##      实例化 selection_panel.tscn，把 on_selection_completed 连到自己的 _on_selection_completed，
##      然后用 _swap() 挂到 ui_root 上显示。玩家点"继续"后 GameRoot 组队、进第一张地图。
##   2) 战斗结算模式：arena.tscn 的 GameUI 下**直接摆了一个 SelectionPanel 实例**，
##      并在 .tscn 里把 on_selection_completed 连到 Arena._on_selection_panel_on_selection_completed
##      （那边会 add_child 玩家、发初始武器、开第一波）。也就是说本面板的信号有两拨订阅者。
##
## 数据流（全部围绕 Global 的两个"选人结果"字段）：
##   players / start_weapons（@export，在 selection_panel.tscn 里挂了 5 个 UnitStats
##     和 11 个 ItemWeapon 资源）
##     → _ready() 清空两个容器后重建卡片（load_players / load_weapons）
##     → 点角色卡：写 Global.main_player_selected（UnitStats 资源）+ 右侧信息栏刷新
##     → 点武器卡：写 Global.main_weapon_selected（ItemWeapon 资源）
##     → 点 ContinueButton：两个都选中才 emit on_selection_completed 并 hide() 自己
##   本文件**不实例化玩家节点**：它只在 Global 里放"选中的资源"，实例化是调用方的事
##   （GameRoot 只是记进 party；Arena 才真正 get_selected_player() + add_child）。
##
## 悬停提示的两种实现（新版已启用、旧版保留注释）：
##   新：TooltipManager（autoload，独立 CanvasLayer，自己负责延迟/淡入/定位/防抖）
##   旧：面板自己实例化一张 HoverUnitCard / HoverItemCard 跟着鼠标走
##   旧代码成段保留在下面（被 # 注释掉），查历史时看得到，但**不会生效**。
##
## 坑：
##   · 场景里预置的卡片（%PlayerContainer 下 5 张、%WeaponContainer 下 11 张）只是**版式预览**：
##     _ready() 第一件事就是把它们全部 queue_free() 掉再按数据重建。
##   · queue_free() 是**帧末**才真正移除；紧接着 add_child 的新卡会和"待释放的旧卡"同帧共存，
##     容器会按两者一起排版（理论上可能闪一帧）。要干净就得先 remove_child()。
##   · 运行时创建的那些卡片 **owner 是 null**（它们不属于本场景文件），
##     所以卡片内部不能用 owner.queue_free() 之类的相对寻址。
##   · 所有 @onready 的 % 节点在 _ready() 之前是 null；而 _ready() 里第一段就在用它。
extends Panel
class_name SelectionPanel

## 选人完成（角色和武器都选中了，玩家点了"继续"）。**无参数** ——
## 结果不在参数里，而在 Global.main_player_selected / Global.main_weapon_selected 里。
## 订阅者：GameRoot._on_selection_completed（地图模式）与
##        Arena._on_selection_panel_on_selection_completed（战斗模式，连线在 arena.tscn）。
signal on_selection_completed

## ── 候选数据（在 selection_panel.tscn 的检视面板里挂）──────────────────────
## 可选角色（UnitStats 资源，5 个：Brawler / Bunny / Crazy / Knight / Well Rounded）。
## 类型化数组，声明时没写 `= []` —— 类型化数组默认就是空数组。
## 名字必须和 Global.available_players 里的键对应，否则 get_selected_player() 查不到场景。
@export var players: Array[UnitStats]
## 可选初始武器（ItemWeapon 资源，11 把）。点中后写进 Global.main_weapon_selected，
## 它同时也是一把**真正的武器数据**（有 scene / stats），会被后来 add_weapon() 实例化。
@export var start_weapons: Array[ItemWeapon]

# 旧方案（本地 hover card）已弃用，改用 TooltipManager；
# 这两张卡片的场景引用现在写在 tooltip_manager.gd 的登记区里
# const HOVER_UNIT_CARD_SCENE = preload("uid://bd5xd4lh1yhed")
# const HOVER_ITEM_CARD_SCENE = preload("uid://sojan35we4eq")

## ── 右侧"角色详情"栏的四个节点（全部 unique_name_in_owner）──────────────────
## 未选角色时它们整体是隐藏的（由 show_player_info(false) 控制），
## 选中角色后 show_player_info(true) 打开并填入数据。
## ⚠ player_title 只被"显示/隐藏"，**没有任何代码给它赋值** ——
##   它的文字是 selection_panel.tscn 里写死的静态文本。想让标题随角色变，得自己在这里 set。
@onready var player_icon: TextureRect = %PlayerIcon
@onready var player_name: Label = %PlayerName
@onready var player_title: Label = %PlayerTitle
@onready var player_description: RichTextLabel = %PlayerDescription

## ── 两排卡片的容器（unique_name_in_owner）────────────────────────────────
## 都是 HBoxContainer（横向排列，自带排版）：上面一排角色卡、下面一排武器卡。
## 容器会接管子节点的 position/size —— 调间距请改 separation / alignment。
@onready var player_container: HBoxContainer = %PlayerContainer
@onready var weapon_container: HBoxContainer = %WeaponContainer

# 旧方案
# var hover_unit_card: HoverUnitCard          # ← 和 player_container 那些放一起
# var hover_item_card: HoverItemCard          # ← 和 player_container 那些放一起

## 初始化：清掉场景里预置的预览卡片，重建两排真卡片，并先把详情栏藏起来。
## 参数：无。返回值：无。
## 副作用（顺序有意义）：
##   1) 把 %PlayerContainer / %WeaponContainer 下现有的子节点全部 queue_free()
##      —— 这些是编辑期摆的版式预览（5 张角色卡 + 11 张武器卡，后 10 张还是"裸 Button"，
##         只有每排第一张是真正的 SelectionCard 场景实例）；queue_free 是帧末生效，
##         所以下面 add_child 的新卡本帧会和它们共存（见文件头的坑）；
##   2) show_player_info(false)：详情栏在"还没选角色"时整体隐藏，避免显示上一局/空数据；
##   3) load_players()：按 players 数组生成角色卡（并接上信号）；
##   4) load_weapons()：按 start_weapons 数组生成武器卡（并接上信号）。
## 为什么在 _ready() 里做而不是 _enter_tree()：_enter_tree 时 % 唯一名还没解析完、
##   @onready 变量还是 null，那里取 player_container 会直接报错。
## 本类直接继承 Panel，没有需要 super 调用的父脚本 _ready()。
func _ready() -> void:
	# 清空两排容器里"编辑期预览用"的占位卡片。
	# ⚠ queue_free() 只是**排队**，真正移除发生在帧末；所以本函数后面 add_child 出来的新卡
	#   在本帧内会和这些待删节点同时存在于容器里（容器会把它们一起算进排版）。
	#   若想彻底避免一帧抖动，应写成 remove_child(child) 之后再 queue_free()。
	for child in player_container.get_children(): child.queue_free()
	for child in weapon_container.get_children(): child.queue_free()
	
	# 旧方案：本地创建两张提示卡（必须先进树再赋值，否则 @onready 全是 null）
	# hover_unit_card = HOVER_UNIT_CARD_SCENE.instantiate()
	# add_child(hover_unit_card)              # ★ 关键：先进树，@onready 才有值
	# hover_unit_card.hide()
	# 
	# hover_item_card = HOVER_ITEM_CARD_SCENE.instantiate()
	# add_child(hover_item_card)              # ★ 关键：先进树，@onready 才有值
	# hover_item_card.hide()
	
	show_player_info(false)
	load_players()
	load_weapons()

## 按 players 数组铺一排角色卡，并把"点选 / 悬停"两类信号接好。
## 参数：无（用 @export players）。
## 返回值：无。
## 副作用：
##   · players 为空时**直接返回**（此时场景里预置的卡已被 _ready() 删掉，界面会是空的）；
##   · 为每个角色实例化一张 SelectionCard（来自 Global.SELECTION_CARD_SCENE）并 add_child 进
##     %PlayerContainer —— 这些运行时节点 **owner 是 null**，不属于本场景文件；
##   · 每张卡连两条信号：
##       pressed        → _on_player_selected.bind(player)  —— 业务：把选中的 UnitStats 记进 Global
##       mouse_entered  → TooltipManager.show_for_control.bind(card, player) —— 悬停提示
##       mouse_exited   → TooltipManager.hide_tip
##   · 注意 .tscn 里 SelectionCard 自己已经把 pressed/mouse_entered 自连到了它自己的
##     _on_pressed / _on_mouse_entered（放音效），所以这两个信号各有**两个**订阅者，是刻意的。
## 关于 .bind()：pressed / mouse_entered 都是无参信号，bind 出来的 Callable 会把这些附加参数
##   追加到实参后面 —— 于是回调能同时拿到"是哪个数据"和"是哪张卡"。
## 顺序细节：add_child() 放在 set_icon() 之前。set_icon() 写的是 Button.icon（不是 @onready 变量），
##   严格说先后都行；但"先进树再填内容"是本工程卡片类的一致约定，照做不会踩 @onready 为 null 的坑。
func load_players() -> void:
	if players.is_empty():
		return
	for player: UnitStats in players:
		var card: SelectionCard = Global.SELECTION_CARD_SCENE.instantiate()
		card.pressed.connect(_on_player_selected.bind(player))
		player_container.add_child(card)
		card.set_icon(player.icon)
		
		# 绑定(数据, 卡片)：卡片当锚点，数据在回调里现取
		#card.mouse_entered.connect(_on_selection_unit_card_mouse_entered.bind(player, card))
		card.mouse_entered.connect(TooltipManager.show_for_control.bind(card, player))
		card.mouse_exited.connect(TooltipManager.hide_tip)
		
		
## 按 start_weapons 数组铺一排初始武器卡。逻辑与 load_players() 完全对称，
## 只有三点不同：
##   · 容器换成 %WeaponContainer；
##   · 回调换成 _on_weapon_selected.bind(weapon)（写 Global.main_weapon_selected）；
##   · 图标直接写 `card.icon = weapon.item_icon`（角色那边走的是 card.set_icon(...) 包装，
##     两条写法效果一样，属历史遗留的不统一）。
## 参数：无（用 @export start_weapons）。返回值：无。
## 副作用：start_weapons 为空时直接返回；否则实例化卡片、add_child、连信号（pressed + 悬停提示）。
## 提示：选中武器**没有任何视觉反馈**（卡片不会高亮、继续按钮也不会变化），
##   玩家只能靠"点一下有音效"来判断选上了。要加选中框得额外做状态标记。
func load_weapons() -> void:
	if start_weapons.is_empty():
		return
	for weapon: ItemWeapon in start_weapons:
		var card: SelectionCard = Global.SELECTION_CARD_SCENE.instantiate()
		card.pressed.connect(_on_weapon_selected.bind(weapon))
		weapon_container.add_child(card)
		# 武器的图标是直接写 Button.icon（和角色那边调 set_icon() 等价，只是写法不统一）
		card.icon = weapon.item_icon
		
		#card.mouse_entered.connect(_on_selection_item_card_mouse_entered.bind(weapon, card))
		card.mouse_entered.connect(TooltipManager.show_for_control.bind(card, weapon))
		card.mouse_exited.connect(TooltipManager.hide_tip)


## 显示 / 隐藏右侧的"角色详情"栏。
## 参数 value：true = 显示，false = 隐藏。四个控件同时开关（不看内容，只看标志位）。
## 返回值：无。
## 副作用：只改 4 个控件的 visible；不清空文本、不 emit 信号。
## 什么时候调用：_ready() 里先 false（还没选角色，别显示上一局的残留 / 空数据），
##   _on_player_selected() 里再 true。
## 注意：player_title 只在这里被开关，**没有任何代码写它的 text** —— 标题是场景里写死的。
func show_player_info(value: bool) -> void:
	player_icon.visible = value
	player_name.visible = value
	player_title.visible = value
	player_description.visible = value
	

## 某个角色卡被点击 → 记录选择结果并刷新详情栏。
## 参数 player：被点中的 UnitStats 资源（由 load_players() 里的 .bind(player) 带进来）。
## 返回值：无。
## 副作用：
##   · **写 Global.main_player_selected**（跨场景存活；GameRoot/_on_selection_completed 与
##     Arena 都靠它拿角色。Arena 还会拿它的 name 去 Global.available_players 查玩家场景）；
##   · 打开详情栏（show_player_info(true)）并填图标 / 名字 / 属性 BBCode；
##   · 不 emit 任何信号（"选完了"是点"继续"时才广播的）。
## 重复点击同一张卡是安全的（覆盖写同一个值，无副作用累积）。
## 注意：这里**不做**"选中高亮"，反复点不同角色只有右侧文字在变 —— 想加高亮要自己维护状态。
## 属性表的单位口径同 hover_unit_card.gd：block_chance 是百分数语义，所以 `%%` 只是拼一个字面 %。
## ⚠ 下面那个多行字符串的续行在源码里是**顶格**的（缩进会被原样写进 BBCode），别顺手补 tab。
func _on_player_selected(player: UnitStats) -> void:
	# 这是本面板**唯一**一处把选择结果写进 Global 的地方（唯一的全局状态副作用）
	Global.main_player_selected = player
	show_player_info(true)
	
	player_icon.texture = player.icon
	player_name.text = player.name
	# 详情栏填内容：BBCode 富文本（[code] 等宽、[color=green] 绿色数值），
	# 五个 %s 依次是 health / damage / speed / luck / block_chance。
	# block_chance 在 UnitStats 里是**百分数语义**（0~100+，Unit 里用 block_chance/100 掷骰），
	# 所以 `%%` 只是转义出一个字面百分号，不要在这里再 ×100。
	# ⚠ 这个多行字符串的续行在源码里是**顶格**的 —— 缩进会被原样写进文本，别顺手补 tab。
	player_description.text = "[code]Health: [color=green]%s[/color]
Damage: [color=green]%s[/color]
Speed: [color=green]%s[/color]
Luck: [color=green]%s[/color]
Block Chance: [color=green]%s%%[/color][/code]" % [player.health, player.damage, player.speed, player.luck, player.block_chance]


# ──────────────────────────────────────────────────────────────
#  新方案：悬停提示统一交给 TooltipManager（autoload，独立 CanvasLayer）
# ──────────────────────────────────────────────────────────────

## 角色卡悬停 → 弹提示卡（新方案的**封装版**）。
## 参数 unit：要展示的 UnitStats；参数 card：锚点控件（卡片自己）。
## 返回值：无。
## 副作用：转调 TooltipManager.show_for_control(card, unit)，由那个 autoload 负责
##   延迟 0.25 秒、淡入、按"控件右上角"定位、以及防抖。
## ⚠ 现状：**本函数目前没有任何调用方** —— load_players() 里改用了一行等价的直接连接
##   `card.mouse_entered.connect(TooltipManager.show_for_control.bind(card, player))`
##   （下面被注释掉的那行才是它的旧调用点）。保留它是为了"需要额外逻辑时有个地方写"，
##   但读代码时别以为它被连上了（连着的是 TooltipManager 的方法本身）。
func _on_selection_unit_card_mouse_entered(unit: UnitStats, card: SelectionCard) -> void:
	if unit == null:
		return
	TooltipManager.show_for_control(card, unit)

## 武器卡悬停 → 弹提示卡（新方案的封装版）。与上面那个函数完全对称，只是数据类型是 ItemWeapon。
## 参数 item：要展示的武器数据；参数 card：锚点控件。
## 返回值：无。副作用：转调 TooltipManager.show_for_control。
## ⚠ 同样**目前无调用方**（真正连的是 TooltipManager.show_for_control.bind(card, weapon)）。
func _on_selection_item_card_mouse_entered(item: ItemWeapon, card: SelectionCard) -> void:
	if item == null:
		return
	TooltipManager.show_for_control(card, item)

## 卡片悬停结束 → 收起提示卡（新方案的封装版）。
## 参数：无。返回值：无。副作用：转调 TooltipManager.hide_tip()。
## ⚠ **目前无调用方** —— 实际连的是 `card.mouse_exited.connect(TooltipManager.hide_tip)`，
##   直接把 autoload 的方法当回调接上了（TooltipManager 是常驻节点，Callable 不会悬空；
##   卡片被释放时 Godot 会自动清掉它发出的连接，不用手动断开）。
func _on_selection_card_mouse_exited() -> void:
	TooltipManager.hide_tip()


# ──────────────────────────────────────────────────────────────
#  旧方案（本地 hover card，已弃用）——保留备查，不再生效
# ──────────────────────────────────────────────────────────────
# func _on_selection_unit_card_mouse_entered(unit: UnitStats) -> void:
# 	hover_unit_card.unit = unit
# 	hover_unit_card.global_position = get_local_mouse_position()
# 	hover_unit_card.show()
# 
# func _on_selection_unit_card_mouse_exited() -> void:
# 	hover_unit_card.hide()
# 
# 
# func _on_selection_item_card_mouse_entered(item: ItemWeapon) -> void:
# 	hover_item_card.item = item
# 	hover_item_card.global_position = get_local_mouse_position()
# 	hover_item_card.show()
# 
# func _on_selection_item_card_mouse_exited() -> void:
# 	hover_item_card.hide()


## 某把初始武器被点击 → 记录选择结果。
## 参数 weapon：被点中的 ItemWeapon 资源（由 load_weapons() 的 .bind(weapon) 带进来）。
## 返回值：无。
## 副作用：**写 Global.main_weapon_selected**（跨场景存活）。
##   读它的地方：GameRoot._on_selection_completed()（塞进 party/装备列表）、
##   Arena._on_selection_panel_on_selection_completed()（add_weapon 给玩家并建一张 ItemCard）。
## 注意：本函数**不做任何 UI 反馈**（不高亮、不刷新详情栏）—— 点武器只有音效，
##   玩家无法从界面上看出自己选了哪把。想改善就得在这里加状态标记。
func _on_weapon_selected(weapon: ItemWeapon) -> void:
	Global.main_weapon_selected = weapon


## "继续"按钮的回调（selection_panel.tscn 里编辑器把 ContinueButton.pressed 连到这里）。
## 参数：无。返回值：无。
## 副作用（按顺序）：
##   1) 播一次 UI 音效 —— 注意它在**校验之前**，所以"没选完就点"也会有音效；
##   2) 两个结果任一为空（还没选角色 / 还没选武器）时**静默 return**：不提示、不报错。
##      继续按钮从来不置 disabled，玩家只会觉得"点了没反应"，这是当前设计的已知体验问题；
##   3) emit on_selection_completed（无参）—— 订阅者拿到信号后自己去读
##      Global.main_player_selected / main_weapon_selected：
##        · GameRoot._on_selection_completed()：组队 party、重置 equipped_weapons、进第一张地图；
##        · Arena._on_selection_panel_on_selection_completed()：add_child 玩家、发初始武器、开第一波；
##   4) hide() 自己 —— 只隐藏、**不释放**。地图模式下 GameRoot 的 _swap() 随后会把它换掉；
##      竞技场模式下它会一直挂在 GameUI 下（以后再 show() 出来就是这一份）。
## 关于 emit 与 hide 的先后：先 emit 再 hide，订阅者里如果读本节点的可见性，此刻还是"可见"的。
func _on_continue_button_pressed() -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	# 两个结果都来自点击回调写入的 Global 字段；少选一个就什么都不做（连提示都没有）
	if not Global.main_player_selected or not Global.main_weapon_selected:
		return
	on_selection_completed.emit()
	hide()
