# battle_stats_panel.gd —— 伤害统计面板：战斗里贴在右上角出手顺序条下面，地图上是同一块面板。
# 纯显示：数据全在 Global（battle_stats_roster / battle_stats_last / battle_stats_total），
# 本脚本不记任何账，只监听 Global.battle_stats_changed 刷新自己。
# 为什么要拆成"Global 存数据 + 面板只显示"：面板是场景的一部分，打完仗跟着场景一起销毁，
# 而「总计」要跨战斗、「上场战斗」回到地图上还要能看 —— 数据必须活过场景切换。
#
# ── 两个维度 ──
#   顶部页签：总计（所有战斗累计）/ 上场战斗（战斗中 = 正在打的这场；在地图上 = 刚打完的那场）
#   左侧页签：伤害（自己造成的）/ 治疗（自己治疗别人的）/ 承伤（自己吃到的）
#
# ── 键为什么是角色显示名 ──
#   战斗里跑的是 GameRoot._make_player_team() duplicate() 出来的副本，resource_path 为空，
#   只有 UnitStats.name 能跨战斗对上（和 Global 用名字当键的选人表是同一个理由）。
#
# ── 坑 ──
#   · 行控件是**一次建好、原地改值 + move_child 重排**，不是每次刷新重建：
#     一次群体技能会触发十几次统计变化，重建节点会白白闪。
#   · 名册（Global.battle_stats_roster）变了才重建行（开新战斗 / 换阵），否则只改数值。
extends Panel
class_name BattleStatsPanel

## 顶部页签：总计（跨场累计）/ 上场战斗（战斗中是本场，地图上是上一场）。
enum TopTab { TOTAL, BATTLE }
## 左侧页签：伤害 / 治疗 / 承伤。
enum SideTab { DAMAGE, HEALING, TAKEN }

# ── 尺寸常量（面板宽度由 .tscn 的左右 offset 定死，这里只管内部排布和纵向高度）──

## 面板上下内边距（和 .tscn 里 VBox 的 offset_top / offset_bottom 一致，算高度要加回来）。
const PAD_V := 9.0
## 纵向容器之间的标准间距（和 .tscn 里各 VBox/HBox 的 separation 一致）。
const V_SEP := 6
## 左侧页签：宽 / 高。
const SIDE_TAB_W := 72.0
const SIDE_TAB_H := 32.0
## 一行数据的高度。
const ROW_H := 30.0
## 名字列 / 数值列的固定宽度（够放 3 个汉字 / 5 位数字；上万会压成「1.2万」，不会溢出）。
const NAME_W := 84.0
## 右侧「数值（占比）」整块的宽度：固定住，所有行的条形右端才能对齐。
## 够放 "9999（100%）" 这种最长组合。
const NUMBERS_W := 146.0

# ── 配色（伤害红、治疗绿、承伤蓝）──

## 伤害（造成）：偏橙红，和飘字的普通伤害同色系。
const DAMAGE_COLOR := Color(0.98, 0.46, 0.35)
## 治疗：绿色，和回血飘字同色系。
const HEALING_COLOR := Color(0.42, 0.92, 0.56)
## 承伤：冷蓝，和上面两个明显区分。
const TAKEN_COLOR := Color(0.48, 0.70, 1.0)
## 角色名：米白。
const NAME_COLOR := Color(0.92, 0.90, 0.84)
## 非第一名、非零值的数值：浅灰。
const VALUE_COLOR := Color(0.76, 0.78, 0.84)
## 第一名的数值：金色（和回合数、施法技能名同色系），一眼能看出谁最高。
const TOP_COLOR := Color(1.0, 0.92, 0.60)
## 条形槽（背景）。
const TRACK_COLOR := Color(1.0, 1.0, 1.0, 0.07)
## "合计"、"暂无统计"这类辅助文字。
const DIM_COLOR := Color(0.62, 0.64, 0.70)

# ── 分段条：不同来源用不同颜色 ──
# 普攻 / 持续伤害 / 其他 用固定语义色（和飘字、明细对得上），技能与承伤来源从调色板里按名字取，
# 同一个名字永远是同一个颜色（跨刷新、跨面板稳定）。

