# TitleScreen —— 游戏主菜单屏幕
# 职责：只是"按钮面板"，不切场景、不改 Global、不读地图数据 —— 按钮 → emit 信号 → GameRoot 做事。
# 位置：GameRoot.show_title() 实例化后挂到 UIRoot（CanvasLayer）下，是常驻主场景的一个"屏幕"。
# 数据流：GameRoot 先写 screen.last_result 再 add_child，本文件在 _ready() 里显示到底部的小字。
# 布局：标题在左上角，按钮横排在底部中间 —— 尽量不挡背景画面。
# 键盘：↑↓←→/Enter/空格 走 Godot 内置 ui_* + GUI 焦点（_ready() 末尾 grab_focus 第一个可用按钮）；
#   W/S/E 走 _unhandled_input + Global 的工具；Esc 刻意不做任何事（主菜单没有上一级）。
# 坑：last_result 必须在 add_child 之前赋值；%控件 都是 @onready，_init() 里别访问。
extends Control
class_name TitleScreen

# ── 对外信号（GameRoot 在 show_title() 里 connect）──
## 点了「新的征程」。无参数 —— 从哪张图开始由 GameRoot 按 maps/start_map_id 决定。
signal new_game_requested
## 点了「退出游戏」。GameRoot 接的是 get_tree().quit()。
signal quit_requested

# ── 输入数据（由 GameRoot 在 add_child 之前写入）──
## 上一场的结算文案，显示在左下角；空串 = 整行隐藏。必须 add_child 之前赋值，_ready() 才读得到。
var last_result := ""

## 焦点环：按视觉顺序排列的可点按钮。_ready() 建好并聚焦第一个，W/S 用它循环、E 用它确认。
var _focus_ring: Array[Control] = []

# ── 节点引用（% = unique_name_in_owner）──
## 左下角的结算提示：只在有 last_result 时显示。
@onready var result_label: Label = %ResultLabel
## 「新的征程」按钮。
@onready var new_game_button: Button = %NewGameButton
## 「继续游戏」按钮。目前恒为 disabled（没有存档系统）。
@onready var continue_button: Button = %ContinueButton
## 「退出游戏」按钮 → quit_requested。
@onready var quit_button: Button = %QuitButton


## 进入树时执行一次：配置结果提示与按钮、连信号、建焦点环并聚焦第一个可用项。
## 副作用：改 result_label.text / continue_button.disabled，connect 两个按钮的 pressed。
## 换屏时本实例被移除，连接随之销毁，不需要手动 disconnect（也不会重复连接）。
func _ready() -> void:
	# 只有"确实有上一局结果"才显示这行；没有就整行隐藏，别让静态说明挡画面。
	result_label.text = last_result
	result_label.visible = not last_result.is_empty()

	# TODO: 存档系统做好后，这里改成"有存档才可点"；现在宁可禁用也不做假按钮。
	continue_button.disabled = true

	# 只连真正有处理函数的两个按钮；continue_button 没有对应信号，纯摆设。
	new_game_button.pressed.connect(_on_new_game_pressed)
	quit_button.pressed.connect(_on_quit_pressed)

	# ⚠ 顺序：必须在 continue_button.disabled = true 之后收集 —— 置灰按钮进环会让 W/S 停住不动。
	# ⚠ 没有末尾的 grab_focus()，方向键按下去会"没人可动"（焦点为空），主菜单以前不支持键盘正是这个原因。
	var buttons: Array[Button] = [new_game_button, continue_button, quit_button]
	_focus_ring.clear()
	for button in buttons:
		if Global.can_focus(button):
			_focus_ring.append(button)
	if not _focus_ring.is_empty():
		_focus_ring[0].grab_focus()

	_build_motes()
	resized.connect(_center_motes)


