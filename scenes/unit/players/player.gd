## ═══════════════════════════════════════════════════════════════════════════
## Player —— 玩家控制（Unit 的子类）：输入、位移、冲刺、动画、武器挂载、每波成长
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   场景模板是 scenes/unit/players/player_well_rounded.tscn（"均衡型"），
##   另外 4 个角色场景（brawler / bunny / crazy / knight）都是它的实例，只换 stats 与贴图。
##   本类是 Unit 的子类，血量、白闪、飘字转发这些公共流程都写在 unit.gd 里。
##   实例化链路：SelectionPanel 选人 → Arena._on_selection_panel_on_selection_completed()
##     → Global.get_selected_player()（读 Global.main_player_selected，**同时写入 Global.player**）
##     → Arena add_child(player) → player.add_weapon(Global.main_weapon_selected)。
##
## 本文件负责什么：
##   1. 每帧读输入、按 stats.speed 位移，并把位置 clamp 在竞技场矩形内
##   2. 冲刺：2.5 倍速 + 半透明 + 禁用自身碰撞 + 拉拖尾（Trail），冷却由 DashCooldownTimer 管
##   3. 动画（idle / move）与左右朝向（Visuals 的负 X 缩放）
##   4. add_weapon()：把 ItemWeapon 数据实例化成场上的 Weapon 节点并交给 WeaponContainer 摆位
##   5. 每波成长 update_player_new_wave() 与血量自然回复（HPRegenTimer）
##
## 数据流（谁读谁写）：
##   Global.game_paused ← 读（Spawner 每波结束置 true，Arena 开新波置 false）
##   Global.player      ← 由 Global.get_selected_player() 写；敌人 AI、武器、摄像机、飘字都靠它定位
##   stats（UnitStats） → 速度 / 血量 / 回血 / 每波成长值；update_player_new_wave() 会**就地修改**这份资源
##   current_weapons    ← ShopPanel 直接 filter/erase 它来卖武器、合成武器（本文件只负责 append）
##   emit Global.on_create_heal_text → Arena 弹 "+N" 回血飘字
##   WeaponContainer.update_weapons_position() ← **只有** add_weapon() 会调用
##
## 坑（改之前务必看）：
##   · 覆盖 _ready() 必须调 super._ready()，否则 Unit 的 health_component.setup(stats) 不执行
##     （玩家血量会停在 HealthComponent 的默认 1/1）；
##   · %DashTimer / %DashCooldownTimer / %Trail 是"场景唯一名"，$CollisionShape2D / $WeaponContainer
##     是普通路径 —— 这些节点只存在于玩家场景里，直接拿 unit.tscn 造一个 Player 会在 @onready 处拿到 null；
##   · Global.game_paused 只冻结 _process，**不冻结 Timer**：HPRegenTimer 在商店/升级界面停留期间照样回血；
##   · 冲刺禁用/恢复碰撞必须用 set_deferred("disabled", ...)，见 start_dash() 的说明；
##   · stats 是共享的 .tres 资源实例，就地加血量会永久改掉它（同一进程内重开一局也会继续累加）。
extends Unit
class_name Player

## ── 数值（冲刺三件套）──────────────────────────────────────────────────
## 冲刺持续时间（秒），默认 0.5。由 _ready() 写进 DashTimer.wait_time
##   （该 Timer 在 player_well_rounded.tscn 里是 one_shot = true）。
## 单位：秒，建议 0.1~1.0；太长会让"半透明 + 穿身"状态持续过久。
@export var dash_duration := 0.5
## 冲刺期间的移动速度倍率，默认 2.5（即 stats.speed 的 2.5 倍）。1.0 = 和正常跑一样快。
## 它只是把速度**乘**上去，不是固定位移 —— 所以冲刺距离 = speed × 本值 × dash_duration。
@export var dash_speed_multi := 2.5
## 冲刺冷却（秒），默认 0.5。由 _ready() 写进 DashCooldownTimer.wait_time（场景里也是 one_shot）。
## 计时从冲刺**结束**那一刻开始，冷却期间 can_dash() 的第二个条件不成立。
@export var dash_cooldown := 0.5

## ── 节点引用（全部来自 player_well_rounded.tscn，子角色场景继承）──────────────
##   %DashTimer / %DashCooldownTimer → 两个 one_shot 计时器；场景里没写 wait_time（引擎默认 1.0），
##                                     必须由 _ready() 用上面的导出值覆盖
##   $CollisionShape2D               → 玩家本体碰撞（半径 4.12 的圆，位置 (0,-30)），冲刺时被禁用
##   %Trail                          → Visuals 下的 Line2D 拖尾（Trail 脚本，top_level = true）
##   $WeaponContainer                → 武器阵型容器（WeaponContainer 脚本），负责摆放手上武器的位置
@onready var dash_timer: Timer = %DashTimer
@onready var dash_cooldown_timer: Timer = %DashCooldownTimer
@onready var collision_shape_2d: CollisionShape2D = $CollisionShape2D
@onready var trail: Trail = %Trail
@onready var weapon_container: WeaponContainer = $WeaponContainer

