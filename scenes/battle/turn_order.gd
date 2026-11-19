#  turn_order.gd —— 出手顺序条：显示本回合谁先出手的一排头像，纯显示、不发信号。
#  上游只有 Battle：_next_round/_on_unit_died → update_order，_begin_turn → set_current，_finish_battle → clear_current。
#  数据不缓存，重建时现场读 BattleUnit；单位少（≤10）直接全量重建，别提前做对象池。
#  坑：_queue 故意用弱类型 Array（能接 Array[BattleUnit]），元素访问要 is_instance_valid 兜底；
#      动态节点 owner 为 null，只能自己 queue_free。
extends Panel
class_name TurnOrder

const Paper := preload("res://styles/paper_ui.gd")

## 出手顺序条：按 Battle 给的队列显示图标，当前出手者加亮放大。

# ── 视觉常量（全局唯一 UI，配色统一比可配重要）──

## 我方边框色。
const PLAYER_BORDER := Color("#477756")
## 敌方边框色。
const ENEMY_BORDER := Color("#a34f45")
## 「下一个出手」箭头色。
const NEXT_ARROW := Paper.VERMILION
## 阵亡单位整体透明度（panel.modulate.a）。阵亡的已从队列剔除，这里只是兜底。
const DEAD_ALPHA := 0.3
## 「本轮 / 下一轮」分隔线的颜色：暗金，和回合数那排字同色系但更淡（不抢头像）。
const DIVIDER_COLOR := Paper.SOFT_INK

# ── 节点引用与运行时状态 ──

## 头像容器（%Icons），由 _rebuild() 动态增删子节点。
@onready var icons: HBoxContainer = %Icons
@onready var content: VBoxContainer = $VBox
## 顶部常驻的回合数字（"第 N 回合"里的 N，红色）。
@onready var round_number: Label = %RoundNumber

## 面板左右内缩（VBox 的左右 offset 之和）—— 算自适应宽度时要加回来。
const H_PADDING := 34.0

## 单位队列（引用，不是拷贝）。弱类型 Array 才能直接接收 Array[BattleUnit]，代价是无静态类型检查。
var _queue: Array = []
## 当前出手者（只用于高亮，不参与逻辑判断）。
var _current: BattleUnit
## 下一轮第一个出手的人（只用于在条上插"本轮 / 下一轮"分隔）。
## null = 不分隔（比如队列刚排好、所有人都还没出手，整条都是本轮）。
var _next_round_first: BattleUnit


func _ready() -> void:
	Paper.UiSkin.changed().connect(_rebuild)
	Paper.bind(round_number, func():
		var ink := Paper.tone(Paper.VERMILION) if Paper.UiSkin.is_ink() else Color(0.54, 0.27, 0.20)
		round_number.add_theme_color_override("font_color", ink))


## 更新整条顺序（每回合和有人阵亡时由 Battle 调）。units 已按速度排好，本组件不排序。
## 副作用：_queue 换成传入数组的引用，并全量重建 %Icons；分隔一并清掉（整条都是本轮）。
func update_order(units: Array) -> void:
	_queue = units
	_next_round_first = null
	_rebuild()


## 标记当前出手者并重建高亮。全量重建是因为图标变大 / 边框变粗会让 HBox 重排。
## 比较高亮用引用相等（unit == _current），传“内容相同的新对象”匹配不上。
func set_current(unit: BattleUnit) -> void:
	_current = unit
	_rebuild()


## 一次设好「轮转后的队列 + 当前出手者」，只重建一次（每回合每个人都会调）。
## units 必须已经是"当前出手者排最前"的顺序 —— 排序由 Battle 负责，这里不排。
## 参数 next_round_first：从哪个人开始已经是下一轮了（不给 = 整条都是本轮，不插分隔）。
func update_turn(units: Array, current: BattleUnit, next_round_first: BattleUnit = null) -> void:
	_queue = units
	_current = current
	_next_round_first = next_round_first
	_rebuild()


## 取消高亮（战斗结束）；_current 置 null 并重建。
func clear_current() -> void:
	_current = null
	_next_round_first = null
	_rebuild()


## 重建：清空 %Icons → 为每个有效单位生成图标。
## 先 remove_child 再 queue_free：否则本帧内新旧图标并存，HBox 会把它们都算进布局（闪一下 / 变长）。
## _queue 是弱类型 Array，可能残留已释放的单位，访问属性前必须 is_instance_valid。
func _rebuild() -> void:
	# 先 remove_child 再 queue_free：否则本帧结束前容器里会同时存在新旧图标
	for child in icons.get_children():
		icons.remove_child(child)
		child.queue_free()

	# 当前出手者永远排第一，其余保持队列原有次序 —— 所以第二格天然就是"下一个出手的人"。
	# （_current 已阵亡/已释放时不同前置顶，直接按原队列显示。）
	var ordered: Array = []
	if _current != null and is_instance_valid(_current) and _queue.has(_current):
		ordered.append(_current)
	for unit in _queue:
		if not is_instance_valid(unit):
			continue
		if unit == _current:
			continue
		ordered.append(unit)

	for i in ordered.size():
		# 第一格和第二格之间插一个右向箭头，表示"他出完手 → 轮到下一个"。
		if i == 1:
			icons.add_child(_make_arrow())
		# 从这个人开始已经是下一轮：在它前面插一条「下轮」分隔（环状顺序条不加标记看不出分界）。
		if _next_round_first != null and ordered[i] == _next_round_first:
			icons.add_child(_make_round_divider())
		# `unit == _current` 是引用比较，判断"这个是不是当前出手的人"。
		icons.add_child(_make_icon(ordered[i], ordered[i] == _current))
	# 右边贴近伤害统计，队列变长时向左展开。
	# 必须延后一帧：_make_icon 刚 add_child，容器的最小尺寸这一帧还没算完。
	_fit_width.call_deferred()


