extends CanvasLayer
## TooltipManager —— 全局提示卡管理器（autoload 单例）
##
## 解决的问题：
##   1. 提示卡不再挂在会被裁剪的容器里（独立 CanvasLayer，永远画最上层、不会被裁）
##   2. 一个场景只实例化一份，反复复用（不随悬停次数增长）
##   3. 定位统一走"默认右下 → 放不下就翻转 → 最后夹在屏幕内"
##   4. 延迟出现 + 淡入淡出，鼠标快速划过一排卡片时不会乱闪
##   5. 提示卡整棵树都不吃鼠标事件，避免它触发下面卡片的 mouse_exited 造成闪烁
##
## ── 用法 ──────────────────────────────────────────────────────────
## 1) 项目设置 → 自动加载：添加本文件，节点名填 TooltipManager
##    （或直接在 project.godot 的 [autoload] 里加一行：
##     TooltipManager="*res://autoloads/tooltip_manager.gd"）
## 2) 在下面 _ready() 的"登记"区按需增删：数据类型 → 卡片场景 → 属性名
## 3) 任意位置调用：
##      TooltipManager.show_for(data)                  # 锚在鼠标旁
##      TooltipManager.show_for_control(card, data)    # 锚在控件右上角（手柄/键盘）
##      TooltipManager.hide_tip()                      # 隐藏
##
## 卡片的两种接法（任选其一）：
##   A. 注册时给属性名（推荐，零改动）：register(UnitStats, scene, &"unit")
##   B. 卡片脚本实现 func bind(data: Object) -> void: ...（注册时属性名留空）
##
## 注意事项：
##   · 卡片根节点请用 custom_minimum_size 固定尺寸，否则第一帧可能错位
##   · 卡片不要放进任何 Container（容器会重排它的位置）
##   · 提示卡是纯展示，鼠标事件全部忽略；需要交互的浮层请另做

signal tooltip_opened(data: Object)
signal tooltip_closed

const LAYER := 128                  # 高于所有游戏 UI
const PLACEMENT_OFFSET := Vector2(16, 16)
const SHOW_DELAY := 0.25            # 秒；0 = 立刻显示
const FADE_IN_TIME := 0.08
const FADE_OUT_TIME := 0.06
const MOUSE_DEADZONE := 24.0        # 鼠标移动超过这个距离才重新定位

enum AnchorMode { NONE, POINT, CONTROL }

# ── 可调参数 ──────────────────────────────────────────────────────
var enabled := true
var delay := SHOW_DELAY
var placement_offset := PLACEMENT_OFFSET
var follow_mouse := true            # POINT 模式下是否跟随鼠标（带死区）

# ── 内部状态 ──────────────────────────────────────────────────────
var _registry: Dictionary = {}      # Script -> { scene: PackedScene, property: StringName }
var _instances: Dictionary = {}     # scene.resource_path -> Control（复用的实例）

var _current: Control = null
var _current_data: Object = null
var _anchor_mode := AnchorMode.NONE
var _anchor_point := Vector2.ZERO
var _anchor_control: Control = null
var _last_mouse := Vector2.ZERO
var _token := 0
var _tween: Tween


func _ready() -> void:
	layer = LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)

	# ── 登记区：数据类型 → 卡片场景 → 属性名（用不到的删掉即可）──────
	register(ItemBase, preload("res://scenes/ui/hover_card/hover_item_card.tscn"), &"item")
	register(UnitStats, preload("res://scenes/ui/hover_card/hover_unit_card.tscn"), &"unit")


# ══════════════════════════════════════════════════════════════════
#  注册
# ══════════════════════════════════════════════════════════════════

## data_class 传 class_name（例如 ItemBase）；property_name 留空则调用卡片的 bind()
func register(data_class: Script, scene: PackedScene, property_name: StringName = &"") -> void:
	_registry[data_class] = { "scene": scene, "property": property_name }


func unregister(data_class: Script) -> void:
	_registry.erase(data_class)


func set_enabled(value: bool) -> void:
	enabled = value
	if not enabled:
		hide_tip()


# ══════════════════════════════════════════════════════════════════
#  对外显示接口
# ══════════════════════════════════════════════════════════════════

## 锚在鼠标旁；传 anchor_point 则锚在指定的视口坐标（左上角为原点的坐标）
func show_for(data: Object, anchor_point: Vector2 = Vector2.INF) -> void:
	if data == null or not enabled:
		hide_tip()
		return
	_anchor_mode = AnchorMode.POINT
	_anchor_control = null
	_anchor_point = get_viewport().get_mouse_position() if anchor_point == Vector2.INF else anchor_point
	_begin(data)


## 锚在某个控件旁边（鼠标不在附近时也能用，适合手柄/键盘导航）
func show_for_control(control: Control, data: Object) -> void:
	if data == null or not enabled or not is_instance_valid(control):
		hide_tip()
		return
	_anchor_mode = AnchorMode.CONTROL
	_anchor_control = control
	_begin(data)


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
	_tween.tween_callback(func() -> void:
		if is_instance_valid(card):
			card.hide()
		_current_data = null
		tooltip_closed.emit())


func is_showing() -> bool:
	return _current != null and _current.visible


func current_data() -> Object:
	return _current_data


# ══════════════════════════════════════════════════════════════════
#  内部实现
# ══════════════════════════════════════════════════════════════════

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


func _process(_delta: float) -> void:
	if _current == null or not _current.visible:
		set_process(false)
		return
	var mouse := get_viewport().get_mouse_position()
	if mouse.distance_to(_last_mouse) >= MOUSE_DEADZONE:
		_last_mouse = mouse
		_anchor_point = mouse
		_place()


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


func _bind(card: Control, data: Object, entry: Dictionary) -> void:
	var property: StringName = entry.get("property", &"")
	if property != &"":
		card.set(property, data)
	elif card.has_method("bind"):
		card.call("bind", data)
	else:
		push_warning("TooltipManager: %s 没有 bind() 方法，登记时也没给属性名" % card.name)


## 按数据的脚本沿着继承链找登记项（登记 ItemBase，传 ItemWeapon 也能命中）
func _find_entry(data: Object) -> Dictionary:
	var script: Script = data.get_script()
	while script != null:
		if _registry.has(script):
			return _registry[script]
		script = script.get_base_script()
	return {}


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


## 提示卡必须完全不接收鼠标，否则它一出现就会让下面卡片的 mouse_exited 触发 → 反复闪烁
func _ignore_mouse_recursive(node: Node) -> void:
	for child in node.get_children():
		if child is Control:
			(child as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ignore_mouse_recursive(child)


func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
