# battle_unit.gd —— 单个战斗单位：战斗期可变状态 + 自身表现。
# 状态：hp/mp/cooldowns/defending/alive 都在本脚本的普通变量里；UnitStats 是共享资源，只读不改。
# 表现：攻击位移、施法起手、受击闪烁、选中/目标高亮、血条刷新。
# 谁先出手、打谁、何时结束全由 Battle 驱动；本脚本没有 AI、不主动调用 Battle（单向依赖）。
# 生命周期坑：@onready 只在进树那一刻赋值，所以 Battle 必须先 add_child() 再 setup()；
#   _ready() 早于 setup()，那时 stats 还是 null，依赖 stats 的初始化只能放 setup()。
# 扩展点：伤害/暴击/格挡 → roll_damage()/roll_crit()/try_block()；技能数值 → skill_damage()/skill_crit()；
#   动作演出 → play_attack()/play_cast()/play_hit()；Buff/Debuff 尚未实现（建议加 status 字典 + tick_status()）。
extends Node2D
class_name BattleUnit

## 战斗单位：血量/蓝量状态 + 表现；战斗流程（谁出手、打谁、何时结束）由 Battle 驱动。
## 数据来源：UnitStats（name/icon/health/mana/damage/speed/block_chance/skills），只读。
## 扩展点：伤害公式 → roll_damage()/roll_crit()/try_block()；技能数值 → skill_damage()/skill_crit()。

# ── 对外信号 ──
# 本脚本只"汇报发生了什么"，从不自己决定流程怎么走——所有决策都在 Battle。

## 左键点到本单位（%ClickArea 转发）。谁接：Battle._on_unit_clicked()。
## 敌我双方都会发，由 Battle 用 state 判断是否响应；阵亡后 input_pickable 关闭，不再发。
signal clicked(unit: BattleUnit)

## 鼠标进入/离开。entered=true 进入。目前无消费者，预留给"敌方信息浮窗"。
signal hovered(unit: BattleUnit, entered: bool)

## 血量变化（_refresh_hp() 里发）。目前内部没连，留给外部的战斗日志/悬浮卡。
signal hp_changed(unit: BattleUnit)

## 蓝量变化（_refresh_mana() 里发）。start_cooldown() 也会借它刷新菜单的"冷却 N"。
signal mp_changed(unit: BattleUnit)

## 单位阵亡（_die() 里发，此时 alive=false、点选已关、淡出已启动）。
## 谁接：Battle._on_unit_died()，只刷新顺序条，不从回合队列移除。本信号只发一次。
signal died(unit: BattleUnit)

# ── 视觉常量（选中/目标/悬停/受击/防御/施法配色）──
# 写死不 @export：这是全局统一的战斗语言。颜色都带 alpha，铺在 %Selection 的半透明圈上。

## 当前行动者：暖黄 30%。
const SELECT_COLOR := Color(1.0, 0.86, 0.35, 0.30)
## 待选目标：红 35%，与行动者明显区分。
const TARGET_COLOR := Color(1.0, 0.35, 0.35, 0.35)
## 悬停弱高亮：白 20%，只暗示"可点"。
const HOVER_COLOR := Color(1.0, 1.0, 1.0, 0.20)
## 受击闪红。modulate 是**乘法**染色，(1.0,0.45,0.45) 会让红通道保持、绿蓝压暗。
const HIT_TINT := Color(1.0, 0.45, 0.45)
## 防御淡蓝；play_cast()/play_hit() 收尾也回到它，"防御中"的提示才能保留。
const DEFEND_TINT := Color(0.75, 0.85, 1.0)
## 施法过曝暖色：G/B 通道 >1.0 是刻意的自发光（modulate 允许超过 1）。
const CAST_TINT := Color(1.45, 1.2, 0.9)

## 单位在战斗**场景里的显示高度**（像素）。与贴图分辨率无关：
## _refresh_visuals() 会按 tex_h 反推 sprite.scale，所以换 150px / 320px / 512px 的立绘，
## 屏幕上都是这么高 —— 提高分辨率只提升清晰度，不改布局、也不影响还没换图的老素材。
## 这是一条"美术口径"：想让单位整体变大变小，改这里一处即可。
const UNIT_DISPLAY_HEIGHT := 210.0
const BATTLE_VISUAL_SCALE := UNIT_DISPLAY_HEIGHT / 240.0

# ── 名字配色 ──
# 我方和怪物（敌方）默认都是绿色；只有"当前被选为攻击目标"的那只才变红（见 set_focused）。
## 常态名字：绿色。
const NAME_COLOR_NORMAL := Color(0.45, 1.0, 0.55)
## 攻击目标名字：红色。
const NAME_COLOR_TARGETED := Color(1.0, 0.35, 0.35)
## 我方名字整体上移的像素数（怪物不动）。地图上的姓名版也做了同样的上移。
## 现在统一贴着头顶排，不再给我方额外上移（0 = 一视同仁）。
const NAME_LIFT_PLAYER := 0.0

# ── 战斗里的朝向 ──
# battle.tscn 里 PlayerSlots 在 X 正方向（右）、EnemySlots 在负方向（左）。
# 但镜头是**观战视角**（相机在右下往左上斜看）：我方在右下、敌人在左上，
# 所以我方面朝左上 = 背对镜头，应该用 45° 的 up_left（背面 3/4）；
# 敌人面朝右下 = 面向镜头，用 down_right（正面 3/4）。
# 这正是"越肩视角"该有的样子：近的角色露背、远的角色露脸。
const BATTLE_FACING_PLAYER := "up_left"
const BATTLE_FACING_ENEMY := "down_right"

# ── 头顶信息块的排布（渲染像素，从头顶往上依次堆）──
# 顺序：名字 / 2px / 血条 / 蓝条（血条蓝条紧贴，中间不留缝）/ 6px / 头顶
# 整块完全在角色头顶之上 —— 立绘四周有留白，可见头顶比贴图顶边还要低约 10px，
# 所以这里按"贴图顶边（head）再往上 6px"留足余量，不会压到头发。
const PLATE_NAME_H := 26.0        # 名字标签高度（与场景里 -160~-134 一致）
const PLATE_BAR_H := 22.0         # 每条血/蓝条的高度
const PLATE_NAME_BAR_GAP := 0.0   # 名字和血条之间（0 = 紧贴）
const PLATE_HEAD_GAP := 6.0      # 信息条与头顶留出间隔，避免压住发饰。

# ── 高亮配色（脚下光环）──
# 不再用"描边"：描边会把立绘边缘糊成一圈、和技能特效打架，所以改成脚下光环 + 呼吸脉动。
# 光环由 _build_rings() 在运行期用 Line2D 生成（两圈：内圈实、外圈柔光），不用任何贴图。
## 行动者光环：暖金。
const RING_SELECT := Color(1.0, 0.86, 0.35, 1.0)
## 待选目标光环：红。
const RING_TARGET := Color(1.0, 0.35, 0.35, 1.0)
## 悬停（只是鼠标停上去，还没选）：淡白。
const RING_HOVER := Color(1.0, 1.0, 1.0, 0.75)
## 光环椭圆半径（贴合 %Selection 那个扁圆：横向 58、纵向 17）。
const RING_RX := 58.0 * BATTLE_VISUAL_SCALE
const RING_RY := 17.0 * BATTLE_VISUAL_SCALE
## 光环整体下移的像素：让角色遮住后半圈、脚边只露一圈，避免线条横穿身体。
const RING_DROP := 7.0

