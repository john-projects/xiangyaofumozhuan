extends Control
class_name StatsPanel

## 角色属性面板 —— 上半部分是"角色形象 + 六个装备栏"（和背包完全一致），下半部分是属性表格。
##
## ── 打开方式（由 WorldMap 的输入状态机管）──
##   地图上按 `C`，或 `Esc` →「角色属性」；`Esc` / `C` / `B` 关闭。
##   ⚠ 打开时会**同时打开背包**（属性面板贴左边、背包贴右边，两个都能点）。
##
## ── 上半部分：复用 CharacterArea（scenes/ui/character_area/）──
##   形象框 240×308 + 左右各 3 个 96px 装备栏 + 名字牌，和背包那块是同一个场景。
##   点已穿的装备栏 = 请求脱下（emit unequip_requested，判定仍在 GameRoot.unequip_slot）。
##
## ── 下半部分：两列表格（固定位置，仿"人物属性"面板）──
##   左列：名称 / 种族 / 气血 / 伤害 / 速度 / 魔法 / 防御 / 法伤
##   右列：等级 / 门派 / 体质 / 力量 / 敏捷 / 魔力 / 耐力 / 自由点数
##   然后「经验」**单独占一行**，再下面是直接展示的 输出 / 抗性 两栏。
##   （基础属性刻意排在右列，和参考图一致；气血/伤害/速度 旁边就是对应的体质/力量/敏捷。）
##
## ── 加点流程（先暂存，再确认）──
##   「＋/－」只改**面板里的暂存差值**（_pending），不写 Global：
##     · ＋：消耗 1 点（暂存后剩余自由点 ≥ 0 才允许）；
##     · －：撤销这一项上暂存的 1 点（已确认的点数**不会**被减，避免误操作洗点）；
##     · 自由点数的显示 = 真实剩余 − 暂存总量，边点边看到还剩多少；
##     · 点「确认加点」才调 GameRoot.apply_attr_deltas() 一次性落盘，然后清空暂存。
##   切换角色会丢弃暂存（避免"看 A 点了一堆，切到 B 又确认"）。
##
## ── 输出 / 抗性（直接展示，没有下拉、没有滚动条）──
##   表格下面左右两栏：输出（暴击率、暴击伤害、封印命中率、治疗量）/
##   抗性（躲避、格挡率、格挡值、抗暴击率、爆伤减免、抵抗封印）。
##   只放本项目真的定义了的属性；整块面板高度按内容算死，不做滚动。
##
## ── 尺寸与位置 ──
##   和背包**同宽（662）**；贴在屏幕**左下角**（背包在右下角，天然不重叠）。
##   ⚠ 本面板**故意不带全屏遮罩**：遮罩会把并排的背包压暗、吃掉它的鼠标事件。

## 面板里 ◀ / ▶ 换了展示的角色。WorldMap 收到后会让背包切到同一个人（反之亦然）。
signal character_view_changed(character: UnitStats)

## 点了某个**已穿上装备**的装备栏：请求脱下来。WorldMap 会转到和背包同一条通路。
signal unequip_requested(slot_type: int)

## 玩家点了「＋ / －」或「确认加点」。WorldMap 收到后重设焦点环
## （点数花完/暂存清空时按钮的可用状态变了）。
signal points_spent

## 面板宽度：和背包（BagPanel 的 662）一致。
const PANEL_WIDTH := 662.0
## 离屏幕右边/下边的留白（和背包/商人一致）。
const WINDOW_MARGIN := 16.0
## 面板内部上下留白（和 .tscn 里 Margin 的 margin_top/bottom 一致，算总高度时要加回来）。
const WINDOW_PADDING_V := 16.0
## 高度下限：内容再少也别缩成一条（正常情况下高度=视口高−上下边距，和背包一样占满）。
const MIN_HEIGHT := 620.0
## 表格：值框高度 / 行间距 / 名字列宽 / 每格右侧按钮区宽度（＋－各一半，或整个"确认加点"）。
const VALUE_HEIGHT := 26.0
const GRID_V_SEPARATION := 4
const LABEL_WIDTH := 62.0
const ACTION_WIDTH := 70.0
## 格子种类：没有按钮 / 某个基础属性（0..4）/ 确认加点按钮。
const CELL_NONE := -1
const CELL_CONFIRM := -2

