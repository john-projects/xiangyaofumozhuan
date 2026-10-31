# ═══════════════════════════════════════════════════════════════════════════
# WorldNPC —— 世界地图上的一个 NPC（纯"表现 + 数据容器"，几乎没有自己的逻辑）
# ═══════════════════════════════════════════════════════════════════════════
# 在系统里的位置：
#   本脚本是 scenes/world/world_npc.tscn 的根脚本。它不是自动加载的，
#   而是由 WorldMap._add_npc() 用 preload 的 NPC_SCENE 实例化后 add_child 到
#   WorldMap 下面的（WorldMap 开了 y_sort_enabled，所以玩家能绕到 NPC 前面/后面）。
#
# 职责边界（很重要）：
#   · 本文件**不做**距离判定、不做输入处理、不做传送 —— 那些全在 WorldMap 里；
#   · 本文件只负责两件事：把 MapNPC 数据画出来（setup），以及切换"高亮"表现（set_highlight）。
#   这样拆是为了让"谁离玩家最近""能不能交谈"这类全局判断只有一个地方（WorldMap）。
#
# 场景节点构成（都是 unique_name_in_owner，所以脚本里用 % 取）：
#   Shadow(Polygon2D)   脚下的椭圆阴影（场景里预置，本脚本不碰）
#   Fallback(Polygon2D) 金色方块占位，MapNPC.texture 为空时显示
#   Sprite(Sprite2D)    NPC 立绘，scale 在场景里设为 1.3
#   NameLabel(Label)    NPC 名字，位置在头顶（offset_top 为负）
#   Mark(Label)        "按 E 交谈"提示，默认 visible = false，高亮时才显示
#
# 数据流：MapNPC(.tres 资源) → WorldMap._add_npc() → npc.setup(data) → 本文件的显示逻辑。
#         本文件只**读** data，从不修改它（就地改 .tres 资源会污染所有引用同一资源的 NPC）。
#
# 坑：
#   · setup() 必须在 add_child 之后调用 —— 它要访问 @onready 变量（%Sprite 等），
#     而 @onready 是在节点 _ready() 之前才赋值的，早于进树调用会拿到 null。
#   · set_highlight() 每次都会 create_tween()，如果每帧调用会不断堆积 tween；
#     所以 WorldMap._update_nearest() 只在"最近 NPC 真的换了"时才调用它。

extends Node2D
class_name WorldNPC

## 地图上的 NPC：显示立绘/名字，玩家靠近时高亮提示可以交谈
## 位置与行为由 WorldMap 决定（WorldMap 负责距离判定和交互）

## 高亮时的缩放倍率（倍）。1.1 = 放大 10%，足够让玩家注意到，又不至于顶到别的 NPC。
## 注意：缩放的基准是 self（整个 NPC 节点），所以名字标签和提示标记也会跟着一起放大。
const HIGHLIGHT_SCALE := 1.1

## NPC 名字的两种颜色。
## 常态金色（和"路人/NPC"的视觉语言一致）；玩家走进交互半径、能按 E 时切成红色提示。
## 红金两色都配了黑描边（见 _apply_name_style），铺在任何地图底图上都看得清。
const NAME_COLOR_NPC := Color(1.0, 0.84, 0.36)
const NAME_COLOR_INTERACT := Color(1.0, 0.35, 0.35)

## 本 NPC 的配置数据（MapNPC 资源：id / display_name / texture / position / dialogue /
## destinations / teleport_label）。由 WorldMap 在 setup() 里注入；本文件只读不写。
## 类型是 Resource（不是节点），运行时改它会影响所有引用同一 .tres 的 NPC，务必小心。
var data: MapNPC

# ── 节点引用（% = unique_name_in_owner）──────────────────────────────────────
## 本图角色的目标显示高度（世界像素）。由 WorldMap 在 setup() 前写入，
## 用来把任意分辨率的立绘归一到和玩家一致的高度 —— 不归一的话，512 高的新立绘
## 会比 150 高的旧占位大三倍多。
var display_height := 195.0
## 站立呼吸：上下浮动幅度（像素）、周期（秒）。
const IDLE_BOB := 3.0
const IDLE_PERIOD := 2.4
## 每个 NPC 用自己的周期与相位，一群人站着才不会像在做广播体操。
var _idle_phase := 0.0
var _idle_period := IDLE_PERIOD
## 脚下阴影（第一次 setup 时建，之后复用）。
var _shadow: Polygon2D = null
## NPC 立绘。有 texture 时用它；没有则隐藏并显示 Fallback 色块。
@onready var sprite: Sprite2D = %Sprite
## 占位色块（金色方块）。仅当 MapNPC.texture 为空时可见，用来"没美术也能跑"。
@onready var fallback: Polygon2D = %Fallback
## 头顶的名字标签，内容取 data.display_name。
@onready var name_label: Label = %NameLabel
## 头顶的"按 E 交谈"提示标签。默认隐藏，只有被高亮时显示（见 set_highlight）。
@onready var mark: Label = %Mark