# ── 数据源与运行时数值 ──

## 数据源（图标/血量/伤害/速度/格挡率/技能表）。正式流程由 setup() 注入。
## 重要：这是**共享资源**，一个 .tres 可能被多个单位引用，本脚本只读；
##       写 stats.health 会改到所有引用者（经典坑）。
@export var stats: UnitStats

## 是否我方。由 setup() 写入；用于贴图翻转、血条配色、Battle 的回合分发。
var is_player := false
## HP 上限；默认 1.0 只是占位，真值在 setup() 取 maxf(1.0, stats.health)。
var max_hp := 1.0
## 当前 HP（float，飘字时才 int() 取整）；降到 0 触发 _die()。
var hp := 1.0
## MP 上限；0.0 表示没配蓝 → 蓝条隐藏（见 _refresh_visuals）。
var max_mp := 0.0
## 当前 MP；消耗走 spend_mana()，不会低于 0。
var mp := 0.0
## 是否存活。_die() 置 false 后不会再变回 true（只有 setup() 会重置）。
var alive := true
## 是否防御。效果在 take_damage()：伤害 ×0.5（下限 1）。
## 生命周期：Battle._begin_turn() 在该单位**自己的回合开始时**调 set_defending(false)，
##   所以防御只持续到它下次行动前（不再是"防一次 = 永久半伤"）。
var defending := false

## skill_id -> 剩余冷却回合数（用 id 字符串做键：Resource 作键按引用比较，同技能不同实例会分家）。
## 值减到 <=0 时 tick_cooldowns() 直接删键，所以 has() 即代表"冷却中"。
var cooldowns: Dictionary[String, int] = {}
## 本场可用技能，由 Battle 注入（优先 UnitStats.skills，否则 default_skills）。
## 可能是 UnitStats.skills 那个数组本身（非拷贝），只读不改。
var available_skills: Array[SkillData] = []

# ── 高亮状态（私有，统一由 _update_selection() 消费）──
# 三个布尔分开存，取消一种高亮不会误清另一种；颜色优先级：目标 > 选中 > 悬停。
var _selected := false
var _targetable := false
var _hovered := false
## 键盘光标是否停在这里：_targetable=所有候选（红框），_focused=光标那一个（另加轮廓+头顶箭头）。
var _focused := false
## 箭头静止高度；_process 的上下浮动以它为基准，不浮动时也要精确回到这里。
var _arrow_base_y := 0.0
## sprite 初始缩放（场景里可能不是 1.0）；play_cast() 的涨大必须回到这个基准，否则会越放越大/小。
var _base_scale := Vector2.ONE
## 立绘脚在原点时，身体中心相对原点的偏移（负值向上）；_refresh_visuals 里按贴图高度算。
var body_center_offset := 0.0
## 8 方位帧动画控制器。只有 UnitStats.anim_dir 非空的角色才有，否则为 null（走静态贴图）。
var _anim: CharAnim2D = null
## 实时 3D 头像（3D-in-2D）。只有 UnitStats.model_glb 非空的角色才有，优先级最高。
var _model3d: Model3DAvatar = null

# ── 节点引用（%Xxx = unique_name_in_owner，改层级也不失效）──
# 这些 @onready 在 _ready() 之前赋值；_refresh_* 依赖它们，所以 setup() 必须在 add_child() 之后调。
@onready var sprite: Sprite2D = %Sprite
@onready var health_bar: HealthBar = %HealthBar
@onready var mana_bar: HealthBar = %ManaBar
@onready var name_label: Label = %NameLabel
@onready var selection: Polygon2D = %Selection
@onready var click_area: Area2D = %ClickArea
## 选中轮廓层：Sprite 的子节点（show_behind_parent），同贴图 + 描边 shader 往外扩一圈实色。
## 挂成 Sprite 子节点是为了自动继承本体位置/缩放——play_cast() 会 tween sprite.scale，兄弟节点会错位。
## 头顶小箭头（Polygon2D 纯几何）。只在 set_focused(true) 时显示并上下浮动。
@onready var target_arrow: Polygon2D = %TargetArrow
## 脚下高亮光环（运行期由 _build_rings() 生成，不需要在 .tscn 里摆）。
var _ring_core: Line2D
var _ring_glow: Line2D


# ── 生命周期与初始化 ──

## 生命周期入口（引擎调用，在 setup() 之前）：缓存初始缩放、连 ClickArea 三个信号、让血条/名字不吃鼠标。
## 不在这里读 stats：_ready() 时 stats 还是 null；本类父级是 Node2D，无需 super._ready()（子类则必须调）。
func _ready() -> void:
	_base_scale = sprite.scale
	_arrow_base_y = target_arrow.position.y
	# 箭头浮动 + 光环呼吸是"每帧"的事；默认关，set_focused()/_update_selection() 里再开。
	set_process(false)
	_build_rings()
	click_area.input_event.connect(_on_click_area_input_event)
	click_area.mouse_entered.connect(_on_mouse_entered)
	click_area.mouse_exited.connect(_on_mouse_exited)
	# Control 默认 mouse_filter=STOP 会吞事件，Area2D 就收不到 input_event，点单位会失灵。
	_ignore_mouse(health_bar)
	_ignore_mouse(mana_bar)
	_ignore_mouse(name_label)


## 造脚下的高亮光环：两圈 Line2D（外圈粗而淡 = 柔光，内圈细而实 = 亮边）。
## 不用贴图、不用 shader，纯代码生成椭圆点集；颜色和可见性由 _update_selection() 控制。
func _build_rings() -> void:
	# ⚠ 三个坑：
	#   ① 不能用负 z_index 藏到立绘下面 —— z_index 是全局排序，负值会连战斗背景一起盖住（背景 z=0）；
	#   ② 也不能画在立绘**上面** —— 那圈线会横穿角色身体，看起来像"穿模"；
	#   ③ 纯排在 Sprite 之前又会被长裙/大触手整圈盖掉。
	# 正确做法：靠**树的顺序**排到 Sprite 前面（同级按顺序绘制，不碰 z_index），
	# 再把整圈往下挪 RING_DROP 像素 —— 角色遮住后半圈，脚边一圈露出来，才像"地上的光圈"。
	_ring_glow = _make_ring(RING_RX * 1.05, RING_RY * 1.12, 11.0)
	add_child(_ring_glow)
	_ring_core = _make_ring(RING_RX, RING_RY, 3.0)
	add_child(_ring_core)
	# 索引 0 留给 Shadow（场景里预置）；两圈排在它后面、Sprite 前面。
	move_child(_ring_glow, 1)
	move_child(_ring_core, 2)
	_ring_glow.position.y = RING_DROP
	_ring_core.position.y = RING_DROP