@onready var panel: Panel = get_node_or_null(^"Panel") as Panel
## 上半部分：形象 + 六个装备栏（和背包同一个场景）。
@onready var character_area: CharacterArea = %CharacterArea
@onready var content: VBoxContainer = %Content
@onready var attr_tab: Button = %AttrTab
@onready var skill_tab: Button = %SkillTab
@onready var stats_box: VBoxContainer = %StatsBox

## 当前页：0 = 属性（默认），1 = 技能。
## 两个页共用同一块下半部分区域（stats_box），切页就是清空重建；
## 上半部分（形象/装备栏）两页都保留 —— 换装备时不用切回属性页。
var _page := 0

## 网格里留下的引用（都按 ATTR_KEYS 下标索引，加点后就地刷新，不重建节点）。
var _attr_value_labels: Array[Label] = []
var _attr_plus_buttons: Array[Button] = []
var _attr_minus_buttons: Array[Button] = []
var _confirm_button: Button = null
var _derived_labels: Dictionary = {}
var _free_label: Label = null

## 暂存的加点差值（还没确认的那些点）。长度 5，顺序同 ATTR_KEYS。
var _pending: Array[int] = [0, 0, 0, 0, 0]
## 暂存属于哪个角色（换人就丢弃，见文件头的"加点流程"）。
var _pending_character: UnitStats = null
## 外部指定的高度（WorldMap 在打开时传入背包的高度，让两个窗口看起来一样高）。
## 0 = 没指定，按内容自身需要的高度。
var _linked_height := 0.0

func _ready() -> void:
	hide()
	# 换人 / 脱下装备的事件都来自上半部分，这里只负责转发给 WorldMap
	character_area.character_changed.connect(_on_area_character_changed)
	character_area.unequip_requested.connect(func(slot_type: int) -> void: unequip_requested.emit(slot_type))
	# 两个页签互斥：ButtonGroup 保证同一时刻只有一个处于按下状态（视觉上就是"当前页"）
	var group := ButtonGroup.new()
	attr_tab.button_group = group
	skill_tab.button_group = group
	attr_tab.pressed.connect(func() -> void: _switch_page(0))
	skill_tab.pressed.connect(func() -> void: _switch_page(1))
	_apply_geometry()
	get_viewport().size_changed.connect(_apply_geometry)


## 切页：0 = 属性，1 = 技能。
## 参数 page：目标页。
## 副作用：改 _page、同步两个页签的按下状态、重建下半部分、重算高度（两页内容高度不同）。
func _switch_page(page: int) -> void:
	if page == _page:
		return
	_page = page
	attr_tab.button_pressed = page == 0
	skill_tab.button_pressed = page == 1
	SoundManager.play_sound(SoundManager.Sound.UI)
	_rebuild()
	_apply_geometry()


## 外部指定高度（WorldMap 在打开属性面板时把背包的高度传进来，让两个窗口看起来一样高）。
## 参数 value：目标高度（像素；<=0 = 不指定，按内容自身高度）。
## 副作用：记下并重算一次面板尺寸。
func set_linked_height(value: float) -> void:
	_linked_height = value
	_apply_geometry()


## 打开面板并展示团队里"当前主角"的属性。
func show_stats(party: Array[UnitStats]) -> void:
	show()
	character_area.show_party(party)
	_rebuild()
	_apply_geometry()


## 面板当前展示的是谁（◀ / ▶ 切换的那个团队成员）。
func current_character() -> UnitStats:
	return character_area.current_character()


## 当前可以聚焦的控件：两个页签 + ◀ / ▶ + （＋ / －）× 5 + 确认加点（后两者只在属性页有）。
## 装备栏**不进环**：背包同屏，那边已经有一份可点的装备栏。
func focus_ring() -> Array[Control]:
	var out: Array[Control] = []
	for button in [attr_tab, skill_tab]:
		if button != null and is_instance_valid(button):
			out.append(button)
	out.append_array(character_area.focus_ring())
	for button in _attr_plus_buttons:
		if button != null and is_instance_valid(button) and not button.disabled:
			out.append(button)
	for button in _attr_minus_buttons:
		if button != null and is_instance_valid(button) and not button.disabled:
			out.append(button)
	if _confirm_button != null and is_instance_valid(_confirm_button) and not _confirm_button.disabled:
		out.append(_confirm_button)
	return out


