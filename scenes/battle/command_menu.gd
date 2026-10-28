#  battle 指令菜单：主菜单（攻击/法术/道具/防御/逃跑）+ 技能二级菜单。挂在 battle.tscn 的 UI/CommandMenu 上。
#  纯 UI：只显示按钮并把点击翻译成 command_selected / skill_selected，战斗流程由 Battle 决定（单向依赖）。
#  数据现场读 open_for(unit)，不缓存；技能按钮每次打开技能页都重建。
#  坑：动态按钮 owner 为 null，释放只能自己 queue_free。
extends Panel
class_name CommandMenu

## 指令菜单：主菜单 + 技能二级菜单；只负责显示与发信号，具体行为由 Battle 决定。

# ── 对外信号（唯一的下游出口，发出去就不管返回值）──

## 主菜单指令被点。command 取 &"attack" / &"defend" / &"flee" / &"item"；&"skill" 走 _open_skills()。
signal command_selected(command: StringName)

## 技能页里点了具体技能。Battle._on_skill_selected() 会再校验一次 can_use_skill()。
signal skill_selected(skill: SkillData)

# ── 节点引用（%Xxx 需要场景里勾 unique_name_in_owner；@onready 在 _ready 前赋值）──
@onready var title_label: Label = %TitleLabel
## 主菜单按钮容器。
@onready var main_buttons: VBoxContainer = %MainButtons
## 技能按钮容器（每次打开技能页都清空重建）。
@onready var skill_buttons: VBoxContainer = %SkillButtons
## 五个主菜单按钮；绑定时用 bind() 附带指令标识。
@onready var attack_button: Button = %AttackButton
## “法术”按钮：打开技能页，不直接发信号；disabled 在 open_for() 里按有无技能设置。
@onready var skill_button: Button = %SkillButton
## “道具”按钮：_ready() 里写死禁用（道具系统未实现）。
@onready var item_button: Button = %ItemButton
@onready var defend_button: Button = %DefendButton
@onready var flee_button: Button = %FleeButton
## 技能页返回按钮；只切本地视图，不发信号、不通知 Battle。
@onready var back_button: Button = %BackButton

# ── 运行时状态 ──

## 当前为谁打开（open_for 写、close 清 null）。普通引用，单位被释放不会自动变 null。
var _unit: BattleUnit

# ── 跨回合记忆：上回合玩家选了什么 ──
## 上回合选中的一级指令（默认攻击）。
var _last_command := &"attack"
## 上回合在法术页选中的技能；非 null 时 open_for() 会直接回到法术页并选中它。
var _last_skill: SkillData = null


## 一次性接线：连六个按钮、“道具”永久禁用，先 _show_main() 再 close()（顺序不能换）。
## bind() 把指令标识追加在信号参数之后，四个按钮共用一个回调；子类覆盖 _ready() 必须调 super._ready()。
func _ready() -> void:
	attack_button.pressed.connect(_on_main_pressed.bind(&"attack"))
	# "法术"按钮单独接线：它要打开二级菜单，而不是直接发指令信号。
	skill_button.pressed.connect(_open_skills)
	item_button.pressed.connect(_on_main_pressed.bind(&"item"))
	defend_button.pressed.connect(_on_main_pressed.bind(&"defend"))
	flee_button.pressed.connect(_on_main_pressed.bind(&"flee"))
	# 注意：这里连的是 _on_back_pressed 而不是 _show_main —— 见那个函数的说明
	# （点"返回指令"必须顺手把键盘焦点补回来，否则之后方向键会失灵）。
	back_button.pressed.connect(_on_back_pressed)

	# 兜底：鼠标点在面板空白处时，如果焦点是空的就补回第一个可用指令。
	# 不这么做的话"点一下空白 → 方向键失灵"，玩家会以为键盘操作坏了。
	# 点在按钮上的事件会被按钮自己吃掉，不会走到这里。
	gui_input.connect(_on_panel_gui_input)

	# 给主按钮挂上指令标识：open_for() 恢复上回合选择时要按标识找按钮。
	attack_button.set_meta("command", &"attack")
	skill_button.set_meta("command", &"skill")
	item_button.set_meta("command", &"item")
	defend_button.set_meta("command", &"defend")
	flee_button.set_meta("command", &"flee")

	# 道具系统还没做，先禁用
	# 注意这只在 _ready() 里设一次，open_for() 不会重新启用它 —— 等道具做完要记得改这里。
	item_button.disabled = true

	_show_main()
	close()