## 生成一圈椭圆 Line2D（closed = 首尾自动闭合）。
func _make_ring(rx: float, ry: float, width: float) -> Line2D:
	var ring := Line2D.new()
	ring.width = width
	ring.antialiased = true
	ring.closed = true
	ring.joint_mode = Line2D.LINE_JOINT_ROUND
	ring.begin_cap_mode = Line2D.LINE_CAP_ROUND
	ring.end_cap_mode = Line2D.LINE_CAP_ROUND
	var points := PackedVector2Array()
	var segments := 48
	for i in segments:
		var angle := TAU * float(i) / float(segments)
		points.append(Vector2(cos(angle) * rx, sin(angle) * ry))
	ring.points = points
	ring.visible = false
	return ring


## 开关光环并染色。show_it=false 时两圈一起隐藏。
func _set_ring(color: Color, show_it: bool) -> void:
	for ring in [_ring_glow, _ring_core]:
		if ring == null:
			continue
		ring.visible = show_it
	if not show_it:
		return
	_ring_core.default_color = Color(color.r, color.g, color.b, 0.95)
	_ring_glow.default_color = Color(color.r, color.g, color.b, 0.28)


## 把自身及所有 Control 子节点设成不接收鼠标事件（递归，因为血条内部还嵌着 ProgressBar/Label）。
## 用 MOUSE_FILTER_IGNORE 而非 PASS：完全穿透，连 hover 都不产生。只改场景实例属性，不污染 .tscn。
func _ignore_mouse(node: Node) -> void:
	if node is Control:
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in node.get_children():
		_ignore_mouse(child)


## 由 Battle 在 add_child() 之后调用：写入数值并刷新外观。参数 p_ 前缀避免与成员同名歧义。
## 副作用：覆写 stats/is_player/HP/MP/alive/defending，**清空 cooldowns**，再 _refresh_visuals()。
## HP 取 maxf(1.0, health) 防一开局判死；MP 取 maxf(0.0, mana) 允许没法力；这是唯一重置 alive 的地方。
func setup(p_stats: UnitStats, p_is_player: bool) -> void:
	stats = p_stats
	is_player = p_is_player
	max_hp = maxf(1.0, stats.health)
	hp = max_hp
	max_mp = maxf(0.0, stats.mana)
	mp = max_mp
	alive = true
	defending = false
	cooldowns.clear()
	statuses.clear()
	_refresh_visuals()


## 按 stats/is_player/当前 HP·MP 刷界面：贴图、名字、翻转、两条 bar 的染色与可见性。
## **锚点约定：本地坐标 (0,0) = 脚底**（Sprite2D 用 offset 把贴图整体上移半个高度）——
## 单位节点摆在哪，脚就踩在哪；名字 / 血条 / 蓝条 / 头顶箭头全部按"头顶"（-贴图高 × 缩放）排，
## 所以换任何尺寸的立绘都不用再手调偏移。
## 敌人整体水平翻转（正对镜头，不用两套素材）；血条用 self_modulate 染色（只影响自己不影响子节点），
## 我方白、敌方偏红/偏蓝；max_mp==0 的单位整条蓝条隐藏。只在 setup() 调一次。
## 建立 8 方位帧动画（只在 stats.anim_dir 非空时）。战斗里朝向固定：
## 我方站左边、面朝右，敌方面朝左，所以只播 "right"/"left" 这一列。
## 副作用：往本节点加一个 CharAnim2D 子节点，并把 sprite.texture 换成交给它的条带图。
## 没有动画资源时静默返回（留 _anim = null），调用方继续用静态贴图。
func _setup_anim() -> void:
	if _anim != null:
		return
	if stats == null or stats.anim_dir.is_empty():
		return
	var anim := CharAnim2D.new()
	anim.name = "CharAnim"
	add_child(anim)
	if not anim.setup(sprite, stats.anim_dir):
		anim.queue_free()
		return
	_anim = anim
	_anim.frame_changed.connect(_on_anim_frame)
	# 朝向由 BATTLE_FACING_* 决定（45° 斜侧，见常量处的说明）。
	_anim.play("idle", BATTLE_FACING_PLAYER if is_player else BATTLE_FACING_ENEMY)


## 建实时 3D 头像（只在 stats.model_glb 非空时）。优先级高于帧动画和静态贴图。
## 战斗里朝向固定：3D 模型和帧动画共用同一组斜向朝向常量。
func _setup_model3d() -> void:
	if _model3d != null:
		return
	if stats == null or stats.model_glb.is_empty():
		return
	var av := Model3DAvatar.new()
	av.name = "Model3D"
	add_child(av)
	if not av.setup(stats.model_glb, UNIT_DISPLAY_HEIGHT, true):
		av.queue_free()
		return
	_model3d = av
	_model3d.set_weapon(stats.weapon_visual if is_player else null)
	sprite.visible = false
	# 保持与 2D 帧动画一致：我方朝左上，敌方朝右下。
	_model3d.face_dir(BATTLE_FACING_PLAYER if is_player else BATTLE_FACING_ENEMY)
	_model3d.play("idle", 0.0)


## 帧动画换帧钩子：以前用来同步"描边"的 region；高亮改成脚下光环后不再需要，
## 保留空实现只因为 AnimationPlayer/帧动画那边可能连着它（删掉连线会静默断）。
func _on_anim_frame() -> void:
	pass