## 切到指定的角色（WorldMap 在"背包换人了"时调它）。
## ⚠ 换人会丢弃暂存加点（_rebuild 里按角色判断）。
func show_character(character: UnitStats) -> void:
	character_area.show_character(character)
	_rebuild()


## 按当前角色重新读一遍数据（装备变了但"看谁"没变时用）。
## 暂存的加点**不会**被清掉（只是重建界面）。
func refresh() -> void:
	if not visible:
		return
	character_area.refresh()
	_rebuild()
	_apply_geometry()


## 上半部分换了人：重建属性 + 通知 WorldMap（让背包跟着切）。
func _on_area_character_changed(character: UnitStats) -> void:
	_rebuild()
	character_view_changed.emit(character)


## ◀ / ▶ 的兼容入口（下标由 CharacterArea 管）。
func _step_player(step: int) -> void:
	character_area.step_player(step)


# ══════════════════════════════════════════════════════════
#  内容重建
# ══════════════════════════════════════════════════════════

## 重建**下半部分**（两列表格 + 经验行 + 输出/抗性）。上半部分（形象/装备栏）归 CharacterArea 自己刷。
func _rebuild() -> void:
	var character := current_character()
	# 换人就丢弃暂存：否则会出现"给 A 点了一堆，切到 B 却把点数确认到 B 身上"
	if character != _pending_character:
		_pending = [0, 0, 0, 0, 0]
		_pending_character = character

	_clear(stats_box)
	_attr_value_labels.clear()
	_attr_plus_buttons.clear()
	_attr_minus_buttons.clear()
	for i in GameRoot.ATTR_KEYS.size():
		_attr_value_labels.append(null)
		_attr_plus_buttons.append(null)
		_attr_minus_buttons.append(null)
	_derived_labels.clear()
	_free_label = null
	_confirm_button = null

	if character == null:
		var note := Label.new()
		note.text = "（没有可展示的角色）"
		note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		stats_box.add_child(note)
		return

	# 技能页：同一块区域换成"已学技能"列表（上半部分形象/装备栏保留）
	if _page == 1:
		_build_skills_page(character)
		return

	var derived := GameRoot.derived_stats(character)
	_build_stats_grid(character, derived)
	_build_sections(character, derived)
	_add_sect_skills_line(character)
	_refresh_attr_values()


# ── 两列表格 ───────────────────────────────────────────────────────────────

