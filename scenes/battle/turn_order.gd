#  turn_order.gd —— 出手顺序条：显示本回合谁先出手的一排头像，纯显示、不发信号。
#  上游只有 Battle：_next_round/_on_unit_died → update_order，_begin_turn → set_current，_finish_battle → clear_current。
#  数据不缓存，重建时现场读 BattleUnit；单位少（≤10）直接全量重建，别提前做对象池。
#  坑：_queue 故意用弱类型 Array（能接 Array[BattleUnit]），元素访问要 is_instance_valid 兜底；
#      动态节点 owner 为 null，只能自己 queue_free。
extends Panel
class_name TurnOrder

## 出手顺序条：按 Battle 给的队列显示图标，当前出手者加亮放大。

# ── 视觉常量（全局唯一 UI，配色统一比可配重要）──

## 我方边框色。
const PLAYER_BORDER := Color(0.35, 0.85, 0.45)
## 敌方边框色。
const ENEMY_BORDER := Color(0.95, 0.42, 0.42)
## 当前出手者边框色（同时更粗、图标更大）。
const CURRENT_BORDER := Color(1.0, 0.85, 0.3)
## 阵亡单位整体透明度（panel.modulate.a）。
const DEAD_ALPHA := 0.3

# ── 节点引用与运行时状态 ──

## 头像容器（%Icons），由 _rebuild() 动态增删子节点。
@onready var icons: HBoxContainer = %Icons

## 单位队列（引用，不是拷贝）。弱类型 Array 才能直接接收 Array[BattleUnit]，代价是无静态类型检查。
var _queue: Array = []
## 当前出手者（只用于高亮，不参与逻辑判断）。
var _current: BattleUnit


## 更新整条顺序（每回合和有人阵亡时由 Battle 调）。units 已按速度排好，本组件不排序。
## 副作用：_queue 换成传入数组的引用，并全量重建 %Icons。
func update_order(units: Array) -> void:
	_queue = units
	_rebuild()


## 标记当前出手者并重建高亮。全量重建是因为图标变大 / 边框变粗会让 HBox 重排。
## 比较高亮用引用相等（unit == _current），传“内容相同的新对象”匹配不上。
func set_current(unit: BattleUnit) -> void:
	_current = unit
	_rebuild()


## 取消高亮（战斗结束）；_current 置 null 并重建。
func clear_current() -> void:
	_current = null
	_rebuild()


## 重建：清空 %Icons → 为每个有效单位生成图标。
## 先 remove_child 再 queue_free：否则本帧内新旧图标并存，HBox 会把它们都算进布局（闪一下 / 变长）。
## _queue 是弱类型 Array，可能残留已释放的单位，访问属性前必须 is_instance_valid。
func _rebuild() -> void:
	# 先 remove_child 再 queue_free：否则本帧结束前容器里会同时存在新旧图标
	for child in icons.get_children():
		icons.remove_child(child)
		child.queue_free()

	for unit in _queue:
		if not is_instance_valid(unit):
			continue
		# `unit == _current` 是引用比较，判断"这个是不是当前出手的人"。
		icons.add_child(_make_icon(unit, unit == _current))


## 生成一个单位图标（Panel + 铺满的贴图）。is_current 决定 64/52 尺寸、3/2 边框与金黄描边。
## 所有 mouse_filter 都设 IGNORE：顺序条盖在战场上，STOP 会挡住下面单位的点击区域（父子层都要设）。
## StyleBox 每次 new（共享 Resource 就地改色会污染他人）；贴图在 add_child 后设锚点，stats 为 null 要兜底。
func _make_icon(unit: BattleUnit, is_current: bool) -> Control:
	# 当前出手者更大：52 → 64（约 +23%），够明显又不会把顺序条挤变形。
	var icon_size := 64.0 if is_current else 52.0

	var panel := Panel.new()
	panel.custom_minimum_size = Vector2(icon_size, icon_size)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.10, 0.12, 0.92)
	style.set_corner_radius_all(10)
	style.set_border_width_all(3 if is_current else 2)
	# 颜色优先级：当前出手者 > 阵营。注意这里读的是 unit.is_player（BattleUnit 的运行时属性），
	# 而不是 unit.stats 里的东西 —— 同一个 .tres 可以被配成敌方，阵营只看实例上的标记。
	style.border_color = CURRENT_BORDER if is_current else (PLAYER_BORDER if unit.is_player else ENEMY_BORDER)
	panel.add_theme_stylebox_override("panel", style)

	var tex := TextureRect.new()
	# stats 可能没配（null），这里兜底成空贴图而不是报错。
	tex.texture = unit.stats.icon if unit.stats != null else null
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(tex)
	# 入树后再设锚点预设：让贴图铺满 Panel。放在 add_child 之后是更稳的写法
	# （锚点预设会参考父节点的 rect，父节点未定之前应用可能得到意外结果）。
	tex.set_anchors_preset(Control.PRESET_FULL_RECT)

	# 阵亡置灰：只调 alpha，保留边框颜色信息（还能看出他是哪一方的）。
	if not unit.alive:
		panel.modulate.a = DEAD_ALPHA

	return panel