## 飘浮灵光：两层粒子 —— 大量细小光尘 + 少量大颗光晕，往上缓缓飘动。
## 代码生成贴图与粒子，不依赖任何外部素材；插在标题/菜单之前（画在背景上、UI 下）。
## ⚠ 只是装饰：不接输入、mouse_filter 与命中无关（Node2D 不参与 UI 事件）。
func _build_motes() -> void:
	# 第一层：细光尘，数量多、颗粒小，负责"空气里有灵气"的氛围。
	_spawn_motes("Motes", {
		"amount": 90,
		"rect": Vector2(1400, 300),
		"speed": Vector2(8.0, 30.0),
		"scale": Vector2(0.2, 0.5),
		"alpha": 0.5,
		"px": 20,
	})
	# 第二层：大光晕，数量少、颗粒大、飘得更慢，负责"看得见的光点"。
	_spawn_motes("MotesGlow", {
		"amount": 8,
		"rect": Vector2(1300, 260),
		"speed": Vector2(4.0, 14.0),
		"scale": Vector2(0.6, 1.1),
		"alpha": 0.28,
		"px": 30,
	})
	_center_motes()


## 生成并插入一层灵光粒子。参数用字典，方便再加一层时只改数字。
func _spawn_motes(node_name: String, cfg: Dictionary) -> void:
	var motes := CPUParticles2D.new()
	motes.name = node_name
	motes.texture = _dot_texture(int(cfg["px"]))
	motes.amount = int(cfg["amount"])
	motes.lifetime = 12.0
	motes.preprocess = 10.0
	motes.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	motes.emission_rect_extents = cfg["rect"]
	motes.direction = Vector2(0, -1)
	motes.spread = 26.0
	motes.initial_velocity_min = cfg["speed"].x
	motes.initial_velocity_max = cfg["speed"].y
	motes.gravity = Vector2(0, -6)
	motes.scale_amount_min = cfg["scale"].x
	motes.scale_amount_max = cfg["scale"].y
	motes.color = Color(1.0, 0.86, 0.58, cfg["alpha"])
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	motes.material = mat
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, 0))
	ramp.set_color(1, Color(1, 1, 1, 0))
	ramp.add_point(0.2, Color(1, 1, 1, 1))
	ramp.add_point(0.8, Color(1, 1, 1, 1))
	motes.color_ramp = ramp
	add_child(motes)
	var menu := get_node_or_null(^"MenuArea")
	var index := menu.get_index() if menu != null else get_child_count() - 1
	move_child(motes, index)


## 把灵光层挪到画面中下部（窗口尺寸变化时跟着走）。
func _center_motes() -> void:
	for node_name in ["Motes", "MotesGlow"]:
		var motes := get_node_or_null(NodePath(node_name)) as CPUParticles2D
		if motes != null:
			motes.position = Vector2(size.x * 0.5, size.y * 0.6)


## 生成一张中心亮、边缘透明的圆点贴图（粒子用）。
func _dot_texture(px: int) -> ImageTexture:
	var img := Image.create(px, px, false, Image.FORMAT_RGBA8)
	var c := Vector2(px - 1, px - 1) * 0.5
	var r := float(px) * 0.5
	for y in px:
		for x in px:
			var d := (Vector2(x, y) - c).length() / r
			var a := clampf(1.0 - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a * a))
	return ImageTexture.create_from_image(img)


## 未被子控件消费的输入：补 W S（move_up / move_down）与 E（交互键）。
## ↑↓/Enter/空格 由 Godot 的 GUI 焦点系统更早消费，这里收不到；Esc 刻意不处理。
## ⚠ E 之后本屏幕可能立刻被 queue_free，所以两个分支都是"先做动作、再 set_input_as_handled"。
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("move_up"):
		Global.step_focus(self, _focus_ring, -1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("move_down"):
		Global.step_focus(self, _focus_ring, 1)
		get_viewport().set_input_as_handled()
	elif Global.is_interact_event(event):
		if Global.activate_focused(self):
			get_viewport().set_input_as_handled()


## 「新的征程」回调：播 UI 音效 + emit new_game_requested。
func _on_new_game_pressed() -> void:
	_click()
	new_game_requested.emit()


## 「退出游戏」回调：播 UI 音效 + emit quit_requested（真正退出由 GameRoot 接的 get_tree().quit()）。
func _on_quit_pressed() -> void:
	_click()
	quit_requested.emit()


## 统一的按钮点击音效（三处调用一致，以后换音效只改这里）。
## ⚠ SoundManager 池子只有 10 个播放器，同一帧点太多按钮会静默丢音（不影响逻辑）。
func _click() -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