## 造下半部分的固定两列表格（4 列网格：名字 / 格子 / 名字 / 格子；
## 每个"格子" = 值框 + 右侧按钮区，按钮区宽度固定，所以所有值框左右对齐）。
func _build_stats_grid(character: UnitStats, derived: Dictionary) -> void:
	var grid := GridContainer.new()
	grid.name = "StatsGrid"
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", GRID_V_SEPARATION)
	stats_box.add_child(grid)

	var exp_text := "已满级"
	if Global.player_level < GameRoot.MAX_LEVEL:
		var need := GameRoot.exp_to_next(Global.player_level)
		var pct := int(roundf(100.0 * Global.player_exp / maxf(1.0, need)))
		exp_text = "%d / %d（%d%%）" % [Global.player_exp, need, pct]
	var sect_id := GameRoot.sect_of(character)
	var sect_text := Global.sect_name(sect_id) if not sect_id.is_empty() else "无门派"

	# 第 1 行：名称 / 等级
	_add_grid_row(grid, "名称", character.name, CELL_NONE,
			"等级", "%d / %d" % [Global.player_level, GameRoot.MAX_LEVEL], CELL_NONE)
	# 第 2 行：种族 / 门派
	_add_grid_row(grid, "种族", character.race_name(), CELL_NONE, "门派", sect_text, CELL_NONE)
	# 第 3 行：气血 / 体质（＋－）
	_add_grid_row(grid, "气血", _stat_text(float(derived["hp"])), CELL_NONE,
			"体质", _attr_text(0), 0, "hp")
	# 第 4 行：魔法 / 力量（＋－）
	_add_grid_row(grid, "魔法", _stat_text(float(derived["mana"])), CELL_NONE,
			"力量", _attr_text(2), 2, "mana")
	# 第 5 行：伤害 / 敏捷（＋－）
	_add_grid_row(grid, "伤害", _stat_text(float(derived["damage"])), CELL_NONE,
			"敏捷", _attr_text(4), 4, "damage")
	# 第 6 行：法伤 / 魔力（＋－）
	_add_grid_row(grid, "法伤", _fmt("spell_damage", float(derived["spell_damage"])), CELL_NONE,
			"魔力", _attr_text(1), 1, "spell_damage")
	# 第 7 行：防御 / 耐力（＋－）
	_add_grid_row(grid, "防御", _stat_text(float(derived["defense"])), CELL_NONE,
			"耐力", _attr_text(3), 3, "defense")
	# 第 8 行：速度 / 自由点数（右边带「确认加点」）
	var last_row := _add_grid_row(grid, "速度", _stat_text(float(derived["speed"])), CELL_NONE,
			"自由点数", "%d 点" % _free_display(), CELL_CONFIRM, "speed")
	_free_label = last_row[1]

	# 经验：单独占一行（放表格里会挤掉法伤/自由点数的位置）
	var exp_row := HBoxContainer.new()
	exp_row.name = "ExpRow"
	exp_row.add_theme_constant_override("separation", 8)
	exp_row.add_child(_make_grid_label("经验"))
	var exp_box := _make_grid_value(exp_text)
	exp_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	exp_row.add_child(exp_box)
	stats_box.add_child(exp_row)


## 加一行表格。左右各一个"名字 + 格子"；格子 = 值框 + 按钮区（kind 决定按钮）。
## 参数 left_kind/right_kind：CELL_NONE / 0..4（基础属性）/ CELL_CONFIRM；
##   left_key/right_key：派生属性键（非空时记进 _derived_labels，确认加点后刷新）。
## 返回值：[左值 Label, 右值 Label]。
func _add_grid_row(grid: GridContainer, left_label: String, left_value: String, left_kind: int,
		right_label: String, right_value: String, right_kind: int,
		left_key := "", right_key := "") -> Array[Label]:
	grid.add_child(_make_grid_label(left_label))
	var left_cell := _make_cell(left_value, left_kind, left_key)
	grid.add_child(left_cell)
	grid.add_child(_make_grid_label(right_label))
	var right_cell := _make_cell(right_value, right_kind, right_key)
	grid.add_child(right_cell)
	var out: Array[Label] = []
	var left_box := left_cell.get_node_or_null(^"ValueBox")
	out.append(left_box.get_node_or_null(^"ValueLabel") as Label if left_box != null else null)
	var right_box := right_cell.get_node_or_null(^"ValueBox")
	out.append(right_box.get_node_or_null(^"ValueLabel") as Label if right_box != null else null)
	return out


## 一个"格子"：值框 + 右侧按钮区。按钮区宽度固定（ACTION_WIDTH），
## 所以有没有按钮、按钮是什么，都不会让左右两列的值框宽度跳动。
func _make_cell(value: String, kind: int, key := "") -> HBoxContainer:
	var cell := HBoxContainer.new()
	cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cell.add_theme_constant_override("separation", 0)
	cell.add_child(_make_grid_value(value, key, kind if kind >= 0 else -1))
	if kind >= 0:
		cell.add_child(_make_attr_button(kind, 1))
		cell.add_child(_make_attr_button(kind, -1))
	elif kind == CELL_CONFIRM:
		cell.add_child(_make_confirm_button())
	else:
		var spacer := Control.new()
		spacer.custom_minimum_size = Vector2(ACTION_WIDTH, 0)
		cell.add_child(spacer)
	return cell


## 表格里的名字格子（固定宽度，保证两列对齐）。
func _make_grid_label(text: String) -> Control:
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(LABEL_WIDTH, 0)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 16)
	label.modulate = Color(1, 1, 1, 0.72)
	return label