## 为某个单位打开菜单。unit 可为 null（标题显示“指令”、法术禁用，不崩）。
## 副作用：写 _unit、标题、skill_button.disabled，切回主菜单并 show()；不发信号。
## skill_button.disabled 只表示“有没有技能”，单个技能能否放由 _make_skill_button() 判断。
func open_for(unit: BattleUnit) -> void:
	_unit = unit
	# 双层判空：unit 本身可能是 null，unit.stats 也可能是 null（资源没配）。
	if unit != null and unit.stats != null:
		title_label.text = unit.stats.name
	else:
		title_label.text = "指令"
	# `unit == null or not unit.has_skills()`：先判空再调方法，靠 or 的短路求值避免 null 访问。
	skill_button.disabled = unit == null or not unit.has_skills()
	show()
	# 恢复上回合的选择：
	#   上回合用的是法术 → 直接回法术页，焦点落在那个技能上（"记住二级菜单"）；
	#   否则回主菜单，焦点落在上回合那个指令上（"记住一级菜单"）。
	# 只抢焦点、不替玩家确认 —— 想换指令直接按方向键走。
	# 必须在 show() 之后调：隐藏中的 Control 拿不到焦点。
	if _last_skill != null and unit != null and unit.available_skills.has(_last_skill):
		_build_skill_page(_last_skill)
	else:
		_show_main()
		_focus_command(_last_command)


## 关闭菜单：hide() + _unit = null。不重置可见性、不发信号，下次 open_for() 会重新归位。
func close() -> void:
	hide()
	_unit = null


# ── 主菜单 / 技能菜单 ──

## 切到主菜单视图（隐藏技能页与返回按钮）。不动整个 Panel 的显隐，那是 open_for()/close() 的事。
## 从技能页返回时不发信号，Battle 不知道玩家点过返回（state 仍是 COMMAND，这是对的）。
func _show_main() -> void:
	main_buttons.visible = true
	skill_buttons.visible = false
	back_button.visible = false
	# 键盘导航：把当前可用的主菜单按钮串成一条链（方向键的顺序 = 这里被跳过的按钮不算数）。
	# 只接线、不抢焦点 —— 抢焦点由 open_for() / _open_skills() / ESC 返回时负责。
	_wire_dpad(main_buttons.get_children())


# ── 键盘导航（与鼠标操作并存）──
# 用引擎内建焦点系统：Button 默认 FOCUS_ALL，方向键自动移动，ui_accept 自动按下，disabled 天然跳过。
# 只缺“竖排左右移动”和“默认焦点落哪”，下面两个函数补这两点。

## 把按钮按顺序串成方向键环（首尾相接），剔除 disabled 的。每次内容 / 禁用状态变化都要重调。
## 引擎默认按几何位置找邻居，竖排按左右会没反应；disabled 按钮混进链里会卡住焦点。
func _wire_dpad(buttons: Array) -> void:
	var items: Array[Button] = []
	for child in buttons:
		if child is Button and not child.disabled:
			items.append(child)
	var count := items.size()
	if count == 0:
		return
	for i in count:
		var prev := items[(i - 1 + count) % count]
		var next := items[(i + 1) % count]
		items[i].focus_neighbor_left = prev.get_path()
		items[i].focus_neighbor_top = prev.get_path()
		items[i].focus_neighbor_right = next.get_path()
		items[i].focus_neighbor_bottom = next.get_path()


## 把焦点落到列表里第一个可用按钮（找不到就什么都不做）。
func _focus_first(buttons: Array) -> void:
	for child in buttons:
		if child is Button and not child.disabled and child.is_visible_in_tree():
			child.grab_focus()
			return


## ESC：技能页里退回主菜单；主菜单里不处理，交给 Battle。
func _unhandled_input(event: InputEvent) -> void:
	if not visible or not skill_buttons.visible:
		return
	if event.is_action_pressed("ui_cancel"):
		_on_back_pressed()
		get_viewport().set_input_as_handled()


## “返回指令”统一入口（鼠标点 / ESC / Enter）。切回主菜单后必须重新 grab_focus()：
## 鼠标点按钮会把焦点给它，_show_main() 随即隐藏它，Control 一隐藏引擎就释放焦点，之后方向键全失效。
func _on_back_pressed() -> void:
	_show_main()
	_focus_first(main_buttons.get_children())


## 面板空白处点击：等一帧让页面切换跑完，焦点空了就补回第一个可用指令。
func _on_panel_gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed):
		return
	await get_tree().process_frame
	if get_viewport().gui_get_focus_owner() == null:
		var buttons: Array = skill_buttons.get_children() if skill_buttons.visible else main_buttons.get_children()
		_focus_first(buttons)