## 普通攻击：骨白，最"朴素"的一段。
const SEG_ATTACK_COLOR := Color(0.86, 0.82, 0.72)
## 持续伤害：紫色，和 dot 飘字同色。
const SEG_DOT_COLOR := Color(0.74, 0.48, 0.96)
## 持续回血：青绿（刻意和技能的草绿拉开，治疗页里"技能治疗 / 持续回血"两段才分得出）。
const SEG_HOT_COLOR := Color(0.30, 0.86, 0.80)
## 来源不明：灰。
const SEG_OTHER_COLOR := Color(0.55, 0.57, 0.62)
## 技能 / 承伤来源的调色板：挑的都是暗底上清楚、彼此区分度高的颜色。
const SEG_PALETTE := [
	Color(0.98, 0.52, 0.30),   # 橙
	Color(0.38, 0.72, 0.98),   # 天蓝
	Color(0.56, 0.88, 0.46),   # 草绿
	Color(0.96, 0.44, 0.62),   # 玫红
	Color(0.66, 0.62, 1.00),   # 蓝紫
	Color(0.98, 0.80, 0.34),   # 金黄
	Color(0.36, 0.86, 0.80),   # 青绿
	Color(0.90, 0.68, 0.46),   # 土黄
	Color(0.82, 0.54, 0.92),   # 紫罗兰
	Color(0.62, 0.82, 0.42),   # 橄榄绿
]

# ── 悬停明细（伤害构成）──

## 明细面板宽度（贴在主面板左边，主面板 510 宽、明细 340 宽，中间留 12px）。
const DETAIL_WIDTH := 340.0
## 明细面板上下内边距（和 .tscn 里 Detail/Margin 的 margin_top/bottom 一致，算高度要加回来）。
const DETAIL_PAD_V := 10.0
## 一级大类的固定显示顺序。和 Global.SOURCE_* 的值一致（那边是常量、这里要当数组用）。
## 治疗页用不到 attack/dot，伤害页用不到 hot，空的分组直接跳过。
const KIND_ORDER := ["attack", "skill", "dot", "hot", "other"]

@onready var top_tabs: HBoxContainer = %TopTabs
@onready var side_tabs: VBoxContainer = %SideTabs
@onready var divider: ColorRect = %Divider
## 表头 + 数据行都动态挂在这里（表头恒为第 0 个孩子）。
@onready var list: VBoxContainer = %List
@onready var total_tab: Button = %TotalTab
@onready var battle_tab: Button = %BattleTab
@onready var damage_tab: Button = %DamageTab
@onready var heal_tab: Button = %HealTab
@onready var taken_tab: Button = %TakenTab
## 悬停明细的浮层（平时隐藏，鼠标停在某一行上才出现）。
@onready var detail: Panel = %Detail
@onready var detail_body: VBoxContainer = %DetailBody

## 当前顶部页 / 左侧页。
var _top := TopTab.TOTAL
var _side := SideTab.DAMAGE
## 榜单角色名（Global.battle_stats_roster 的副本，按上场顺序）。
var _names: Array[String] = []
## 姓名 → 行控件 {"root": HBoxContainer, "value": Label, "percent": Label, "bar": Control, "segs": Array}。
var _rows: Dictionary = {}
## 表头右侧的「合计」数值（空状态时为 null）。
var _summary: Label = null
## 鼠标当前停在哪一行的角色名（"" = 没停在任何行上）。
var _hovered := ""


## 生命周期：两组页签各建一个 ButtonGroup（互斥），挂到 Global 的统计变化信号上，再画一次。
func _ready() -> void:
	var top_group := ButtonGroup.new()
	total_tab.button_group = top_group
	battle_tab.button_group = top_group
	total_tab.pressed.connect(_set_top.bind(TopTab.TOTAL))
	battle_tab.pressed.connect(_set_top.bind(TopTab.BATTLE))

	var side_group := ButtonGroup.new()
	for button in [damage_tab, heal_tab, taken_tab]:
		button.button_group = side_group
	damage_tab.pressed.connect(_set_side.bind(SideTab.DAMAGE))
	heal_tab.pressed.connect(_set_side.bind(SideTab.HEALING))
	taken_tab.pressed.connect(_set_side.bind(SideTab.TAKEN))

	# 数据变了（开新战斗 / 每一笔伤害治疗）就刷新；面板换了场景会自己断开，不用手动解绑。
	Global.battle_stats_changed.connect(_on_stats_changed)
	_sync_roster()
	_refresh()