## ── 状态 ────────────────────────────────────────────────────────────────
## 场上**真实存在**的武器节点列表（Weapon 节点，不是 ItemWeapon 数据资源）。
## 由 add_weapon() 追加；ShopPanel 在读/卖/合成时直接对它 filter / erase（上限 6 把由 ShopCard 拦）。
## 顺序 = 获得顺序，WeaponContainer 正是按这个顺序把武器摆到阵型位上的。
var current_weapons: Array[Weapon] = []
## 本帧的输入方向向量（Input.get_vector 的返回值，长度 ≤ 1）。
## 在 _process 里每帧刷新；暂停时不更新；冲刺结束的回调里会被清零（防滑步）。
var move_dir: Vector2
## 是否正在冲刺。start_dash() 置 true，DashTimer 超时置 false。
var is_dashing := false
## ⚠ 声明了但**全工程没有任何地方读取**（历史遗留）：冲刺可用性的真实判据是
## dash_cooldown_timer.is_stopped()，见 can_dash()。改这个变量不会影响任何行为。
var dash_available := true


## 生命周期：父类 Unit._ready() 之后执行，补上玩家特有的初始化。
## 参数/返回值：无。
## 副作用：
##   · super._ready() → health_component.setup(stats)（设满血 + emit on_health_changed 刷血条）；
##   · 用导出值覆盖两个计时器的 wait_time（场景里它们是引擎默认的 1.0）。
## 时机 / 坑：
##   · **super._ready() 不能删**，否则玩家血量停在 HealthComponent 的默认 1/1；
##   · 两个计时器在 player_well_rounded.tscn 里都是 one_shot = true。若改成 Timer 默认的 false：
##     DashTimer 循环 → is_dashing 反复置位；DashCooldownTimer 循环 → is_stopped() 永远 false
##     → can_dash() 永远返回 false，冲刺彻底失效；
##   · 下面一大片注释掉的 add_weapon(preload("uid://...")) 是原作者调试用的初始武器，
##     原文保留（正式发初始武器走 Arena → Global.main_weapon_selected 那条路）。
# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	super._ready()
	dash_timer.wait_time = dash_duration
	dash_cooldown_timer.wait_time = dash_cooldown
	
	#add_weapon(preload("uid://c412cvkmww8ch"))
	#add_weapon(preload("uid://v3qy6nqsa42h"))
	#add_weapon(preload("uid://cim67qebrn4lw"))
	#add_weapon(preload("uid://246kvelp4yr3"))
	#add_weapon(preload("uid://bx7d7mby7gkxw"))
	#add_weapon(preload("uid://o1pjlme2fu5o"))
	#add_weapon(preload("uid://cgsyn64p4dyq4"))
	#add_weapon(preload("uid://dh4ejm50kgsgv"))
	#add_weapon(preload("uid://c1s0vxtth2eay"))
	#add_weapon(preload("uid://cnvvspccvx3c8"))
	#add_weapon(preload("uid://dfd3lorxq2qj4"))
	
## 每帧主循环：读输入 → 位移 → 冲刺判定 → 动画/朝向。
## 参数 delta：距上一帧的秒数（引擎传入），速度单位因此是"像素/秒"。
## 返回值：无。
## 副作用：改 position（**直接改**，不走物理体；Area2D 的判定形状随节点一起移动）、
##   可能触发 start_dash()（进而改 trail / modulate / 碰撞形状 / 计时器）、
##   让 AnimationPlayer 切动画、改 visuals.scale。
## 细节 / 坑：
##   · 第一行检查 Global.game_paused（Spawner 每波结束置 true）—— 暂停时不读输入、不位移；
##   · Input.get_vector 的结果**已经做过死区与归一化**（长度 0~1），所以斜向移动不会更快；
##   · 位移用 position（局部坐标，相对 Arena 节点）而不是 global_position；
##     clamp 把玩家限制在 x ∈ [-1000, 1000]、y ∈ [-500, 500] ——
##     这正好等于 Spawner.spawn_area_size(1000, 500)：改刷怪范围时**必须同步改这里**，
##     否则会出现"怪刷在墙外、玩家过不去"或者"玩家能跑出刷怪区"；
##   · clamp 作用在 position 上：Arena 不在原点时它与 global_position 不等价（当前 Arena 在原点，看不出差别）；
##   · can_dash() 用的是 is_action_just_pressed，所以冲刺是"按下瞬间"触发；
##     若那一帧正好被 game_paused 提前 return，这次按键会被吞掉（不会补发）；
##   · 冲刺期间仍然走完整的位移计算（速度乘 dash_speed_multi），没有单独的"冲刺位移"分支，
##     因此冲刺途中改变输入方向会让玩家拐弯。
# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	if Global.game_paused:
		return
	move_dir = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	
	var current_velocity := move_dir * stats.speed
	if is_dashing:
		current_velocity *= dash_speed_multi
	
	position += current_velocity * delta
	position.x = clamp(position.x, -1000, 1000)
	position.y = clamp(position.y, -500, 500)
	
	
	if can_dash():
		start_dash()
	
	update_animations()
	update_rotation()