func _refresh_visuals() -> void:
	# 优先级：实时 3D 模型 > 8 方位帧动画 > 静态立绘
	_setup_model3d()
	if _model3d == null:
		_setup_anim()
		if _anim == null:
			sprite.texture = stats.icon
	name_label.text = stats.name
	# 脚锚定：Sprite2D 居中绘制贴图，offset 上移半个高度后底边正好落在 y=0
	var tex_h := 0.0
	var head := 0.0
	if _model3d != null:
		# 3D 头像自己按 UNIT_DISPLAY_HEIGHT 算缩放，这里只用它来排头顶 UI。
		tex_h = UNIT_DISPLAY_HEIGHT
		head = -tex_h
	else:
		if sprite.texture != null:
			tex_h = float(sprite.texture.get_height())
			# 按贴图高度反推缩放：不管立绘是 150px（老的蛋形头像）还是 320px（新立绘），
			# 显示出来都是 UNIT_DISPLAY_HEIGHT 这么高。这样提高素材分辨率只会更清晰，
			# 不会让单位变大，也不会影响还没换图的敌人。
			var s := UNIT_DISPLAY_HEIGHT / tex_h
			sprite.scale = Vector2(s, s)
			_base_scale = sprite.scale          # play_cast() 涨大后要回到这个基准
			sprite.offset = Vector2(0.0, -tex_h * 0.5)
		head = -tex_h * sprite.scale.y          # 头顶（负值 = 向上）
	body_center_offset = head * 0.5              # 身体中心（飘字/弹道落点都瞄这里）
	# 头顶信息块：从头顶往上依次是 蓝条 / 血条 / 名字，整块都在角色头顶之上。
	# 我方整体再上移 NAME_LIFT_PLAYER（怪物的位置不变）。
	var lift := NAME_LIFT_PLAYER if is_player else 0.0
	var mp_bottom := head - PLATE_HEAD_GAP - lift
	var mp_top := mp_bottom - PLATE_BAR_H
	var hp_bottom := mp_top                    # 蓝条顶 = 血条底 -> 中间没有缝
	var hp_top := hp_bottom - PLATE_BAR_H
	var name_bottom := hp_top - PLATE_NAME_BAR_GAP
	var name_top := name_bottom - PLATE_NAME_H
	mana_bar.offset_top = mp_top
	mana_bar.offset_bottom = mp_bottom
	health_bar.offset_top = hp_top
	health_bar.offset_bottom = hp_bottom
	name_label.offset_top = name_top
	name_label.offset_bottom = name_bottom
	# 静态立绘（没有 8 方位帧动画、也没有 3D 模型）才补程序化空闲动作。
	# 有帧动画的单位自带 idle，再叠一层会打架。
	if _anim == null and _model3d == null:
		_start_idle_motion()
	# 名字紧贴血条顶边（标签框比文字高，居中的话会空出一截，看着像"名字飘太高"）。
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	name_label.size.y = PLATE_NAME_H
	_refresh_name_color()
	target_arrow.position.y = name_top - 26.0       # 目标箭头浮在信息块上方
	_arrow_base_y = target_arrow.position.y
	# 选中光环就在原点（= 脚下）
	selection.position = Vector2.ZERO
	selection.scale = Vector2.ONE * BATTLE_VISUAL_SCALE
	var ground_shadow := get_node("Shadow") as Polygon2D
	ground_shadow.scale = Vector2.ONE * BATTLE_VISUAL_SCALE
	ground_shadow.color = Color(0.10, 0.075, 0.065, 0.20)
	# 点击判定挪到身体中段（Area2D 在脚底，光靠半径盖不住上半身）
	click_area.position.y = body_center_offset
	click_area.scale = Vector2.ONE * BATTLE_VISUAL_SCALE
	# 敌人翻转：flip_h 只影响绘制，不改坐标/碰撞，点击区域不受影响。
	# 有帧动画时朝向已经画在图里了（我方朝左、敌朝右），再 flip 会镜像回去，所以跳过。
	sprite.flip_h = (not is_player) and _anim == null
	# 敌方血条染红（直接换 fill 颜色，不只是 modulate 一下）；我方保持绿色。
	health_bar.self_modulate = Color(1, 1, 1)
	if not is_player:
		health_bar.set_fill_color(ENEMY_HP_COLOR)
	# 蓝条只给我方看：敌人不显示蓝条（也省得一排空槽）。
	mana_bar.visible = is_player and max_mp > 0.0
	mana_bar.self_modulate = Color(1, 1, 1)
	_refresh_hp()
	_refresh_mana()


## 敌人血条颜色（红）。只在 _apply_layout() 里用一次，改这里就能统一换色。
const ENEMY_HP_COLOR := Color(0.86, 0.24, 0.22, 1)

## 身体中心（世界坐标）：立绘脚在原点，往上抬半个身高。弹道落点、命中爆炸、飘字都用它。
func body_center() -> Vector2:
	return global_position + Vector2(0.0, body_center_offset)


# ── 数值（伤害/暴击/格挡/速度的唯一口径）──
# 所有随机判定都走 Global.get_chance_success()，它会推进全局随机数序列——
# 也就是说"多打一次暴击判定"会间接影响之后掉落/抽卡的随机结果（不是 bug，但调平衡时会困惑）。

## 普攻伤害：返回 maxf(1.0, stats.damage)（1 点下限，防"打不动"死局）。纯函数，不碰随机数。
## 现状没有攻防差/随机浮动/等级修正；想做浮动就改成 stats.damage * randf_range(0.9, 1.1)。
func roll_damage() -> float:
	return maxf(1.0, stats.damage)


## 是否暴击。crit_bonus 为技能加成（普攻用默认 0.0）。副作用：**推进全局随机数序列**。
## 公式：10% + stats.crit_rate/100 + crit_bonus。注意 crit_rate 是百分数、这里按小数算（0.10 = 10%）。
func roll_crit(crit_bonus := 0.0) -> bool:
	return Global.get_chance_success(0.10 + stats.crit_rate / 100.0 + status_value("crit_rate") / 100.0 + crit_bonus)


## 本回合缓存的出手速度，由 Battle._next_round() 排序前调 roll_turn_speed() 写入。
## ⚠ 必须缓存：排序会反复调比较函数，若在里面调 turn_speed() 每次取新随机数，
##   "a>b"与"b>a"可能同时成立，引擎报 "bad comparison function" 且排序结果未定义。
var round_speed := 0.0


## 本次出手速度 = stats.speed + randf_range(-4.0, 4.0)（乱敏 ±4）。副作用：**推进随机数序列**。
## speed 默认 300（与像素/秒复用同字段），这里只当大小比较用；不做扰动则同速单位顺序永远固定。
func turn_speed() -> float:
	return float(stats.speed) + randf_range(-4.0, 4.0)


## 每回合开始 roll 一次并缓存，返回 roll 出的值（方便调试打印）。副作用：写 round_speed、推进随机数。
func roll_turn_speed() -> float:
	round_speed = turn_speed()
	return round_speed


## 防御减伤曲线的常数：减伤率 = 防御 / (防御 + DEF_SOFT)，防越高收益越平缓。
## 梦幻西游里这条是 [攻 − 防×K2]×K3 的攻防差公式；我们的数值小（攻 9 / 防 18），
## 直接相减会变成"全部打 1 血"，所以换成等价意图的百分比曲线。
const DEF_SOFT := 60.0


## 扣血（战斗里唯一的伤害入口，普攻和技能最后都走这里）。
## 公式：最终伤害 = max(1, 伤害 × (1 − 防护/(防护+60)) − 格挡值)（防御姿态再 ×0.5）
##   · 参数 magic = true 时防护用 `spell_defense`（法防），否则用 `defense`（物理防御）
##   · 格挡值：**最后一步固定减法**（不乘任何系数），所以对高频低伤特别有效
## 返回值：实际扣掉的血量（Battle 用它飘伤害数字，避免显示未减伤的值）。
## 副作用：改 hp、_refresh_hp()；归零调 _die()。已死单位直接 return 0（防鞭尸/重复 _die()）。
func take_damage(amount: float, magic := false) -> float:
	if not alive:
		return 0.0
	var guard := float(stats.spell_defense) if magic else float(stats.defense)
	var def_ratio := guard / (guard + DEF_SOFT)
	var final := maxf(1.0, amount * (1.0 - def_ratio))
	final = maxf(1.0, final - float(stats.block_value))
	if defending:
		final = maxf(1.0, final * 0.5)
	hp = maxf(0.0, hp - final)
	_refresh_hp()
	if hp <= 0.0:
		_die()
	return final


## 回血（治疗技能未实现，目前无人调用）。用 minf(max_hp, ...) 夹上限；死人不能靠回血复活。
## 注意传负数会变成扣血且不触发 _die()，别这么用。
func heal(amount: float) -> void:
	if not alive:
		return
	hp = minf(max_hp, hp + amount)
	_refresh_hp()


## 刷新血条并广播 hp_changed。update_bar 第二个参数是**原始数值**（血条内部 str()），不是比例。
## 不会除零：max_hp 在 setup() 里保证 >= 1。
func _refresh_hp() -> void:
	health_bar.update_bar(hp / max_hp, hp)
	hp_changed.emit(self)