## Global 报账了：名册可能有变（开新战斗），先对齐行控件，再刷新数值。
func _on_stats_changed() -> void:
	_sync_roster()
	_refresh()


## 每帧检查鼠标停在哪一行上（行控件是 MOUSE_FILTER_IGNORE，收不到 mouse_entered，
## 所以只能自己比对鼠标位置；面板最多 5 行，开销可以忽略）。
func _process(_delta: float) -> void:
	_update_hover()


## 鼠标换行（或离开）时开关明细浮层。
## 参数 mouse：全局坐标；不传就取真实鼠标位置（测试时可以塞一个坐标进来）。
func _update_hover(mouse := Vector2.INF) -> void:
	if detail == null:
		return
	if not is_visible_in_tree():
		if detail.visible:
			detail.hide()
		_hovered = ""
		return
	if mouse == Vector2.INF:
		mouse = get_global_mouse_position()
	var found := ""
	for who in _rows:
		var root: Control = _rows[who]["root"]
		if root.get_global_rect().has_point(mouse):
			found = String(who)
			break
	if found == _hovered:
		return
	_hovered = found
	if found.is_empty():
		detail.hide()
	else:
		_show_detail(found)


## 参战名册变了才重建行控件（内容相同就不动，避免一笔伤害就重建一遍 UI）。
## "还没建过"也要建一次：开新档/第一次进图时名册是空的，得先把「暂无统计」画出来并把高度收好。
func _sync_roster() -> void:
	if _names == Global.battle_stats_roster and list.get_child_count() > 0:
		return
	_names.clear()
	_names.append_array(Global.battle_stats_roster)
	_rebuild_rows()


# ── 数据 ──

## 当前左侧页对应的统计字段名。
func _field() -> String:
	match _side:
		SideTab.HEALING:
			return Global.STAT_HEALING
		SideTab.TAKEN:
			return Global.STAT_TAKEN
		_:
			return Global.STAT_DAMAGE


## 当前左侧页的主色（条形、合计数字、第一名数值都用它）。
func _side_color() -> Color:
	match _side:
		SideTab.HEALING:
			return HEALING_COLOR
		SideTab.TAKEN:
			return TAKEN_COLOR
		_:
			return DAMAGE_COLOR


# ── 页签 ──

## 切顶部页（总计 / 上场战斗）。只换数据源，不重建行控件。
func _set_top(tab: TopTab) -> void:
	if _top == tab:
		return
	_top = tab
	total_tab.button_pressed = tab == TopTab.TOTAL
	battle_tab.button_pressed = tab == TopTab.BATTLE
	SoundManager.play_sound(SoundManager.Sound.UI)
	_refresh()


## 切左侧页（伤害 / 治疗 / 承伤）。只换字段和配色。
func _set_side(tab: SideTab) -> void:
	if _side == tab:
		return
	_side = tab
	damage_tab.button_pressed = tab == SideTab.DAMAGE
	heal_tab.button_pressed = tab == SideTab.HEALING
	taken_tab.button_pressed = tab == SideTab.TAKEN
	SoundManager.play_sound(SoundManager.Sound.UI)
	_refresh()


# ── 界面 ──