## 把一份武器数据变成场上真实存在的武器节点，并挂到玩家身下。
## 谁调用：Arena._on_selection_panel_on_selection_completed()（开局发初始武器）、
##   ShopPanel._on_item_purchased()（买到武器）、ShopPanel._on_combine_button_pressed()（合成出下一档）。
## 参数 data：ItemWeapon 资源（内含 scene 场景引用与 stats 数值），来自商店候选池或 .tres。
## 返回值：无。
## 副作用（五步，顺序有意义）：
##   1. data.scene.instantiate() → 新建 Weapon 节点；
##   2. add_child(weapon)：**入树的瞬间** Weapon._ready() 就会执行（它把 sprite 的初始位置记进
##      atk_start_pos）。此刻 weapon.data 还是 null —— 所以 Weapon._ready() 里不能读 data；
##   3. weapon.setup_weapon(data)：注入数据、把索敌圆半径设成 max_range、按稀有度上描边色。
##      第 2、3 步在同一个调用栈里同步完成，所以第一帧 _process 之前 data 必然已就绪；
##   4. current_weapons.append(weapon)：登记进玩家自己的列表（ShopPanel 读的就是它）；
##   5. weapon_container.update_weapons_position(current_weapons)：**用整张列表重排所有武器**的位置。
## 坑：
##   · 重复调用只会越来越多 —— 本函数不查重、不看上限（上限 6 由 ShopCard 在购买前拦）；
##   · 重排只发生在这一处：卖出/合成删武器时没人调用它，剩余武器不会自动补位（视觉上留空档）；
##   · data.scene 为 null 时第 1 步直接报错；data 为 null 时第 1 步就崩了。
func add_weapon(data:ItemWeapon) -> void:
	var weapon := data.scene.instantiate() as Weapon
	add_child(weapon)
	weapon.setup_weapon(data)
	current_weapons.append(weapon)
	weapon_container.update_weapons_position(current_weapons)

## 按本帧输入切换"待机 / 移动"动画。
## 参数：无（读成员 move_dir）。
## 返回值：无。
## 副作用：animation_player.play("move") 或 play("idle")。
## 细节：AnimationPlayer 在 unit.tscn 里 autoplay = "idle"，所以出生时已经在播 idle；
##   对**同名动画**重复调用 play() 不会重置播放进度（Godot 的既有行为），因此不会抖。
## 坑：move_dir 只在 _process 里更新，且暂停时 _process 提前 return ——
##   于是"暂停时动画停在跑动帧上"，看起来像在原地踏步（纯表现问题）。
func update_animations() -> void:
	if move_dir.length() > 0:
		animation_player.play("move")
	else:
		animation_player.play("idle")

func update_rotation() -> void:
	if move_dir == Vector2.ZERO:
		return
	
	if move_dir.x >= 0.1:
		visuals.scale = Vector2(-0.5, 0.5)
	else:
		visuals.scale = Vector2(0.5, 0.5)

func start_dash() -> void:
	is_dashing = true
	dash_timer.start()
	trail.start_trail()
	visuals.modulate.a = 0.5
	collision_shape_2d.set_deferred("disabled", true)

func can_dash() -> bool:
	return not is_dashing and dash_cooldown_timer.is_stopped() and Input.is_action_just_pressed("dash") and move_dir != Vector2.ZERO
	
func is_facing_right() -> bool:
	return visuals.scale.x == -0.5

func update_player_new_wave() -> void:
	stats.health += stats.health_increase_per_wave
	health_component.setup(stats)

func _on_dash_timer_timeout() -> void:
	is_dashing = false
	visuals.modulate.a = 1.0
	move_dir = Vector2.ZERO
	collision_shape_2d.set_deferred("disabled", false)
	dash_cooldown_timer.start()


func _on_hp_regen_timer_timeout() -> void:
	if health_component.current_health <= 0:
		return
	if health_component.current_health < stats.health:
		var heal := stats.hp_regen
		health_component.heal(heal)
		Global.on_create_heal_text.emit(self, heal)
		
		