## 固定右侧间距，随头像数量调整宽度。
func _fit_width() -> void:
	if icons == null:
		return
	var w := content.get_combined_minimum_size().x + H_PADDING
	offset_left = offset_right - w


## 刷新顶部常驻的回合数（"第 N 回合"里的 N）。
## 文案拆成三段 Label 是为了给数字单独上红色；加粗用"描边和文字同色"伪造
## （富文本的 [b] 在项目这套没有粗体字重的字体上不会生效）。
func set_round(n: int) -> void:
	if round_number != null:
		round_number.text = str(n)


## 第一、二格之间的右向箭头（纯装饰，不占点击区域）。
func _make_arrow() -> Control:
	var arrow := Label.new()
	arrow.text = "▶"
	arrow.add_theme_font_size_override("font_size", 16)
	arrow.add_theme_color_override("font_color", Paper.tone(NEXT_ARROW))
	arrow.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	arrow.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return arrow


## 「本轮 / 下一轮」分隔：一条竖线 + 下面一行小字「下轮」。
## 为什么要它：顺序条是个环——当前出手者排最前，出过手的会自动转到队尾等下一轮。
## 不标一下，玩家分不清"队尾那几个人"是排在本轮后面还是下一轮开头。
func _make_round_divider() -> Control:
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	box.add_theme_constant_override("separation", 2)

	var line := ColorRect.new()
	line.custom_minimum_size = Vector2(3, 38)
	line.color = Paper.tone(DIVIDER_COLOR)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(line)

	var label := Label.new()
	label.text = "下轮"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Paper.tone(DIVIDER_COLOR))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(label)
	return box


## 生成一个单位图标（Panel + 铺满的贴图）。is_current 只影响尺寸 64/52 与边框粗细 3/2，
## **不改边框颜色**（颜色永远代表阵营）。
## 所有 mouse_filter 都设 IGNORE：顺序条盖在战场上，STOP 会挡住下面单位的点击区域（父子层都要设）。
## StyleBox 每次 new（共享 Resource 就地改色会污染他人）；贴图在 add_child 后设锚点，stats 为 null 要兜底。
func _make_icon(unit: BattleUnit, is_current: bool) -> Control:
	# 当前出手者更大：52 → 64（约 +23%），够明显又不会把顺序条挤变形。
	var icon_size := 64.0 if is_current else 52.0

	var panel := Panel.new()
	panel.custom_minimum_size = Vector2(icon_size, icon_size)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var style := StyleBoxFlat.new()
	style.bg_color = Paper.tone(Paper.PAPER if is_current else Paper.INSET)
	style.set_corner_radius_all(5)
	style.set_border_width_all(3 if is_current else 2)
	# 边框颜色只表达阵营，**当前出手者不改色**：高亮只靠"放大一点 + 边框略粗"。
	# 阵营看的是 unit.is_player（BattleUnit 的运行时属性），不是 stats 里的东西 ——
	# 同一个 .tres 可以被配成敌方，阵营只看实例上的标记。
	style.border_color = Paper.tone(PLAYER_BORDER if unit.is_player else ENEMY_BORDER)
	panel.add_theme_stylebox_override("panel", style)

	var tex := TextureRect.new()
	# stats 可能没配（null），这里兜底成空贴图而不是报错。
	# 小格子优先用方形头像；没配头像就退回 icon（全身立绘）。
	tex.texture = null
	if unit.stats != null:
		tex.texture = unit.stats.avatar if unit.stats.avatar != null else unit.stats.icon
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(tex)
	# 入树后再设锚点预设：让贴图铺满 Panel。放在 add_child 之后是更稳的写法
	# （锚点预设会参考父节点的 rect，父节点未定之前应用可能得到意外结果）。
	tex.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tex.offset_left = 3
	tex.offset_top = 3
	tex.offset_right = -3
	tex.offset_bottom = -3
	if is_current:
		var mark := Label.new()
		mark.text = "◆"
		mark.position = Vector2(4, 1)
		mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
		mark.add_theme_font_size_override("font_size", 12)
		mark.add_theme_color_override("font_color", Paper.tone(Paper.VERMILION))
		panel.add_child(mark)

	# 阵亡置灰：只调 alpha，保留边框颜色信息（还能看出他是哪一方的）。
	if not unit.alive:
		panel.modulate.a = DEAD_ALPHA

	return panel