## 清空 List 并重建：表头（合计）+ 每个参战角色一行；没人参战时只有一行"暂无统计"。
## 行控件建好后调一次 _fit_height()，把面板高度收成内容高度（人少时不留一大块空白）。
func _rebuild_rows() -> void:
	for child in list.get_children():
		list.remove_child(child)
		child.queue_free()
	_rows.clear()
	_summary = null

	if _names.is_empty():
		var empty := Label.new()
		empty.text = "暂无统计"
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.add_theme_font_size_override("font_size", 17)
		empty.add_theme_color_override("font_color", DIM_COLOR)
		list.add_child(empty)
		_fit_height.call_deferred()
		return

	# 表头：左"合计"，右总数值（跟着左侧页签变）。
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var caption := Label.new()
	caption.text = "合计"
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	caption.add_theme_font_size_override("font_size", 16)
	caption.add_theme_color_override("font_color", DIM_COLOR)
	header.add_child(caption)
	_summary = Label.new()
	_summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_summary.custom_minimum_size = Vector2(NUMBERS_W, 0)
	_summary.add_theme_font_size_override("font_size", 16)
	_summary.add_theme_color_override("font_color", DIM_COLOR)
	header.add_child(_summary)
	list.add_child(header)

	for who in _names:
		list.add_child(_make_row(who))

	_fit_height.call_deferred()


## 造一行：[名字] [分段比例条] [数值（占比）]。
## 比例条由**多个来源色块拼成**（每段宽度 = 该来源数值 / 全队最高值），用锚点定位，
## 所以不必关心实际像素宽度；数值和括号里的占比是一整块、贴右对齐。
func _make_row(who: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, ROW_H)
	row.add_theme_constant_override("separation", 6)
	# 整块面板只有页签按钮吃鼠标，其余全部穿透（地图上盖住 NPC 也照样点得到）。
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var name_label := Label.new()
	name_label.text = who
	name_label.custom_minimum_size = Vector2(NAME_W, 0)
	name_label.clip_text = true                       # 名字过长时裁掉，别把行撑变形
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 18)
	name_label.add_theme_color_override("font_color", NAME_COLOR)
	row.add_child(name_label)

	# 条形区：底槽 + 若干来源色块（色块由 _sync_segments() 按需补/隐藏）。
	var bar := Control.new()
	bar.name = "Bar"
	bar.custom_minimum_size = Vector2(0, 14)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(bar)

	var track := ColorRect.new()
	track.color = TRACK_COLOR
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(track)
	# 入树之后再设锚点：父节点 rect 没定之前 PRESET_FULL_RECT 可能算出意外结果。
	track.set_anchors_preset(Control.PRESET_FULL_RECT)

	# 数值 + 占比（"1340（53%）"）：两块贴着放、整体右对齐，宽度固定让所有行的条右端对齐。
	var numbers := HBoxContainer.new()
	numbers.custom_minimum_size = Vector2(NUMBERS_W, 0)
	numbers.size_flags_horizontal = Control.SIZE_SHRINK_END
	numbers.alignment = BoxContainer.ALIGNMENT_END
	numbers.add_theme_constant_override("separation", 0)
	numbers.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(numbers)

	var value_label := Label.new()
	value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	value_label.add_theme_font_size_override("font_size", 18)
	value_label.add_theme_color_override("font_color", VALUE_COLOR)
	numbers.add_child(value_label)

	var percent_label := Label.new()
	percent_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	percent_label.add_theme_font_size_override("font_size", 15)
	percent_label.add_theme_color_override("font_color", DIM_COLOR)
	numbers.add_child(percent_label)

	_rows[who] = {"root": row, "value": value_label, "percent": percent_label,
			"bar": bar, "segs": []}
	return row


