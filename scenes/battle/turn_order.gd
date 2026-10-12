# ═══════════════════════════════════════════════════════════════════════════════
#  turn_order.gd —— 出手顺序条（战斗 UI 的一部分）
# ═══════════════════════════════════════════════════════════════════════════════
#
# 【它在系统里的位置】
#   本脚本挂在战斗场景 UI 层里的 TurnOrder 节点上（battle.tscn 里 UI/TurnOrder 的一个 Panel
#   实例），显示"本回合谁先出手"的一排单位头像。
#     · 上游（唯一数据来源）：Battle。
#         Battle._next_round()  → update_order(排好序的存活单位)   —— 每回合重排一次
#         Battle._begin_turn()  → set_current(当前出手者)          —— 换人时刷新
#         Battle._on_unit_died()→ update_order(活人)               —— 有人死了就缩短队列
#         Battle._finish_battle()→ clear_current()                 —— 战斗结束取消高亮
#     · 下游：**没有**。本组件是纯显示，不 emit 任何信号、不点击、不管鼠标
#       （所有动态生成的 Control 都设了 MOUSE_FILTER_IGNORE，连 hover 都不产生），
#       也从不反向调用 Battle。
#
# 【数据从哪来】
#   · _queue：Battle 传进来的单位数组（**引用**，不是拷贝 —— 所以调用方之后改那个数组，
#     这里也会跟着变，但因为每次变更都会再调 update_order 重建，所以不会出现不一致）；
#   · _current：Battle 通过 set_current() 写入的"当前出手者"；
#   · 每个图标的贴图 / 阵营色 / 阵亡置灰，都是重建时现场从 BattleUnit 读的，不缓存数值。
#
# 【实现策略与扩展提示】
#   单位数量不多（当前最多 5v5 = 10 个）时，"整条清空重建"最省事也最不容易出 bug；
#   上百个单位再改成对象池（复用节点只改内容），或改成分帧增量更新。
#
# 【坑位提示】
#   · _queue 声明为弱类型 `Array` 而不是 Array[BattleUnit]：因为 Battle 传进来的是
#     Array[BattleUnit]，赋给弱类型 Array 是可以的（反过来不行）。用弱类型时元素要当
#     `unit.alive` 那样直接访问，编译期不做类型检查，所以要靠 `if not is_instance_valid(unit)` 兜底。
#   · 清理子节点必须"先 remove_child 再 queue_free"，否则本帧内新旧图标会同时挂在容器里。
#   · 动态创建的 Panel/TextureRect **没有 owner**（owner = null），所以释放只能自己 queue_free，
#     走 owner.queue_free() 会失败。
# ═══════════════════════════════════════════════════════════════════════════════
extends Panel
class_name TurnOrder

## 出手顺序条：按 Battle 给的队列显示图标，当前出手的加亮边框。
## 单位数量不多时直接重建最省事；上百个单位再改成对象池（复用节点只改内容）。

# ── 视觉常量 ──────────────────────────────────────────────────────────────────
# 边框颜色承担"阵营 + 当前行动者"两种语义，优先级：当前行动者 > 阵营。
# 这些值没有做成 @export，因为顺序条是全局唯一的 UI，配色统一比可配更重要。

## 我方边框色：绿色。用于 is_player == true 的单位图标。
const PLAYER_BORDER := Color(0.35, 0.85, 0.45)
## 敌方边框色：红色。用于 is_player == false 的单位图标。
const ENEMY_BORDER := Color(0.95, 0.42, 0.42)
## 当前出手者的边框色：金黄，且边框更粗、图标更大（见 _make_icon），三重强调。
const CURRENT_BORDER := Color(1.0, 0.85, 0.3)
## 阵亡单位的整体透明度（0.3 = 很淡）。用 panel.modulate.a 实现，不影响边框色本身。
const DEAD_ALPHA := 0.3

# ── 节点引用与运行时状态 ──────────────────────────────────────────────────────

## 头像的容器（HBoxContainer）。所有图标都是它的子节点，由 _rebuild() 动态增删。
## %Icons 走 unique_name_in_owner，改层级不会失效；@onready 在 _ready() 之前赋值。
@onready var icons: HBoxContainer = %Icons

## 要显示的单位队列（Battle 每回合传进来的"已按速度排序的存活单位"）。
## 类型写成弱类型 Array 是刻意的：能直接接收 Array[BattleUnit]（带类型的数组不能隐式转成
## 另一种带类型的数组，但可以赋给弱类型 Array）。代价是元素访问没有静态类型检查。
var _queue: Array = []
## 当前出手的单位（Battle._begin_turn 里 set_current 写入；结束时 clear_current 清空）。
## 它是 _queue 里某个元素的引用，这里只用来判"哪个图标要高亮"，不参与任何逻辑判断。
var _current: BattleUnit