## 刷新蓝条并广播 mp_changed。max_mp==0 时不更新（避免 0/0 的 NaN 写进 ProgressBar），
## 但 **mp_changed 任何情况都发**——指令菜单靠它刷新"蓝不够/冷却 N"。
func _refresh_mana() -> void:
	if max_mp > 0.0:
		mana_bar.update_bar(mp / max_mp, mp)
	mp_changed.emit(self)


## 死亡处理（hp 归零时由 take_damage() 调，不再校验 alive）。一次性、不可逆：alive/defending=false、
## 取消选中与高亮、关点选、名字变暗，然后**原地倒地**（绕脚底旋转 + 下沉 + 压暗成尸体）。
## emit died 在最后发，接收方看到的是最终状态。
## 重要：**不 queue_free()**——Battle 的列表/顺序条/跨 await 引用还指着它，统一由 _clear_units() 释放。
func _die() -> void:
	alive = false
	defending = false
	set_selected(false)
	set_targetable(false)
	set_focused(false)
	click_area.input_pickable = false
	name_label.modulate = Color(1, 1, 1, 0.35)
	# 正在播的受击后仰/空闲呼吸先停：它们也在改 sprite 的 rotation / position.y，会和退场抢
	if _hit_tween != null and _hit_tween.is_valid():
		_hit_tween.kill()
	if _idle_tween != null and _idle_tween.is_valid():
		_idle_tween.kill()

	# 3D 模型如果配了 dead 动作就先播它（有就播，没有拉倒）
	if _model3d != null:
		_model3d.play_once("dead")
	# 两种死法：
	#   怪物 —— 不倒、不留尸体，直接淡出（战场干净，也不挡后面的人）
	#   人物 —— 快速隐去身体，由 Battle 在原地补一团幽火（见 _on_unit_died）
	# 两者都**不 queue_free**：Battle 的列表/顺序条还指着这个节点，
	# 统一交给战斗结束时的 _clear_units() 释放。
	var fade_time := DEATH_FADE_PLAYER if is_player else DEATH_FADE_ENEMY
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, fade_time)
	tween.tween_callback(func() -> void: visible = false)
	# 注意：died 立刻发 —— 顺序条/判定要马上把这个人当死人看，动画只是表现。
	died.emit(self)


# ── 技能：蓝量 / 冷却 / 数值 ──
# 本脚本管"蓝够不够、在不在冷却、数值怎么算"；何时扣蓝/进冷却/打谁由 Battle 决定。
# 冷却用**回合数**而非引擎 Timer：回合制逻辑时间与真实时间无关，暂停/加速/切场景都不受影响。

## 是否有技能表（不看蓝量与冷却）。CommandMenu 用它决定"法术"按钮 disabled。
## 语义边界：有技能 ≠ 现在放得出来，能不能放看 can_use_skill()。
func has_skills() -> bool:
	return not available_skills.is_empty()


## 现在能不能放：活着 + 蓝够（**严格小于**才不够，刚好等于可以）+ 不在冷却 + **没被封法术**。
func can_use_skill(skill: SkillData) -> bool:
	if skill == null or not alive:
		return false
	if has_status("silence"):
		return false
	if mp < skill.mana_cost:
		return false
	if cooldown_left(skill) > 0:
		return false
	return true


## 剩余冷却回合数；0 表示可用（不存在的键、skill 为 null 都返回 0）。
## 用 skill.id 做键：Resource 作键按引用比较，同技能不同实例会被当不同技能。
func cooldown_left(skill: SkillData) -> int:
	if skill == null or not cooldowns.has(skill.id):
		return 0
	return cooldowns[skill.id]


## 扣蓝：mp = maxf(0.0, mp - amount)，然后 _refresh_mana()（刷蓝条 + emit mp_changed）。
## 调用方先用 can_use_skill 校验，正常不会"蓝不够还硬扣"。
func spend_mana(amount: float) -> void:
	mp = maxf(0.0, mp - amount)
	_refresh_mana()


## 让技能进冷却：cooldowns[id] = maxi(剩余, skill.cooldown)（取大值）。
## 取 max 而不是直接赋值：防止同一回合内把别人加的长冷却改短；重复施放同一技能也不会叠加。
## 副作用：**额外 emit mp_changed**——蓝没变但冷却变了，借这个信号让菜单刷新"冷却 N"文字。
func start_cooldown(skill: SkillData) -> void:
	if skill == null:
		return
	var left := cooldown_left(skill)
	cooldowns[skill.id] = maxi(left, skill.cooldown)
	mp_changed.emit(self)          # 顺便刷新技能菜单的显示


## 每回合开始调一次：所有冷却 -1，减到 <=0 的键**删除**。
## 为什么要两趟（先记 expired 再 erase）：Godot 字典不允许边遍历 keys() 边 erase。
## is_empty() 提前返回只是小优化（大多数单位大多数时候没有冷却）。
func tick_cooldowns() -> void:
	if cooldowns.is_empty():
		return
	var expired: Array[String] = []
	# 显式写 `for key: String in cooldowns.keys()` 是为了让 key 有明确类型（keys() 返回弱类型 Array）。
	for key: String in cooldowns.keys():
		cooldowns[key] = cooldowns[key] - 1
		if cooldowns[key] <= 0:
			expired.append(key)
	for key in expired:
		cooldowns.erase(key)


## 技能伤害 = maxf(1.0, 倍率 × stats.damage/法伤)（固定伤害则取 flat_damage），再叠状态加成：
## `damage_pct` / `damage_spell` 按百分比放大，`spell_damage` 按点数加。纯函数，不碰随机数。
## 参数 hit：第几击（0 起）。技能配了 hit_power 时用它，否则一律用 power。
func skill_damage(skill: SkillData, hit := 0) -> float:
	if skill == null:
		return roll_damage()
	# 固定伤害（缥缈剑指 / 药雾弥漫）：吃固定值，不随攻击力/法伤成长。
	var raw := stats.damage
	if skill.damage_type == SkillData.DamageType.MAGIC:
		raw = stats.spell_damage
	var power := skill.power
	if hit >= 0 and hit < skill.hit_power.size():
		power = skill.hit_power[hit]
	var base := skill.flat_damage if skill.fixed_damage else power * raw
	base = maxf(1.0, base)
	base *= 1.0 + (status_value("damage_pct") + status_value("damage_spell")) / 100.0
	base += status_value("spell_damage")
	return base


## 暴击倍率：基础 ×1.5，再加 `crit_damage_bonus` 状态（百分数，15 = +15%）。
func crit_multiplier() -> float:
	return 1.5 + status_value("crit_damage_bonus") / 100.0


# ── 状态（buff / 封印 / 封法术 / 持续回血）──
# 每条：{stat: String, value: float, turns: int, per_turn: float}
#   · 数值加成：damage_pct / damage_spell（百分比）、spell_damage（点数）、crit_rate（百分点）、
#     crit_damage_bonus（百分点）；
#   · 控制：seal（被封印，下次行动跳过并消耗）、silence（不能放技能）；
#   · 持续回血：hot（per_turn 是每回合回复量）。
var statuses: Array[Dictionary] = []


## 加一条状态（同种会合并：数值/每回合回复相加，回合取更长的那个）。
func add_status(stat: String, value: float, turns: int, per_turn := 0.0) -> void:
	if stat.is_empty() or turns <= 0:
		return
	for s in statuses:
		if s["stat"] == stat:
			s["value"] = float(s["value"]) + value
			s["per_turn"] = float(s["per_turn"]) + per_turn
			s["turns"] = maxi(int(s["turns"]), turns)
			return
	statuses.append({"stat": stat, "value": value, "turns": turns, "per_turn": per_turn})