## 按当前的顶部/左侧页刷新数值、条形长度、名次颜色，并把行按名次重排。
## 数据从 Global.battle_stats_last（上场战斗）或 Global.battle_stats_total（总计）现取；
## 同数值按上场顺序排（不来回跳）。
func _refresh() -> void:
	if _summary == null or _rows.is_empty():
		# 没有榜单时明细也没意义，顺手收掉（否则换阵容后会留一块浮层）。
		if detail != null and detail.visible:
			detail.hide()
		_hovered = ""
		return
	var field := _field()
	var source: Dictionary = Global.battle_stats_last \
			if _top == TopTab.BATTLE else Global.battle_stats_total

	var entries: Array[Dictionary] = []
	var sum := 0.0
	var best := 0.0
	for i in _names.size():
		var who: String = _names[i]
		var entry: Dictionary = source.get(who, {})
		var value := float(entry.get(field, 0.0))
		entries.append({"name": who, "value": value, "order": i, "record": entry})
		sum += value
		best = maxf(best, value)

	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if not is_equal_approx(float(a["value"]), float(b["value"])):
			return float(a["value"]) > float(b["value"])
		return int(a["order"]) < int(b["order"]))

	var color := _side_color()
	_summary.text = _format_amount(sum)
	_summary.add_theme_color_override("font_color", color)

	for i in entries.size():
		var who: String = String(entries[i]["name"])
		var value := float(entries[i]["value"])
		var row: Dictionary = _rows.get(who, {})
		if row.is_empty():
			continue
		# 重排名次：0 是表头，所以从 1 开始。
		list.move_child(row["root"], i + 1)
		var value_label: Label = row["value"]
		value_label.text = _format_amount(value)
		var is_top := best > 0.0 and is_equal_approx(value, best)
		value_label.add_theme_color_override("font_color", TOP_COLOR if is_top else VALUE_COLOR)
		# 占比：分母是全队合计（就是表头那个数），四舍五入到整数，跟在数值后面。
		var percent_label: Label = row["percent"]
		percent_label.text = "（%d%%）" % int(roundf(value / sum * 100.0)) if sum > 0.0 else "（0%）"
		# 条形：按来源拆成多段色块拼起来（各段宽度相对"全队最高值"，第一名正好占满）。
		_sync_segments(row, _row_parts(entries[i]["record"], field), best)

	# 正停在某一行上时，数字变了要把明细一起刷新（伤害是逐笔跳的）。
	if not _hovered.is_empty() and detail != null and detail.visible:
		if _rows.has(_hovered):
			_show_detail(_hovered)
		else:
			detail.hide()
			_hovered = ""


# ── 悬停明细：伤害 / 治疗 / 承伤的构成 ──


