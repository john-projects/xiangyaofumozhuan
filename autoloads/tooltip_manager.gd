extends CanvasLayer
## TooltipManager —— 全局提示卡管理器（autoload，CanvasLayer）。
## 独立于场景：卡片只实例化一份、常驻复用，画在 LAYER=128（所有游戏 UI 之上），不受容器裁剪。
## 定位：默认右下 → 放不下翻转 → 夹在屏幕内；延迟出现 + 淡入淡出，鼠标快速划过不闪。
## 本文件不复制、不解释数据：card.set(属性名, data) 或 card.bind(data)，展示完全由卡片脚本决定。
## 用法：register(数据类型, 卡片场景, 属性名或留空走 bind())，再 show_for(data) / show_for_control(控件, data) / hide_tip()。
## 登记沿 get_base_script() 向上匹配，登记 ItemBase 即可服务所有道具子类。

## 卡片状态边沿信号（不是鼠标事件）。⚠ 被新提示打断的旧卡片不会补发 tooltip_closed。
signal tooltip_opened(data: Object)   # 卡片开始淡入时 emit，携带当前绑定的数据对象
signal tooltip_closed                 # 卡片淡出结束、真正 hide() 之后 emit；无参数

## 时间单位均为秒；LAYER 高于所有游戏 UI，PLACEMENT_OFFSET 避免贴边，SHOW_DELAY 防快速划过乱闪，
## MOUSE_DEADZONE 防 1px 抖动反复重排。delay / placement_offset 还可在运行期覆盖。
const LAYER := 128                  # 高于所有游戏 UI
const PLACEMENT_OFFSET := Vector2(16, 16)   # 卡片相对锚点的偏移（像素，右下方），让卡片不要紧贴鼠标/控件边缘
const SHOW_DELAY := 0.25            # 秒；0 = 立刻显示
const FADE_IN_TIME := 0.08          # 淡入时长（秒）。很短：观感是"立刻出现，但不生硬"
const FADE_OUT_TIME := 0.06         # 淡出时长（秒）。比淡入更短，收起来更干脆
const MOUSE_DEADZONE := 24.0        # 鼠标移动超过这个距离才重新定位

## 锚定模式：决定 _place() 从哪里取锚点。
enum AnchorMode { NONE, POINT, CONTROL }   # NONE=初始/无卡片；POINT=跟鼠标（show_for）；CONTROL=跟控件右上角（show_for_control）

# ── 可调参数（运行期可改，影响所有调用方）──
var enabled := true                 # 总开关：false 时 show_for / show_for_control 只会收起卡片（等价于 hide_tip）
var delay := SHOW_DELAY             # 显示延迟（秒），默认取 SHOW_DELAY；设成 0 就是立即显示（调试或手柄导航时常用）
var placement_offset := PLACEMENT_OFFSET   # 卡片相对锚点的偏移（像素），默认 (16,16)；调大可以让卡片离鼠标更远
var follow_mouse := true            # POINT 模式下是否跟随鼠标（带死区）

# ── 内部状态（下划线开头，外部不要直接改；_instances 创建后常驻不清理）──
var _registry: Dictionary = {}      # Script -> { scene: PackedScene, property: StringName }
var _instances: Dictionary = {}     # scene.resource_path -> Control（复用的实例）

var _current: Control = null        # 当前正在展示或淡出的卡片；null = 当前什么都没有
var _current_data: Object = null    # 与 _current 配对的数据对象；hide_tip 走完后清空
var _anchor_mode := AnchorMode.NONE # 当前锚定模式，决定 _place() 从哪里取锚点
var _anchor_point := Vector2.ZERO   # POINT 模式的锚点（视口坐标）；CONTROL 模式不用它
var _anchor_control: Control = null # CONTROL 模式的锚点控件；切到 POINT 模式时会被显式置 null
var _last_mouse := Vector2.ZERO     # 上一次记录到的鼠标位置，用于死区比较
var _token := 0                     # 显示请求的"版本号"：每次新显示请求或 hide 都 +1；await 醒来靠它判断自己是否已过期（防抖核心）
var _tween: Tween                   # 当前正在跑的淡入/淡出 tween；可能为 null，用之前必须先判 null 再 is_valid()


## 初始化：设图层、PROCESS_MODE_ALWAYS，先关 _process（仅 POINT+follow_mouse 时开），并登记卡片类型。
## 不实例化卡片（懒加载）；登记用的 preload 路径写死，文件挪走会在启动时报错。
func _ready() -> void:
	layer = LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)

	# ── 登记区：数据类型 → 卡片场景 → 属性名（用不到的删掉即可）──────
	register(ItemBase, preload("res://scenes/ui/hover_card/hover_item_card.tscn"), &"item")
	register(UnitStats, preload("res://scenes/ui/hover_card/hover_unit_card.tscn"), &"unit")