## 某种状态的数值合计（没有就 0）。只读，不碰回合数。
func status_value(stat: String) -> float:
	var total := 0.0
	for s in statuses:
		if s["stat"] == stat:
			total += float(s["value"])
	return total


## 是否有某种状态。
func has_status(stat: String) -> bool:
	for s in statuses:
		if s["stat"] == stat:
			return true
	return false


## 清空全部状态（setup() 重置时用）。
func clear_statuses() -> void:
	statuses.clear()


## 回合开始：取消防御 → **判断是否被封印** → 结算持续回血 → 所有状态 -1 回合、到期的移除。
## 返回值：true = 这个单位被封印了，本次行动应该跳过（封印状态已被消耗）。
func begin_turn() -> bool:
	set_defending(false)
	var sealed := has_status("seal")
	# 持续回血（hot）：先把这一回合的回血结算掉，再递减回合。
	if alive:
		for s in statuses:
			var per := float(s["per_turn"])
			if per > 0.0:
				heal(per)
	var kept: Array[Dictionary] = []
	for s in statuses:
		s["turns"] = int(s["turns"]) - 1
		if int(s["turns"]) > 0:
			kept.append(s)
	statuses = kept
	return sealed


## 技能是否暴击：roll_crit(skill.crit_bonus)，skill 为 null 时加成按 0。副作用：推进随机数序列。
func skill_crit(skill: SkillData) -> bool:
	return roll_crit(skill.crit_bonus if skill != null else 0.0)


# ── 选中 / 目标高亮 ──
# 只做"标记 + 重算颜色"，不动任何战斗数值。

## 设置"当前行动者"高亮：写 _selected，重算光环。不改战斗数据。
## 谁用：Battle._begin_turn() 点亮、_finish_turn()/_finish_battle() 熄灭。
func set_selected(value: bool) -> void:
	_selected = value
	_update_selection()


## 设置"可被选为目标"光环。只管视觉，不影响点击能不能被接收——
## 真正决定"点了有没有用"的是 Battle 的 state 与 _targets.has(unit)。
func set_targetable(value: bool) -> void:
	_targetable = value
	_update_selection()


## 把键盘目标光标放到本单位：显示光环 + 头顶箭头并开启每帧浮动。死人一律不显示（尸体不顶箭头）。
## 副作用：写 _focused、开关 %TargetArrow 的 visible 与 _process、重算光环颜色。
func set_focused(value: bool) -> void:
	_focused = value
	var show_it := value and alive
	target_arrow.visible = show_it
	if not show_it:
		target_arrow.position.y = _arrow_base_y
	_update_selection()
	_refresh_name_color()          # 被选为攻击目标 -> 名字变红


## 名字颜色的唯一出口：被选为攻击目标（键盘/鼠标光标停在它身上）时红色，否则绿色。
## 顺手补一圈黑描边 —— 立绘不管是深色还是浅色，名字都看得清。
func _refresh_name_color() -> void:
	name_label.add_theme_color_override("font_color",
			NAME_COLOR_TARGETED if (_focused and alive) else NAME_COLOR_NORMAL)
	name_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	name_label.add_theme_constant_override("outline_size", 4)


## 每帧：头顶箭头正弦浮动 + 脚下光环呼吸（只在有高亮/聚焦时运行）。
## 用 _process 而非 Tween：Tween 要管换目标时的 kill 与重复创建，开关 _process 更简单也不易出错。
func _process(_delta: float) -> void:
	var seconds := float(Time.get_ticks_msec()) / 1000.0
	target_arrow.position.y = _arrow_base_y + sin(seconds * 3.85) * 7.0
	if _ring_core != null and _ring_core.visible:
		# 呼吸：半径 ±4%、亮度 0.72~1.0 之间来回，像"心跳"而不是闪光灯。
		var pulse := 0.5 + 0.5 * sin(seconds * 3.2)
		var twist := 1.0 + pulse * 0.04
		_ring_core.scale = Vector2(twist, twist)
		_ring_glow.scale = Vector2(1.0 + pulse * 0.07, 1.0 + pulse * 0.07)
		_ring_core.modulate.a = 0.72 + pulse * 0.28
		_ring_glow.modulate.a = 0.45 + pulse * 0.35


## 按三个标记重算高亮（唯一"高亮真相"出口）：脚下扁圆 + 光环。
## 优先级：键盘/悬停的红色目标 > _selected 暖金 > 悬停白。
## ⚠ `_targetable` 只表示"能被点"，不再直接显示红圈：
##   否则进入选目标时，所有敌人会同时被标红（之前就是这样）。
func _update_selection() -> void:
	var aiming := _targetable and (_focused or _hovered)
	var show_it := alive and (aiming or _selected or _hovered)
	selection.visible = show_it
	var ring_color := RING_HOVER
	if aiming:
		selection.color = TARGET_COLOR
		ring_color = RING_TARGET
	elif _selected:
		selection.color = SELECT_COLOR
		ring_color = RING_SELECT
	else:
		selection.color = HOVER_COLOR
	_set_ring(ring_color, show_it)
	# 只有需要动的东西才开 _process（箭头浮动 / 光环呼吸）。
	set_process(show_it or target_arrow.visible)


## 设置/取消防御姿态：true 时 Sprite 渐变淡蓝，false 时回纯白；到期由 Battle._begin_turn() 取消。
## 坑：这里的 modulate tween 与 play_hit()/play_cast() 收尾互相覆盖，故 play_* 收尾写 `DEFEND_TINT if defending else WHITE`。
func set_defending(value: bool) -> void:
	defending = value
	var body := _visual_body()
	if value:
		var tween := create_tween()
		tween.tween_property(body, "modulate", DEFEND_TINT, 0.15)
	else:
		body.modulate = Color.WHITE


## 本回合的"取消防御 + 状态结算"在文件上半部分的 begin_turn() 里（和 statuses 放一起）。


# ── 表现（演出）—— 都可以换成 AnimationPlayer ──
# 所有 play_* 都是协程，返回时机就是"演出播完"，Battle 靠 await 它们保证节奏顺序。

## 普攻站位：停在目标**前方**多远（靠自己这一侧）。
## 105 时两个人几乎贴在一起，看着像"撞上去"；180 ≈ 一个半身位，留出挥砍的间隔。
const ATTACK_STAND_OFF := 180.0
## 冲刺/归位速度（像素/秒）：按距离算时长，远近都跟手。
const ATTACK_DASH_SPEED := 1900.0
const ATTACK_DASH_MIN := 0.10
const ATTACK_DASH_MAX := 0.26
## 招式动作最长等多久（帧动画问得到就按它，问不到用这个兜底）。
const ATTACK_SWING_MAX := 0.5
## 冲进敌阵时临时抬高层级。
## 为什么需要：敌我单位是同一个父节点下的兄弟节点、按生成顺序绘制 —— 我方先生成、
## 敌人后生成，所以人一冲进敌方阵地就会被敌人的立绘盖住。抬高层级最省事，
## 不用改整体 y_sort（那会连带影响特效、血条、名字牌的层级）。
const ATTACK_Z := 50