## 打开技能页：播音效 → 清空旧按钮 → 按 _unit.available_skills 重建 → 切视图（不发信号）。
## 先 remove_child 再 queue_free：queue_free 到帧末才释放，直接 add_child 会出现新旧按钮同帧重叠。
## 空列表时放一个居中 Label，避免空白页看起来像 bug。读的是 available_skills，不是 UnitStats.skills。
func _open_skills() -> void:
	# 防御性判断：菜单理论上只在 open_for() 之后才会显示，但这里再挡一次 null。
	if _unit == null:
		return
	SoundManager.play_sound(SoundManager.Sound.UI)
	_last_command = &"skill"
	_build_skill_page(null)


## 重建法术页（不放音效 —— open_for() 恢复上回合选择时也要用）。
## 参数 focus_skill：要选中的技能；null = 落第一个可用项。
func _build_skill_page(focus_skill: SkillData) -> void:
	if _unit == null:
		return
	for child in skill_buttons.get_children():
		skill_buttons.remove_child(child)
		child.queue_free()

	var count := 0
	for skill in _unit.available_skills:
		# 技能表里可能有 null 空位（编辑器里拖漏了），跳过而不是崩。
		if skill == null:
			continue
		skill_buttons.add_child(_make_skill_button(skill))
		count += 1
	if count == 0:
		# 纯代码建 Label：horizontal_alignment 设成居中，保证提示文字在按钮栏宽里居中显示。
		var empty := Label.new()
		empty.text = "（没有可用技能）"
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		skill_buttons.add_child(empty)

	main_buttons.visible = false
	skill_buttons.visible = true
	back_button.visible = true
	# 键盘导航：技能按钮 + "返回指令" 串成一条链，焦点落在第一个可用技能上。
	# disabled 的技能按钮（蓝不够 / 冷却中）会被 _wire_dpad / _focus_first 自动剔除，
	# 所以方向键不会卡在一个按不下去的项上；一个技能都用不了时焦点会落到"返回指令"。
	var chain: Array = skill_buttons.get_children()
	chain.append(back_button)
	_wire_dpad(chain)
	if not _focus_skill(focus_skill):
		_focus_first(chain)


## 把焦点落到指定技能的按钮上；找到并聚焦返回 true。
func _focus_skill(skill: SkillData) -> bool:
	if skill == null:
		return false
	for child in skill_buttons.get_children():
		if child is Button and not (child as Button).disabled \
				and child.get_meta("skill", null) == skill:
			(child as Button).grab_focus()
			return true
	return false


## 把焦点落到某个一级指令对应的按钮上（不可用时退回第一个可用项）。
func _focus_command(command: StringName) -> void:
	for child in main_buttons.get_children():
		if child is Button and not (child as Button).disabled \
				and child.get_meta("command", &"") == command:
			(child as Button).grab_focus()
			return
	_focus_first(main_buttons.get_children())


## 造一个技能按钮：只显示“技能名 + 状态后缀”。
## 后缀优先冷却、其次蓝不够；可用性用 can_use_skill()。
## ⚠ 不再显示蓝耗数字（"蓝6"）—— 蓝耗已经统一成 5，写出来只是噪音。
## 副作用：接 pressed → _on_skill_pressed.bind(skill)，只读 _unit 数据；必须在 _unit 有效时调用。
func _make_skill_button(skill: SkillData) -> Button:
	var button := Button.new()
	var suffix := ""
	var cd := _unit.cooldown_left(skill)
	if cd > 0:
		suffix = "  冷却%d" % cd
	elif _unit.mp < skill.mana_cost:
		suffix = "  蓝不够"
	button.text = "%s%s" % [skill.display_name, suffix]
	button.custom_minimum_size = Vector2(180, 46)
	button.add_theme_font_size_override("font_size", 20)
	button.disabled = not _unit.can_use_skill(skill)
	button.set_meta("skill", skill)
	# bind(skill)：pressed 信号无参数，bind 的值会作为第一个参数传给 _on_skill_pressed。
	button.pressed.connect(_on_skill_pressed.bind(skill))
	return button


# ── 按钮回调（把 UI 事件翻译成信号）──

## 主菜单按钮共用回调。播 UI 音效并 emit command_selected()。
## 不关菜单：关闭是 Battle 的职责（道具 / 技能未实现时要留着让玩家重选）。
func _on_main_pressed(command: StringName) -> void:
	_last_command = command
	_last_skill = null          # 选了普通指令 = 下次不再回法术页
	SoundManager.play_sound(SoundManager.Sound.UI)
	command_selected.emit(command)


## 技能按钮回调。播 UI 音效并 emit skill_selected()；不做蓝量 / 冷却校验，准入由 Battle 负责。
func _on_skill_pressed(skill: SkillData) -> void:
	_last_command = &"skill"
	_last_skill = skill
	SoundManager.play_sound(SoundManager.Sound.UI)
	skill_selected.emit(skill)