## 更新整条顺序（Battle._next_round 每回合调一次，_on_unit_died 里也会调）。
## 参数 units：要显示的单位列表，通常已经按出手速度排好序（本组件**不排序**，原样显示）。
## 返回值：无。
## 副作用：
##   · _queue 被**替换成传入的数组引用**（不是拷贝 —— 调用方之后原地改那个数组，这里也会看到，
##     但因为调用方每次变更都会重新调本函数，所以不会出现显示与逻辑不一致）；
##   · 触发 _rebuild()：销毁并重建 %Icons 下所有子节点。
## 注意：传进来的通常是"存活单位"（Battle 用 _alive() 过滤过），所以阵亡单位的 DEAD_ALPHA 分支
##   一般不会走到；_make_icon 里保留它是为了防御"传进来时还活着、重建前这一刻死了"的边界情况，
##   以及将来改成"显示完整队列（死人置灰）"时的兼容。
func update_order(units: Array) -> void:
	_queue = units
	_rebuild()


## 标记"当前出手者"并刷新高亮（Battle._begin_turn 里调）。
## 参数 unit：当前出手的单位（必须是 _queue 里的元素，否则等于没有图标会被高亮）。
## 返回值：无。
## 副作用：写 _current 并触发一次完整重建。
## 实现说明：这里用**全量重建**而不是"只改两个图标的边框" —— 因为当前行动者的图标会变大（52→64）
##   且边框变粗，会导致 HBoxContainer 整体重新排版，全量重建反而更简单可靠。
## 副作用代价：每次换人都会销毁/新建 8 个左右的 Control，单位数量级很小，可以接受。
## 比较方式：_rebuild 里用 `unit == _current`（引用相等），所以必须传同一个对象实例，
##   传一个"内容相同的新对象"是匹配不上的。
func set_current(unit: BattleUnit) -> void:
	_current = unit
	_rebuild()


## 取消"当前出手者"高亮（Battle._finish_battle 里调，战斗结束后顺序条不该再指着谁）。
## 参数/返回值：无。
## 副作用：_current 置 null 并重建（所有图标恢复"非当前"的样式与尺寸）。
func clear_current() -> void:
	_current = null
	_rebuild()


## 重建整条顺序条：清空 %Icons → 为每个有效单位生成一个图标。
## 参数/返回值：无。
## 副作用：销毁 %Icons 的所有旧子节点、创建新子节点（都是纯 UI，不触碰战斗数据）。
## 两步清理的原因（重要）：
##   queue_free() 只是"本帧末释放"，节点在这一帧内仍然是 %Icons 的子节点。
##   若省略 remove_child()，本帧里会出现"旧图标 + 新图标"并存 ——
##   HBoxContainer 会把它们全部算进布局，表现为顺序条瞬间变长/闪一下。
##   先 remove_child 立刻断开父子关系，再 queue_free 延迟回收内存，视觉上才是瞬间替换。
## is_instance_valid 的必要性：_queue 是弱类型 Array，可能在两次重建之间积累了已释放的节点
##   （例如单位被 Battle._clear_units() 提前 free 掉了），访问它们的属性会崩。
## 注意：这里没有做"只更新有变化的图标"的增量优化，理由见文件头的扩展提示。
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


## 生成一个单位图标：一个正方 Panel（带圆角描边）+ 里面铺满的单位贴图。
## 参数 unit：要显示的单位（调用方已保证 is_instance_valid）；is_current：是否当前出手者。
## 返回值：新建的 Panel（尚未入树，由 _rebuild() 负责 add_child）。
## 副作用：无（只创建节点、读 unit 的数据，不改任何战斗状态）。
## 视觉规则：
##   · 尺寸：当前出手者 64，其他人 52 —— 用大小做最直观的强调；
##   · 边框宽度：当前 3px，其他 2px；
##   · 边框颜色优先级：当前金黄 > 我方绿 / 敌方红（用嵌套三目表达式实现）；
##   · 单位若已阵亡，整个 panel 的 modulate.a 降到 DEAD_ALPHA（0.3）。
## 为什么所有 mouse_filter 都设 IGNORE：
##   顺序条只是展示，不该吃掉点击；而且它盖在战场上方，如果 mouse_filter 保持默认的 STOP，
##   会挡住下面 BattleUnit 的 %ClickArea，导致"被顺序条盖住的那块区域点不到敌人"。
##   Panel 和 TextureRect 都要设（父子都要，任何一层 STOP 都会拦截）。
## 布局细节：
##   · 用 custom_minimum_size 固定尺寸（HBoxContainer 按最小尺寸排版）；
##   · add_theme_stylebox_override("panel", style)：给"这一个 Panel 实例"换 StyleBox，
##     不会污染全局主题；每次都 new 一个 StyleBoxFlat 是刻意的（共享 StyleBox 就地改颜色
##     会污染所有引用者 —— StyleBox 是 Resource）；
##   · tex.set_anchors_preset(PRESET_FULL_RECT) 在 add_child 之后调用，
##     让 TextureRect 撑满 Panel（锚点设置在入树后应用更稳妥）；
##   · stretch_mode = KEEP_ASPECT_CENTERED 保证非正方形贴图不会变形、居中留边；
##   · expand_mode = EXPAND_IGNORE_SIZE 让贴图不受 Control 的默认最小尺寸影响。
## 坑：unit.stats 可能为 null（资源没配全），所以贴图取值前有 `if unit.stats != null else null` 兜底。
func _make_icon(unit: BattleUnit, is_current: bool) -> Control:
	# 当前出手者更大：52 → 64（约 +23%），够明显又不会把顺序条挤变形。
	var size := 64.0 if is_current else 52.0

	var panel := Panel.new()
	panel.custom_minimum_size = Vector2(size, size)
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