## 表格里的值框（深色描边盒子 + 左对齐数值）。
## 参数 attr_index >= 0 时把这个 Label 记进 _attr_value_labels[attr_index]；
##   key 非空时记进 _derived_labels（确认加点后就地改）。
func _make_grid_value(text: String, key := "", attr_index := -1) -> PanelContainer:
	var box := PanelContainer.new()
	box.name = "ValueBox"
	box.custom_minimum_size = Vector2(0, VALUE_HEIGHT)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_stylebox_override("panel", _value_style())
	var label := Label.new()
	label.name = "ValueLabel"
	label.text = text
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 17)
	box.add_child(label)
	if attr_index >= 0:
		_attr_value_labels[attr_index] = label
	if not key.is_empty():
		_derived_labels[key] = label
	return box


## 基础属性的「＋ / －」小按钮（各占半个按钮区）。
## delta = +1 加一点（暂存），-1 撤销这点属性上暂存的 1 点。
func _make_attr_button(index: int, delta: int) -> Button:
	var button := Button.new()
	button.text = "＋" if delta > 0 else "－"
	button.custom_minimum_size = Vector2(ACTION_WIDTH / 2.0, VALUE_HEIGHT)
	button.add_theme_font_size_override("font_size", 18)
	if delta > 0:
		button.tooltip_text = "给%s暂存 1 点（还要点「确认加点」才生效）" % GameRoot.ATTR_NAMES[index]
		_attr_plus_buttons[index] = button
	else:
		button.tooltip_text = "撤销 %s 上暂存的 1 点" % GameRoot.ATTR_NAMES[index]
		_attr_minus_buttons[index] = button
	button.pressed.connect(_on_attr_button.bind(index, delta))
	return button


## 「确认加点」按钮（放在自由点数那一格的右边，宽度正好占满按钮区）。
func _make_confirm_button() -> Button:
	var button := Button.new()
	button.name = "ConfirmButton"
	button.text = "确认加点"
	button.custom_minimum_size = Vector2(ACTION_WIDTH, VALUE_HEIGHT)
	button.add_theme_font_size_override("font_size", 13)
	button.clip_text = true
	button.tooltip_text = "把加减后的点数确认加到角色属性上"
	button.pressed.connect(_on_confirm_pressed)
	_confirm_button = button
	return button


## 值框的底板样式：深色底 + 细描边 + 小圆角。
func _value_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.145, 0.145, 0.18, 0.95)
	style.border_color = Color(0.36, 0.31, 0.25, 1.0)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 3
	style.content_margin_bottom = 3
	return style


# ── 输出 / 抗性（直接展示，没有下拉）──────────────────────────────────────────

## 造表格下面的"输出 / 抗性"两栏（左右并排，省一半高度）。
## 参数 character：角色；derived：GameRoot.derived_stats() 的结果。
## 只放本项目真的定义了的属性：参考图里的命中/活力/愤怒之类一律没有，直接不显示。
## 每一行都是「名字 + 值框」，和上面主表格同一套样式；key 非空时记进 _derived_labels（确认加点后刷新）。
func _build_sections(character: UnitStats, derived: Dictionary) -> void:
	# 和上面的基础属性表格拉开一点距离（不然两块贴在一起，看着像一张表）
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 16)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stats_box.add_child(gap)

	var row := HBoxContainer.new()
	row.name = "SectionsRow"
	row.add_theme_constant_override("separation", 16)
	stats_box.add_child(row)

	# 左栏：输出（四项二级输出属性；法伤已经在上面表格里，不重复）
	var attack_col := _make_section_column("输出")
	_add_section_row(attack_col, "暴击率", _fmt("crit_rate", float(derived["crit_rate"])), "crit_rate")
	_add_section_row(attack_col, "暴击伤害",
			_fmt("crit_damage_bonus", float(derived["crit_damage_bonus"])), "crit_damage_bonus")
	_add_section_row(attack_col, "封印命中率", _fmt("seal_hit", float(derived["seal_hit"])), "seal_hit")
	_add_section_row(attack_col, "治疗量", _fmt("healing", float(derived["healing"])), "healing")
	row.add_child(attack_col)

	# 右栏：抗性（躲避/格挡率 + 四项二级防御属性）
	var defense_col := _make_section_column("抗性")
	_add_section_row(defense_col, "躲避", _fmt("dodge", float(derived["dodge"])), "dodge")
	_add_section_row(defense_col, "格挡率", _fmt("block_chance", character.block_chance))
	_add_section_row(defense_col, "格挡值", _fmt("block_value", float(derived["block_value"])), "block_value")
	_add_section_row(defense_col, "抗暴击率", _fmt("crit_resist", float(derived["crit_resist"])), "crit_resist")
	_add_section_row(defense_col, "爆伤减免",
			_fmt("crit_damage_resist", float(derived["crit_damage_resist"])), "crit_damage_resist")
	_add_section_row(defense_col, "抵抗封印", _fmt("seal_resist", float(derived["seal_resist"])), "seal_resist")
	row.add_child(defense_col)