## 冲出去之前记下的层级，归位时还原。
var _z_before := 0

# ── 死亡：原地倒地成尸体 ──
## 倒地动画时长（秒）。
const DEATH_FADE_ENEMY := 0.45
## 人物淡出时长（秒）：比怪物快，因为马上会有一团幽火顶上来。
const DEATH_FADE_PLAYER := 0.16
## 旧倒地参数现仅 3D 模型无 dead 动作时兜底用，见 _die()。
const DEATH_FALL_TIME := 0.45
## 倒地角度（度）：不到 90，留一点倾斜更像"软倒"而不是"被推倒"。
const DEATH_FALL_ANGLE := 82.0
## 倒地后身体再往下沉多少像素。
const DEATH_SINK := 10.0
## 尸体染色：压暗 + 去血色的灰紫。留 alpha=1，尸体要看得见。
const DEATH_TINT := Color(0.55, 0.52, 0.60, 1.0)

# ── 程序化动画（给静态立绘的单位用：怪物没有 attack/idle/cast 序列帧）──
## 空闲呼吸：上下浮动的像素与一个来回的时长。
## 只动 sprite.position.y，不碰 scale —— play_cast()/attack_swing() 都在 tween scale，
## 两边抢同一个属性会互相打断。
const IDLE_BOB := 4.0
## 受击后仰：歪多少度、到位/回正各多久、保持期间每段抖动多长、抖幅多少度。
const HIT_TILT := 6.0
const HIT_LEAN_TIME := 0.10
const HIT_BACK_TIME := 0.14
const HIT_SHAKE_STEP := 0.07
const HIT_SHAKE_DEG := 1.6
const IDLE_PERIOD := 1.7
## 程序化出招：蓄力后仰 → 突刺前倾 → 回正。数值是相对 _base_scale 的倍增。
const SWING_ANTIC_X := 0.92
const SWING_ANTIC_Y := 1.06
const SWING_STRIKE_X := 1.12
const SWING_STRIKE_Y := 0.92
const SWING_TILT := 9.0            ## 倾斜角度（度）

## 空闲呼吸的循环 tween（换图/重建时先 kill 掉旧的）。
var _idle_tween: Tween
## 当前正在播的受击后仰 tween。
## 多段技能每一击都会重新调 play_hit()，不 kill 旧的就会几个 tween 同时抢 rotation，
## 表现成"僵住不动、最后抽一下"。
var _hit_tween: Tween


## 普攻第一段：斜着走到目标**同一横线**的侧面站位（await 到到位）。
## 落点 = 目标的 y（完全对齐）+ x 方向让出 ATTACK_STAND_OFF 的距离，且仍在**自己这一侧**
## （我方 x 恒大于敌方，所以永远是"站到目标右手边"）—— 斜向切入，不是横着平移。
## 以前是"朝目标冲 80px 就退"，看不出谁打谁；走到面前才有交手感。
## 坐标换算用 global_position → 局部偏移：仅在本单位与父节点无旋转/缩放时等价
## （本项目舞台是纯平移，安全）。目标在演出中被释放则直接返回，调用方当成演出已结束。
func attack_approach(target: BattleUnit) -> void:
	if not is_instance_valid(target):
		return
	# 自己在目标的左边还是右边（我方在右、敌方在左，不会歧义）
	var dx := global_position.x - target.global_position.x
	var side_x := 1.0 if dx >= 0.0 else -1.0
	var to_global := Vector2(target.global_position.x + side_x * ATTACK_STAND_OFF,
			target.global_position.y)
	var to := position + (to_global - global_position)
	# 抬到最上层，避免被敌方立绘盖住
	_z_before = z_index
	z_index = ATTACK_Z
	var dist := (to - position).length()
	var t := clampf(dist / ATTACK_DASH_SPEED, ATTACK_DASH_MIN, ATTACK_DASH_MAX)
	var tween := create_tween()
	tween.tween_property(self, "position", to, t)
	if _model3d != null:
		_model3d.face_from_vector(to - position)
		_model3d.play("run")
	await tween.finished
	if _model3d != null:
		_model3d.face_from_vector(target.global_position - global_position)
		_model3d.play("idle")


## 普攻第二段：出招（播 attack 动作并等它播完）。近战门派技能不需要它 —— 那些有自己的特效。
func attack_swing(on_impact: Callable = Callable()) -> void:
	if _model3d != null:
		var duration := _model3d.play_once("attack", 0.04)
		if duration > 0.0:
			await get_tree().create_timer(duration * 0.44).timeout
			if on_impact.is_valid():
				on_impact.call()
			await get_tree().create_timer(duration * 0.56).timeout
		else:
			if on_impact.is_valid():
				on_impact.call()
			await _procedural_swing()
		return
	if on_impact.is_valid():
		on_impact.call()
	if _anim != null:
		_anim.play_once("attack")
	# 有帧动画：等它播完（能问就问到播完为止，加 ATTACK_SWING_MAX 上限防死等）。
	if _anim != null:
		var waited := 0.0
		while _anim.is_playing_once() and waited < ATTACK_SWING_MAX:
			await get_tree().process_frame
			waited += get_process_delta_time()
		return
	# 没有帧动画（怪物 = 静态立绘）：用缩放 + 倾斜演一套"蓄力→突刺→回正"。
	await _procedural_swing()


## 程序化反馈作用于当前可见的形象；3D 模式的原 Sprite 已隐藏。
func _visual_body() -> Node2D:
	return _model3d if _model3d != null else sprite


## 缺少攻击剪辑时，蓄力后仰 → 突刺前倾 → 回正。
func _procedural_swing() -> void:
	var body := _visual_body()
	if body == null:
		return
	var rest_scale := Vector2.ONE if _model3d != null else _base_scale
	var sx := rest_scale.x
	var sy := rest_scale.y
	var tween := create_tween()
	# 蓄力：横向收、纵向拉，身体微后仰
	tween.tween_property(body, "scale", Vector2(sx * SWING_ANTIC_X, sy * SWING_ANTIC_Y), 0.08)
	tween.parallel().tween_property(body, "rotation", deg_to_rad(-SWING_TILT), 0.08)
	# 突刺：横向拉、纵向压，向前倾
	tween.tween_property(body, "scale", Vector2(sx * SWING_STRIKE_X, sy * SWING_STRIKE_Y), 0.10)
	tween.parallel().tween_property(body, "rotation", deg_to_rad(SWING_TILT), 0.10)
	# 回正
	tween.tween_property(body, "scale", rest_scale, 0.14)
	tween.parallel().tween_property(body, "rotation", 0.0, 0.14)
	await tween.finished