# ── 注册 ──

## 登记"数据类型 → 卡片场景 → 属性名"。data_class 是 Script（class_name），登记父类可覆盖子类。
## property_name 留空则调用卡片的 bind()；重复登记同类型即覆盖，不会多出实例。
func register(data_class: Script, scene: PackedScene, property_name: StringName = &"") -> void:
	_registry[data_class] = { "scene": scene, "property": property_name }


## 反注册：只删登记表那一条，已实例化的卡片不释放（只是再也 bind 不到数据）。
func unregister(data_class: Script) -> void:
	_registry.erase(data_class)


## 总开关：设为 false 会立即 hide_tip()（作废延迟显示并淡出）；设为 true 不会主动显示任何东西。
func set_enabled(value: bool) -> void:
	enabled = value
	if not enabled:
		hide_tip()


# ── 对外显示接口 ──

## 在鼠标旁显示（POINT 模式）。data 为 null 等同 hide_tip()。
## anchor_point 默认 Vector2.INF 是哨兵，表示用当前鼠标位置（所以不能真的传 INF 当坐标）。
func show_for(data: Object, anchor_point: Vector2 = Vector2.INF) -> void:
	if data == null or not enabled:
		hide_tip()
		return
	_anchor_mode = AnchorMode.POINT
	_anchor_control = null
	_anchor_point = get_viewport().get_mouse_position() if anchor_point == Vector2.INF else anchor_point
	_begin(data)


## 把提示卡锚到控件右上角（CONTROL 模式），手柄 / 键盘导航靠它。
## data 为空、enabled=false 或控件已释放都会先 hide_tip()。
func show_for_control(control: Control, data: Object) -> void:
	if data == null or not enabled or not is_instance_valid(control):
		hide_tip()
		return
	_anchor_mode = AnchorMode.CONTROL
	_anchor_control = control
	_begin(data)


## 隐藏当前提示卡。_token += 1 作废所有等待中的延迟，停跟随，再淡出 0.06s 后在回调里 hide 并 emit。
## ⚠ 淡出是异步的：刚调完 is_showing() 可能仍为 true。本来就不可见时不会 emit tooltip_closed。
func hide_tip() -> void:
	_token += 1                       # 让还在等待延迟的 show 失效
	set_process(false)
	if _current == null or not _current.visible:
		_current_data = null
		return
	var card := _current
	_kill_tween()
	_tween = create_tween()
	_tween.tween_property(card, "modulate:a", 0.0, FADE_OUT_TIME)
	# 用 bind 传卡片，而不是 lambda 捕获：卡片万一被提前释放，bind 只是传进一个失效引用，
	# 不会像 lambda 那样在调试器里刷 "Lambda capture at index 0 was freed"。
	_tween.tween_callback(_hide_card.bind(card))


## 淡出结束：隐藏卡片、清数据、emit tooltip_closed（卡片可能已被释放，先判有效）。
func _hide_card(card: Control) -> void:
	if is_instance_valid(card):
		card.hide()
	_current_data = null
	tooltip_closed.emit()


## 当前是否有卡片显示中。注意淡出过程中 visible 仍为 true。
func is_showing() -> bool:
	return _current != null and _current.visible


## 当前绑定的数据对象（可能为 null）。只读，调用方自行判空。
func current_data() -> Object:
	return _current_data


# ── 内部实现 ──

## 显示流程统一入口：查登记 → 取卡片 → 换目标时藏旧卡 → 绑定数据。
## 同一份数据 + 同一张卡 + 已可见时只重算位置（防抖：鼠标微动不重新计时 / 淡入）。
## ⚠ async：await 醒来后必须核对 token、enabled 与 _current，期间世界可能已变。
func _begin(data: Object) -> void:
	var entry := _find_entry(data)
	if entry.is_empty():
		push_warning("TooltipManager: 没有为 %s 登记卡片场景" % data.get_class())
		return

	var card := _get_card(entry["scene"] as PackedScene)
	if card == null:
		return

	# 换目标时立刻藏掉旧卡片，避免两张叠在一起
	if _current != null and _current != card:
		_current.hide()

	var same_target := _current == card and _current.visible and _current_data == data
	_current = card
	_current_data = data
	_bind(card, data, entry)

	if same_target:
		_place()                       # 内容没变，只更新位置
		return

	_token += 1
	var my_token := _token
	if delay > 0.0:
		await get_tree().create_timer(delay).timeout
		if my_token != _token or not enabled or _current != card:
			return                       # 期间被取消/换目标了
	_show_now()