## 门派技能一行摘要（5 个技能名 + 共享的等级），悬停看每个技能的说明。## 为什么只做一行：面板已经排满，5 个技能各占一行会把它撑高、破坏"不滚动"的布局；
##   技能名本身就能看出是哪个门派，完整效果放在 tooltip 里。
func _add_sect_skills_line(character: UnitStats) -> void:
	var label := Label.new()
	label.name = "SectSkillsLabel"
	label.text = GameRoot.sect_skill_summary(character)
	label.tooltip_text = GameRoot.sect_skill_details(character)
	label.add_theme_font_size_override("font_size", 14)
	label.modulate = Color(1, 0.92, 0.7, 0.9)
	label.clip_text = true
	label.mouse_filter = Control.MOUSE_FILTER_STOP   # 默认 IGNORE，设 STOP 才能触发 tooltip
	stats_box.add_child(label)


# ── 技能页 ────────────────────────────────────────────────────────────────

## 造"技能"页：列出当前角色学过的所有技能（和"属性"页共用下半部分）。
## 来源两块：
##   · 门派技能：拜师时学到的 2 被动 + 3 主动（共享一个等级），数据在 Global.SECT_SKILLS；
##   · 角色技能：UnitStats.skills 里配置的 SkillData。
## 每个技能占两行：标题（【被动】名字 Lv.N）+ 说明（截断，悬停看全）。
func _build_skills_page(character: UnitStats) -> void:
	var sect_id := GameRoot.sect_of(character)
	if sect_id.is_empty():
		_add_skills_header("门派技能")
		_add_skills_note("还没有拜入门派 —— 去建邺城找五位掌门拜师，入门即学会本门 5 个技能。")
	else:
		var level := GameRoot.sect_skill_level(character)
		_add_skills_header("%s · 门派技能 Lv.%d" % [Global.sect_name(sect_id), level])
		for skill in Global.sect_passives(sect_id):
			_add_skill_row("被动", String(skill["name"]), level, String(skill["desc"]))
		for skill in Global.sect_actives(sect_id):
			var targets := ""
			if skill.has("targets") or bool(skill.get("targets_all", false)):
				targets = "（当前目标：%s）" % Global.sect_skill_targets_text(skill, level)
			_add_skill_row("主动", String(skill["name"]), level, String(skill["desc"]) + targets)

	if character.skills.is_empty():
		_add_skills_header("角色技能")
		_add_skills_note("暂无（这个角色的 UnitStats.skills 里没有配技能）。")
	else:
		_add_skills_header("角色技能")
		for skill in character.skills:
			if skill == null:
				continue
			_add_skill_row("技能", skill.display_name, 0, skill.description)


## 技能页的分组标题（"太虚剑宗 · 门派技能 Lv.3" / "角色技能"）。
func _add_skills_header(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 17)
	label.modulate = Color(1, 0.86, 0.55, 0.95)
	stats_box.add_child(label)


## 技能页的说明文字（没拜师 / 没配技能时的提示）。
func _add_skills_note(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 13)
	label.modulate = Color(1, 1, 1, 0.55)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stats_box.add_child(label)