## 某个角色在当前页签下的来源列表（给分段条用）：[{label, value, color}]，按数值从大到小。
## 和悬停明细用同一套来源/名字，保证"条上看到的颜色"和"明细里看到的名字"一一对应。
func _row_parts(record: Dictionary, field: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if field == Global.STAT_TAKEN:
		var taken: Dictionary = record.get(Global.PARTS_TAKEN, {})
		for attacker in taken:
			out.append({"label": String(attacker), "value": float(taken[attacker]),
					"color": _source_color("", String(attacker))})
	else:
		var parts_key := Global.PARTS_HEALING if field == Global.STAT_HEALING else Global.PARTS_DAMAGE
		var parts: Dictionary = record.get(parts_key, {})
		for kind in KIND_ORDER:
			var group: Dictionary = parts.get(kind, {})
			for label in group:
				out.append({"label": _source_name(kind, String(label)),
						"value": float(group[label]),
						"color": _source_color(kind, String(label))})
	out.sort_custom(func(a, b) -> bool: return float(a["value"]) > float(b["value"]))
	return out


## 来源 → 色块颜色。普攻/持续伤害/其他是固定语义色，其余按名字从调色板里取（同名同色）。
func _source_color(kind: String, label: String) -> Color:
	match kind:
		Global.SOURCE_ATTACK:
			return SEG_ATTACK_COLOR
		Global.SOURCE_DOT:
			return SEG_DOT_COLOR
		Global.SOURCE_HOT:
			return SEG_HOT_COLOR
		Global.SOURCE_OTHER:
			return SEG_OTHER_COLOR
		_:
			return SEG_PALETTE[absi(label.hash()) % SEG_PALETTE.size()]


## 把一行条形按来源重新拼一遍：段数不够就补，多了就隐藏（不反复 new / free，免得每笔伤害都重建节点）。
## 每段用锚点定宽度：anchor_left/right = 累计占比（分母是 best = 全队最高值，第一名正好占满）。
func _sync_segments(row: Dictionary, parts: Array[Dictionary], best: float) -> void:
	var bar: Control = row["bar"]
	var segs: Array = row["segs"]
	while segs.size() < parts.size():
		var seg := ColorRect.new()
		seg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		seg.anchor_top = 0.0
		seg.anchor_bottom = 1.0
		seg.offset_top = 0.0
		seg.offset_bottom = 0.0
		bar.add_child(seg)
		segs.append(seg)
	var cursor := 0.0
	for i in segs.size():
		var seg: ColorRect = segs[i]
		if i >= parts.size() or best <= 0.0:
			seg.visible = false
			continue
		var width := float(parts[i]["value"]) / best
		seg.visible = true
		seg.color = parts[i]["color"]
		seg.anchor_left = cursor
		seg.anchor_right = cursor + width
		seg.offset_left = 0.0
		seg.offset_right = 0.0
		cursor += width


## 显示某个角色的构成明细：贴在主面板左边、纵向对齐被悬停的那一行。
## 数据同样来自 Global（按当前顶部页取"上场战斗"或"总计"）。
func _show_detail(who: String) -> void:
	if detail == null or not _rows.has(who):
		return
	_rebuild_detail(who)
	var row: Control = _rows[who]["root"]
	var screen_h := get_viewport_rect().size.y
	var h := detail.size.y
	# 纵向居中对齐到那一行，再夹在屏幕内（面板本身就贴着屏幕右边，所以 x 不用夹）。
	var center_y := row.get_global_rect().get_center().y
	var top := clampf(center_y - h * 0.5, 8.0, maxf(8.0, screen_h - h - 8.0))
	detail.position = Vector2(-DETAIL_WIDTH - 12.0, top - global_position.y)
	detail.show()


## 重建明细内容：标题 → 分隔线 → 各来源（一行一个）→ 分隔线 → 合计。
## 拉平显示：没有大类/缩进，所有来源按数值从大到小排成一列，右侧是数值和占比。
func _rebuild_detail(who: String) -> void:
	for child in detail_body.get_children():
		detail_body.remove_child(child)
		child.queue_free()

	var field := _field()
	var source: Dictionary = Global.battle_stats_last \
			if _top == TopTab.BATTLE else Global.battle_stats_total
	var row: Dictionary = source.get(who, {})
	var total := float(row.get(field, 0.0))
	var color := _side_color()

	detail_body.add_child(_make_detail_label("%s · %s" % [who, _detail_title()], 17, NAME_COLOR))
	detail_body.add_child(_make_detail_separator())

	var entries := _composition_rows(row, field)
	if entries.is_empty():
		detail_body.add_child(_make_detail_label("暂无明细", 15, DIM_COLOR))
	for entry in entries:
		detail_body.add_child(_make_detail_row(String(entry["label"]), float(entry["value"]),
				total, color))

	detail_body.add_child(_make_detail_separator())
	detail_body.add_child(_make_detail_row("合计", total, total, NAME_COLOR, false))

	detail.size = Vector2(DETAIL_WIDTH,
			detail_body.get_combined_minimum_size().y + DETAIL_PAD_V * 2.0)


## 当前页签下的构成列表（**拉平**：一行一个来源，没有大类/缩进），按数值从大到小排。
## 返回 [{"label", "value"}]。
## 承伤：一行一个"谁打的"。
func _composition_rows(row: Dictionary, field: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if field == Global.STAT_TAKEN:
		var taken: Dictionary = row.get(Global.PARTS_TAKEN, {})
		for key in taken:
			out.append({"label": String(key), "value": float(taken[key])})
	else:
		var parts_key := Global.PARTS_HEALING if field == Global.STAT_HEALING else Global.PARTS_DAMAGE
		var parts: Dictionary = row.get(parts_key, {})
		for kind in KIND_ORDER:
			var group: Dictionary = parts.get(kind, {})
			for label in group:
				out.append({
					"label": _source_name(kind, String(label)),
					"value": float(group[label]),
				})
	out.sort_custom(func(a, b) -> bool: return float(a["value"]) > float(b["value"]))
	return out


## 一行来源的显示名：
##   普通攻击 / 其他 —— 名字本身就是来源，直接用；
##   技能          —— 用技能名（技能名一看就知道是技能）；
##   持续伤害 / 持续回血 —— 在技能名后标一下，因为它们和同一个技能的直伤同名
##                    （例："药雾弥漫（持续伤害）" 和 "药雾弥漫" 是两行）。
func _source_name(kind: String, label: String) -> String:
	match kind:
		Global.SOURCE_DOT:
			return "%s（持续伤害）" % (label if not label.is_empty() else "持续伤害")
		Global.SOURCE_HOT:
			return "%s（持续回血）" % (label if not label.is_empty() else "持续回血")
		Global.SOURCE_SKILL:
			return label if not label.is_empty() else _kind_name(kind)
		_:
			return _kind_name(kind)


## 来源大类 → 中文名（拉平显示后只用于"普通攻击 / 其他"这种没有具体名字的行）。
func _kind_name(kind: String) -> String:
	match kind:
		Global.SOURCE_ATTACK:
			return "普通攻击"
		Global.SOURCE_SKILL:
			return "技能"
		Global.SOURCE_DOT:
			return "持续伤害"
		Global.SOURCE_HOT:
			return "持续回血"
		_:
			return "其他"


## 明细标题（带当前页签的范围，免得浮层飘远了看不出是总计还是本场）。
func _detail_title() -> String:
	var scope := "上场战斗" if _top == TopTab.BATTLE else "总计"
	match _side:
		SideTab.HEALING:
			return "治疗构成（%s）" % scope
		SideTab.TAKEN:
			return "承伤来源（%s）" % scope
		_:
			return "伤害构成（%s）" % scope


## 明细的一行：[名字] [数值] [占比]。所有行同一套样式（拉平，不做缩进/分级）。
## 参数 color：数值颜色（各项来源用页签主色，"合计"那行传亮色）。
## show_percent = false 时右侧不留占比（"合计"那一行用）。
func _make_detail_row(label: String, value: float, total: float, color: Color,
		show_percent := true) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 6)

	var name_label := Label.new()
	name_label.text = label
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.clip_text = true
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_label.add_theme_font_size_override("font_size", 16)
	name_label.add_theme_color_override("font_color", NAME_COLOR)
	row.add_child(name_label)

	var value_label := Label.new()
	value_label.text = _format_amount(value)
	value_label.custom_minimum_size = Vector2(70, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	value_label.add_theme_font_size_override("font_size", 16)
	value_label.add_theme_color_override("font_color", color)
	row.add_child(value_label)

	if show_percent:
		var percent := Label.new()
		percent.text = "%d%%" % int(roundf(value / total * 100.0)) if total > 0.0 else ""
		percent.custom_minimum_size = Vector2(44, 0)
		percent.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		percent.mouse_filter = Control.MOUSE_FILTER_IGNORE
		percent.add_theme_font_size_override("font_size", 14)
		percent.add_theme_color_override("font_color", DIM_COLOR)
		row.add_child(percent)
	return row


## 明细里的一行文字（标题 / "暂无明细"）。
func _make_detail_label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


## 明细里的分隔线（和主面板的分隔线同色）。
func _make_detail_separator() -> ColorRect:
	var line := ColorRect.new()
	line.custom_minimum_size = Vector2(0, 1)
	line.color = Color(1, 0.85, 0.5, 0.18)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line


## 把面板高度收成"刚好装下内容"：高度跟着行数走（1 人队和 5 人队都不会留一块空白）。
## 用容器的 get_combined_minimum_size() 而不是自己乘常量：字体行高比 ROW_H 高时不会把内容挤出去。
func _fit_height() -> void:
	if list == null or top_tabs == null:
		return
	var body := maxf(list.get_combined_minimum_size().y, side_tabs.get_combined_minimum_size().y)
	var content := top_tabs.get_combined_minimum_size().y + V_SEP \
			+ maxf(divider.get_combined_minimum_size().y, 1.0) + V_SEP + body
	offset_bottom = offset_top + PAD_V * 2.0 + content


## 数值显示：一律整数（伤害是 float，直接 str 会出现 12.000000）；
## 上万后压成「1.2万」，否则长数字会把数值列挤爆。
func _format_amount(value: float) -> String:
	var n := int(roundf(value))
	if n < 10000:
		return str(n)
	return "%.1f万" % (float(n) / 10000.0)