## 真正显示卡片：尺寸为 0 时用最小尺寸兜底（避免错位），modulate.a 从 0 淡入。
## 按需开 _process（仅 POINT+follow_mouse），记录 _last_mouse，并 emit tooltip_opened。
func _show_now() -> void:
	var card := _current
	if card == null:
		return
	if card.size == Vector2.ZERO:
		card.size = card.get_combined_minimum_size()
	card.modulate.a = 0.0
	card.show()
	_place()
	_kill_tween()
	_tween = create_tween()
	_tween.tween_property(card, "modulate:a", 1.0, FADE_IN_TIME)
	_last_mouse = get_viewport().get_mouse_position()
	set_process(_anchor_mode == AnchorMode.POINT and follow_mouse)
	tooltip_opened.emit(_current_data)


## POINT 模式跟随鼠标：移动超过 MOUSE_DEADZONE 才重排，卡片不显示时自动关 _process。
func _process(_delta: float) -> void:
	if _current == null or not _current.visible:
		set_process(false)
		return
	var mouse := get_viewport().get_mouse_position()
	if mouse.distance_to(_last_mouse) >= MOUSE_DEADZONE:
		_last_mouse = mouse
		_anchor_point = mouse
		_place()


## 按锚点算卡片位置：默认右下 → 放不下反向翻转 → 最后 clamp 进屏幕。
## CONTROL 模式锚在控件右上角；屏幕尺寸取 get_visible_rect()（canvas_items 拉伸下即逻辑分辨率）。
## clamp 上界用 maxf(0, screen-size)，卡片比屏幕大时退化为 0，不会把卡片顶出左上角。
func _place() -> void:
	if _current == null:
		return

	var anchor := _anchor_point
	if _anchor_mode == AnchorMode.CONTROL:
		if not is_instance_valid(_anchor_control):
			hide_tip()
			return
		var r := _anchor_control.get_global_rect()
		anchor = Vector2(r.position.x + r.size.x, r.position.y)   # 控件右上角

	var screen := get_viewport().get_visible_rect().size
	var size := _current.size
	if size == Vector2.ZERO:
		size = _current.get_combined_minimum_size()

	var pos := anchor + placement_offset
	if pos.x + size.x > screen.x:              # 右边放不下 → 翻到左侧
		pos.x = anchor.x - size.x - placement_offset.x
	if pos.y + size.y > screen.y:              # 下边放不下 → 翻到上方
		pos.y = anchor.y - size.y - placement_offset.y

	pos.x = clampf(pos.x, 0.0, maxf(0.0, screen.x - size.x))      # 最后兜底夹住
	pos.y = clampf(pos.y, 0.0, maxf(0.0, screen.y - size.y))
	_current.position = pos


## 把数据灌进卡片：有属性名就 card.set()，否则调卡片的 bind()，两者都没有则 push_warning。
func _bind(card: Control, data: Object, entry: Dictionary) -> void:
	var property: StringName = entry.get("property", &"")
	if property != &"":
		card.set(property, data)
	elif card.has_method("bind"):
		card.call("bind", data)
	else:
		push_warning("TooltipManager: %s 没有 bind() 方法，登记时也没给属性名" % card.name)


## 沿数据脚本的继承链找登记项（子类 → 父类），第一个命中者胜出；找不到返回空字典。
func _find_entry(data: Object) -> Dictionary:
	var script: Script = data.get_script()
	while script != null:
		if _registry.has(script):
			return _registry[script]
		script = script.get_base_script()
	return {}


## 取卡片实例：按 scene.resource_path 缓存，命中且有效就复用（永不清理）。
## 首次实例化：整棵树 mouse_filter=IGNORE，先 hide 再 add_child（避免入树瞬间在 0,0 闪一下）。
func _get_card(scene: PackedScene) -> Control:
	var key := scene.resource_path
	var cached: Control = _instances.get(key)
	if is_instance_valid(cached):
		return cached

	var card := scene.instantiate() as Control
	if card == null:
		push_warning("TooltipManager: %s 的根节点不是 Control" % key)
		return null
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ignore_mouse_recursive(card)              # 整棵树都不吃鼠标事件
	card.hide()
	add_child(card)
	_instances[key] = card
	return card


## 递归把整棵树的 mouse_filter 设为 IGNORE，否则卡片一出现就触发下面控件的 mouse_exited。
func _ignore_mouse_recursive(node: Node) -> void:
	for child in node.get_children():
		if child is Control:
			(child as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ignore_mouse_recursive(child)


## 杀掉当前 tween，防止透明度错乱。⚠ kill 会跳过上一次淡出的回调，tooltip_closed 不会补发。
func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