## 技能页里的一条技能：第一行【类型】名字 Lv.N，第二行说明（截断 + tooltip）。
## 参数 tag：被动 / 主动 / 技能；name：技能名；level：等级（<=0 表示没有等级，不显示 Lv）；
##   desc：说明文字。
func _add_skill_row(tag: String, name: String, level: int, desc: String) -> void:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	var tag_label := Label.new()
	tag_label.text = "【%s】" % tag
	tag_label.add_theme_font_size_override("font_size", 13)
	tag_label.modulate = Color(1, 0.78, 0.45, 0.95)
	head.add_child(tag_label)
	var name_label := Label.new()
	name_label.text = ("%s Lv.%d" % [name, level]) if level > 0 else name
	name_label.add_theme_font_size_override("font_size", 16)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(name_label)
	row.add_child(head)
	var desc_label := Label.new()
	desc_label.text = desc
	desc_label.add_theme_font_size_override("font_size", 12)
	desc_label.modulate = Color(1, 1, 1, 0.68)
	desc_label.clip_text = true
	desc_label.tooltip_text = desc
	desc_label.mouse_filter = Control.MOUSE_FILTER_STOP
	row.add_child(desc_label)
	stats_box.add_child(row)


## 一栏"输出"或"抗性"：小标题 + 若干行（值框）。
func _make_section_column(title: String) -> VBoxContainer:
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 4)
	var header := Label.new()
	header.text = title
	header.add_theme_font_size_override("font_size", 16)
	header.modulate = Color(1, 0.86, 0.55, 0.95)
	column.add_child(header)
	return column


## 一栏里的一行「名字 + 值框」。key 非空时记进 _derived_labels（确认加点后一起刷新）。
func _add_section_row(column: VBoxContainer, title: String, value: String, key := "") -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.add_child(_make_grid_label(title))
	row.add_child(_make_grid_value(value, key))
	column.add_child(row)


## 二级属性的显示格式：百分数带 %，暴击伤害显示"基础 150% + 加成"，其余直接取整。
## 参数 key：derived_stats() 的键（或 "block_chance"）；value：数值（百分数语义）。
func _fmt(key: String, value: float) -> String:
	if key == "crit_damage_bonus":
		# 战斗里暴击固定 ×1.5，所以"暴击伤害"显示的是 150% + 额外加成
		return "%s%%" % _stat_text(value + 150.0)
	if key in ["crit_rate", "seal_hit", "crit_resist", "crit_damage_resist",
			"seal_resist", "dodge", "block_chance"]:
		return "%s%%" % _stat_text(value)
	return _stat_text(value)


# ── 加点（暂存 → 确认）──────────────────────────────────────────────────

## 点了一次「＋」或「－」：只改**暂存差值**，不写 Global。
## 参数 index：哪一项（0..4，顺序同 ATTR_KEYS）；delta：+1 / -1。
## 副作用：改 _pending；就地刷新五项数值、自由点数、按钮可用状态；发 points_spent 让 WorldMap 重设焦点环。
func _on_attr_button(index: int, delta: int) -> void:
	var character := current_character()
	if character == null:
		return
	if delta > 0:
		# 暂存后剩余自由点必须 ≥ 0 才允许加
		if GameRoot.free_attribute_points(character) - _pending_total() <= 0:
			return
		_pending[index] += 1
	else:
		# 只能撤销"暂存"的点；已经确认过的点数不会被减（避免误操作洗点）
		if _pending[index] <= 0:
			return
		_pending[index] -= 1
	SoundManager.play_sound(SoundManager.Sound.UI)
	_refresh_attr_values()
	points_spent.emit()


## 点「确认加点」：把暂存的一组差值一次性写进 Global（GameRoot.apply_attr_deltas 是唯一写入点）。
## 副作用：成功后清空暂存、刷新数值（派生属性这时才变）、发 points_spent。
func _on_confirm_pressed() -> void:
	var character := current_character()
	if character == null or _pending_total() == 0:
		return
	var why := GameRoot.apply_attr_deltas(character, _pending)
	if not why.is_empty():
		return
	_pending = [0, 0, 0, 0, 0]
	SoundManager.play_sound(SoundManager.Sound.UI)
	_refresh_attr_values()
	points_spent.emit()