## 空闲呼吸：上下浮动，无限循环。**每只怪周期与相位都不同** ——
## 同一批出场的怪如果节奏一致，会像广播体操一样整齐上下，很出戏。
## 只动 position.y —— scale 留给 play_cast()/attack_swing()，rotation 留给攻击倾斜。
func _start_idle_motion() -> void:
	if sprite == null:
		return
	if _idle_tween != null and _idle_tween.is_valid():
		_idle_tween.kill()
	# 周期各差 ±15%，相位随机落在 0~1 之间（0 = 在最低点、1 = 在最高点）
	var period := IDLE_PERIOD * randf_range(0.85, 1.18)
	var phase := randf()
	sprite.position.y = -IDLE_BOB * phase
	# 先把"本轮剩下的上升段"走完（只走这一次，不进循环），之后才进标准循环。
	# 这样起始位置和循环起点是对得上的，不会出现第一次跳动。
	var lead := create_tween()
	lead.tween_property(sprite, "position:y", -IDLE_BOB, period * 0.5 * (1.0 - phase)) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	lead.finished.connect(_loop_idle.bind(period))


## 空闲循环本体：上浮半周期 → 下落半周期，无限循环。period 由 _start_idle_motion 传进来。
func _loop_idle(period: float) -> void:
	if sprite == null or not is_inside_tree():
		return
	_idle_tween = create_tween().set_loops()
	_idle_tween.tween_property(sprite, "position:y", 0.0, period * 0.5) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_idle_tween.tween_property(sprite, "position:y", -IDLE_BOB, period * 0.5) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


## 普攻第三段：退回原位（await 到回到站位），并把攻击时抬高的层级还原。
## 参数 from_position：开打前记下的局部位置（调用方在 attack_approach 之前存）。
func attack_return(from_position: Vector2) -> void:
	var dist := (position - from_position).length()
	var t := clampf(dist / ATTACK_DASH_SPEED, ATTACK_DASH_MIN, ATTACK_DASH_MAX)
	var tween := create_tween()
	if _model3d != null:
		_model3d.face_from_vector(from_position - position)
		_model3d.play("run")
	tween.tween_property(self, "position", from_position, t)
	await tween.finished
	if _model3d != null:
		_model3d.face_dir(BATTLE_FACING_PLAYER if is_player else BATTLE_FACING_ENEMY)
		_model3d.play("idle")
	z_index = _z_before


## 普攻完整收尾：出招 + 归位（普通攻击用；近战技能只调 attack_return）。
func attack_finish(from_position: Vector2) -> void:
	await attack_swing()
	await attack_return(from_position)


## 施法起手：微微涨大 + 染色（无素材时也有反馈），总时长约 0.14+0.16=0.3s。
## 先设回 WHITE 清掉上次残留的受击红/防御蓝；放大到 _base_scale*1.14 再回落；
## parallel() 让缩放与染色同时进行；收尾色 DEFEND_TINT if defending else WHITE（防御中施法保持淡蓝）。
func play_cast() -> void:
	var body := _visual_body()
	var rest_scale := Vector2.ONE if _model3d != null else _base_scale
	body.modulate = Color.WHITE
	# 帧动画：播放施法动作（一次性）。涨大/染色 tween 与它并行，不冲突。
	if _model3d != null:
		_model3d.play_once("cast")
	elif _anim != null:
		_anim.play_once("cast")
	var tween := create_tween()
	tween.tween_property(body, "scale", rest_scale * 1.14, 0.14)
	tween.parallel().tween_property(body, "modulate", CAST_TINT, 0.14)
	tween.tween_property(body, "scale", rest_scale, 0.16)
	tween.parallel().tween_property(body, "modulate", DEFEND_TINT if defending else Color.WHITE, 0.16)
	await tween.finished


## 受击表现：朝**远离攻击者**的方向后仰，然后**保持这个姿势**直到攻击/技能动画播完，
## 期间只有细微抖动，结束时回正。**不后退**（位移会和出手的冲刺、空闲呼吸打架）。
## 参数 from：攻击者的世界坐标；INF = 无从判断，退化成"向右后仰"。
## 参数 hold：后仰总共保持多久（秒）。多段技能传那一段动画的时长，普通攻击传一次挥击的时长。
## 只动 rotation + modulate —— 这两样空闲呼吸都不碰，所以不用停它。
func play_hit(from := Vector2.INF, hold := 0.35) -> void:
	var body := _visual_body()
	if body == null:
		return
	# 方向：从攻击者指向自己 = 受力方向的反面
	var dir := Vector2.RIGHT
	if from != Vector2.INF:
		var d := global_position - from
		if d.length() > 1.0:
			dir = d.normalized()
	# 远离攻击者的方向 = dir；Godot 2D 里**正角是顺时针**，
	# 所以"被打退的方向朝左"要让身子向左倒 → 负角。即 rotation = tilt 本身（tilt 带符号）。
	# 之前写成 -tilt，等于把人往攻击者那边倒，方向正好反了。
	var tilt := deg_to_rad(HIT_TILT) * (signf(dir.x) if absf(dir.x) > 0.05 else 1.0)
	var rest := Color.WHITE if not defending else DEFEND_TINT
	var lean := HIT_LEAN_TIME
	var back := HIT_BACK_TIME
	var shake := maxf(0.0, hold - lean - back)

	# 上一击的后仰还没播完就再来一记：先掐掉，否则两个 tween 抢 rotation 会互相抵消
	if _hit_tween != null and _hit_tween.is_valid():
		_hit_tween.kill()
	var tween := create_tween()
	_hit_tween = tween
	# ① 后仰到位（带回弹感）
	tween.tween_property(body, "rotation", tilt, lean) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(body, "modulate", HIT_TINT, minf(0.06, lean))
	# ② 保持后仰：在这段时间里做细微抖动（围绕后仰角小幅摇摆）
	var step := HIT_SHAKE_STEP
	var n := int(shake / step)
	for i in n:
		var wobble := deg_to_rad(randf_range(-HIT_SHAKE_DEG, HIT_SHAKE_DEG))
		tween.tween_property(body, "rotation", tilt + wobble, step)
	var left := shake - n * step
	if left > 0.01:
		tween.tween_interval(left)
	# ③ 回正 + 消红
	tween.tween_property(body, "rotation", 0.0, back) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(body, "modulate", rest, back)
	await tween.finished


# ── 点击 / 悬停 ──
# 三个回调都来自 %ClickArea；能收到鼠标事件的前提：Battle 开了 physics_object_picking，
# 且盖在单位上的 Control 都被设成 MOUSE_FILTER_IGNORE（见 _ignore_mouse）。

## %ClickArea 的 input_event 回调：把左键按下翻译成 clicked 信号。
## 过滤：活着 + 是 InputEventMouseButton + 左键 + pressed（不看抬起，否则一次点击发两次）。
## 不改状态、不 set_input_as_handled()，所以点击会继续传播。
func _on_click_area_input_event(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if not alive:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		clicked.emit(self)


## 鼠标移入：点亮悬停高亮 + 广播 hovered(true)；若是可选目标则把全局指针换成手型。
## 注意 _update_selection() 优先级 目标 > 选中 > 悬停，悬停到红圈上不会变回白圈。
func _on_mouse_entered() -> void:
	_hovered = true
	_update_selection()
	hovered.emit(self, true)
	if _targetable:
		Input.set_default_cursor_shape(Input.CURSOR_POINTING_HAND)


## 鼠标移出：取消悬停 + 广播 hovered(false) + 把全局默认指针还原成箭头。
## 坑：还原是无条件的（没判断当初是不是自己改成手型）；目前只有本类改指针，所以安全。
func _on_mouse_exited() -> void:
	_hovered = false
	_update_selection()
	hovered.emit(self, false)
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)