## 用配置数据初始化本 NPC 的外观。
## 参数 p_data：该 NPC 的 MapNPC 资源（调用方保证非 null）。
## 返回值：无。
## 副作用：写 data、sprite.texture、fallback.visible、name_label.text，
##        并间接调用 set_highlight(false) —— 后者会 create_tween() 造一条缩放动画。
## 调用时机：必须在节点**已进树**之后调用（add_child 之后），否则 @onready 变量全是 null；
##   WorldMap._add_npc() 正是"先 add_child(npc)，再 npc.setup(data)"这个顺序。
## 注意：这里没做 data 为 null 的兜底，传 null 会在 data.texture 处直接报错。
func setup(p_data: MapNPC) -> void:
	data = p_data
	_idle_phase = randf() * TAU
	_idle_period = IDLE_PERIOD * randf_range(0.85, 1.2)
	_ensure_shadow()
	if data.texture != null:
		sprite.texture = data.texture
		_fit_sprite_to_height()
		fallback.visible = false
	else:
		fallback.visible = true
	name_label.text = data.display_name
	_apply_name_style(NAME_COLOR_NPC)      # NPC 名字常态是金色
	set_highlight(false)


## 站立呼吸：只动 sprite 的 y，幅度 3px、周期 2 秒左右。
## 不做缩放呼吸 —— 缩放会连名字版和阴影的视觉比例一起改，反而乱。
func _process(delta: float) -> void:
	if sprite == null or sprite.texture == null:
		return
	_idle_phase += delta * TAU / _idle_period
	sprite.position.y = -IDLE_BOB * (0.5 + 0.5 * sin(_idle_phase))


## 脚下阴影：三层同心椭圆（外淡内深），和队长/队友的地面阴影同一套参数。
## 插到子节点最前面，保证画在立绘下面（这层不受 y_sort 影响，同父节点按顺序绘制）。
func _ensure_shadow() -> void:
	if _shadow != null or not is_inside_tree():
		return
	var ellipse := PackedVector2Array()
	var rx := display_height * 0.16
	var ry := display_height * 0.045
	for i in 48:
		var angle := TAU * float(i) / 48.0
		ellipse.append(Vector2(cos(angle) * rx, sin(angle) * ry))
	_shadow = Polygon2D.new()
	_shadow.name = "Shadow"
	_shadow.polygon = ellipse
	_shadow.color = Color(0.10, 0.075, 0.065, 0.055)
	for index in 2:
		var inner := Polygon2D.new()
		inner.polygon = ellipse
		inner.scale = Vector2.ONE * (0.78 if index == 0 else 0.52)
		inner.color = Color(0.10, 0.075, 0.065, 0.07 if index == 0 else 0.12)
		_shadow.add_child(inner)
	add_child(_shadow)
	move_child(_shadow, 0)      # 画在最底层


## 按贴图高度归一到 display_height，并把脚底锚到节点原点。
## Sprite2D 是居中绘制，offset.y 上移半个（未缩放前的）贴图高度后，底边正好落在 y=0 ——
## 这样不同分辨率、不同身高的立绘踩在同一条地面上，阴影和名字版也不用逐个调。
## 副作用：改 sprite.scale / sprite.offset / name_label 与 Mark 的纵向位置。
func _fit_sprite_to_height() -> void:
	if sprite.texture == null:
		return
	var tex_h := float(sprite.texture.get_height())
	if tex_h <= 0.0 or display_height <= 0.0:
		return
	var s := display_height / tex_h
	sprite.scale = Vector2(s, s)
	sprite.offset = Vector2(0.0, -tex_h * 0.5)
	# 阴影尺寸跟着身高重算（重新 setup 时对得上）
	if _shadow != null:
		var ellipse := PackedVector2Array()
		var rx := display_height * 0.16
		var ry := display_height * 0.045
		for i in 48:
			var angle := TAU * float(i) / 48.0
			ellipse.append(Vector2(cos(angle) * rx, sin(angle) * ry))
		_shadow.polygon = ellipse
		for child in _shadow.get_children():
			(child as Polygon2D).polygon = ellipse
	# 头顶名字与提示跟着身高走
	name_label.offset_top = -display_height - 30.0
	name_label.offset_bottom = -display_height - 4.0
	if mark != null:
		mark.offset_top = -display_height - 56.0
		mark.offset_bottom = -display_height - 32.0


## 给名字上色（并补一圈黑描边，地图底色再花也看得清）。
## 参数 color：金色（常态）/ 红色（可交互）。
func _apply_name_style(color: Color) -> void:
	name_label.add_theme_color_override("font_color", color)
	name_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	name_label.add_theme_constant_override("outline_size", 5)


## 切换"可交谈"高亮表现：显示/隐藏头顶提示 + 平滑放大/还原。
## 参数 value：true = 玩家在交互半径内（高亮）；false = 恢复常态。
## 返回值：无。
## 副作用：
##   · 改 mark.visible；
##   · create_tween() 新建一条 tween，0.1 秒内把 self.scale 补间到目标值。
## 为什么用 tween 而不是直接赋 scale：直接跳变太生硬；0.1 秒是"够快不拖沓"的折中。
## 坑：
##   · create_tween() 是"绑定在本节点上"的 tween，本节点被 queue_free 后会自动失效，
##     不需要手动 kill；
##   · 每次都新建 tween：短时间内连续调用（例如每帧）会让多条 tween 同时改 scale，
##     所以调用方必须做"只在状态变化时调用"的优化（WorldMap._update_nearest 已这么做）。
func set_highlight(value: bool) -> void:
	mark.visible = value
	# 能交互时名字变红，离开交互半径恢复金色。
	_apply_name_style(NAME_COLOR_INTERACT if value else NAME_COLOR_NPC)
	var tween := create_tween()
	tween.tween_property(self, "scale", Vector2.ONE * (HIGHLIGHT_SCALE if value else 1.0), 0.1)