## 刷新表格里的数字与按钮状态：五项基础属性（含暂存）、自由点数、派生属性、＋/－/确认 的可用性。
func _refresh_attr_values() -> void:
	var character := current_character()
	if character == null:
		return
	var points := GameRoot.attribute_points(character)
	var free_points := _free_display()
	for i in points.size():
		if i < _attr_value_labels.size() and _attr_value_labels[i] != null \
				and is_instance_valid(_attr_value_labels[i]):
			_attr_value_labels[i].text = str(points[i] + _pending[i])
		if i < _attr_plus_buttons.size() and _attr_plus_buttons[i] != null \
				and is_instance_valid(_attr_plus_buttons[i]):
			_attr_plus_buttons[i].disabled = free_points <= 0
		if i < _attr_minus_buttons.size() and _attr_minus_buttons[i] != null \
				and is_instance_valid(_attr_minus_buttons[i]):
			_attr_minus_buttons[i].disabled = _pending[i] <= 0
	if _free_label != null and is_instance_valid(_free_label):
		_free_label.text = "%d 点" % free_points
	if _confirm_button != null and is_instance_valid(_confirm_button):
		_confirm_button.disabled = _pending_total() == 0
	var derived := GameRoot.derived_stats(character)
	for key in _derived_labels:
		var label: Label = _derived_labels[key]
		if label == null or not is_instance_valid(label):
			continue
		label.text = _fmt(String(key), float(derived.get(key, 0.0)))


## 自由点数的**显示值** = 真实剩余 − 暂存总量（边点边能看到还剩多少）。
func _free_display() -> int:
	var character := current_character()
	if character == null:
		return 0
	return maxi(0, GameRoot.free_attribute_points(character) - _pending_total())


## 暂存差值总和。
func _pending_total() -> int:
	var total := 0
	for value in _pending:
		total += value
	return total


## 某一项基础属性的**显示值** = 已确认的点数 + 暂存。
func _attr_text(index: int) -> String:
	var character := current_character()
	if character == null:
		return "0"
	var points := GameRoot.attribute_points(character)
	return str(points[index] + _pending[index])


## 属性值 → 显示文本：四舍五入到整数（系数是小数，会算出 43.375 这种数）。
func _stat_text(value: float) -> String:
	return Global.format_stat(roundf(value))


# ══════════════════════════════════════════════════════════
#  窗口位置与尺寸（左下角，和背包同宽）
# ══════════════════════════════════════════════════════════

## 把面板摆到屏幕**左下角**（背包在右下角，两个窗口并排不重叠）。
## 高度：取"背包高度"和"内容需要的高度"里大的那个（背包高度由 WorldMap 打开时传进来），
##   再夹进屏幕可用高度 —— 于是窗口拉大时和右边背包差不多高，内容也永远完整显示。
func _apply_geometry() -> void:
	if panel == null:
		return
	var view := get_viewport_rect().size
	var available := view.y - WINDOW_MARGIN * 2.0
	var needed := 0.0
	if content != null:
		needed = content.get_combined_minimum_size().y + WINDOW_PADDING_V * 2.0
	var height := maxf(MIN_HEIGHT, maxf(_linked_height, needed))
	height = minf(height, available)
	panel.anchor_left = 0.0
	panel.anchor_top = 1.0
	panel.anchor_right = 0.0
	panel.anchor_bottom = 1.0
	panel.grow_horizontal = Control.GROW_DIRECTION_END
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	panel.offset_left = WINDOW_MARGIN
	panel.offset_right = WINDOW_MARGIN + PANEL_WIDTH
	panel.offset_top = -(height + WINDOW_MARGIN)
	panel.offset_bottom = -WINDOW_MARGIN
	panel.anchor_left = 0.0
	panel.anchor_top = 1.0
	panel.anchor_right = 0.0
	panel.anchor_bottom = 1.0
	panel.grow_horizontal = Control.GROW_DIRECTION_END
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	panel.offset_left = WINDOW_MARGIN
	panel.offset_right = WINDOW_MARGIN + PANEL_WIDTH
	panel.offset_top = -(height + WINDOW_MARGIN)
	panel.offset_bottom = -WINDOW_MARGIN


## 清空一个容器（先 remove_child 再 queue_free，避免"正在发信号的控件被立刻摘掉"）。
func _clear(container: Container) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()
