## ═══════════════════════════════════════════════════════════════════════════
## Weapon —— 场上武器的通用逻辑（节点侧）：索敌 → 转向 → 冷却 → 交给 behavior 出手
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   场景模板是 scenes/weapons/weapon_base.tscn（根节点 Node2D + 本脚本），
##   所有具体武器（weapon_punch / weapon_pistol / …）都是它的实例，彼此只差三处：
##   ① 贴图与 sprite 的初始位置；② WeaponBehavior 子节点上挂的脚本（Melee 还是 Range）；
##   ③ 被 ItemWeapon .tres 指向时配的 WeaponStats 数值。
##   "数据 → 节点"的桥：Player.add_weapon(data: ItemWeapon) → data.scene.instantiate()
##     → add_child → setup_weapon(data)（本文件）。
##
## 本文件负责什么（真正的伤害逻辑在 behavior 里，这里只管"什么时候打、朝哪儿打"）：
##   1. 索敌：RangeArea（Area2D，圆形的半径 = 武器射程）进/出敌人时维护 targets 列表
##   2. 每帧挑最近目标、算朝向（含散布）、按朝向翻转贴图，冷却到点就调 behavior.execute_attack()
##   3. setup_weapon()：注入数据、按 max_range 设索敌半径、按稀有度上描边色
##
## 数据流（从哪来到哪去）：
##   RangeArea.area_entered / area_exited（连接写在场景文件的 [connection] 段里）
##     → _on_range_area_area_entered / _on_range_area_area_exited → targets: Array[Enemy]
##     （元素其实是**敌人的根节点**：敌人根节点是 Area2D 且 collision_layer = 2，
##      而 RangeArea 是 collision_mask = 2、collision_layer = 0）
##   data: ItemWeapon → data.stats: WeaponStats → 冷却、射程、散布精度（伤害由 behavior 读）
##   Global.player.is_facing_right() → 没有目标时的待机朝向
##   weapon_behavior.execute_attack() → 近战挥砍 / 远程开火（可能是协程，本文件不 await 它）
##
## 坑（改之前务必看）：
##   · setup_weapon() 是在 add_child **之后**才被调用的，所以 _ready() 里不能碰 data（那时还是 null）；
##   · %CollisionShape2D 里那个 CircleShape2D 是场景的**子资源**，同一武器场景的多个实例
##     **共享同一个圆**：给一把武器改半径就会把所有同类武器都改掉
##     （同名武器的射程本来就一样，所以平时看不出来）；
##   · 描边用的 ShaderMaterial 在 weapon_base.tscn 里设了 resource_local_to_scene = true，
##     所以每个武器实例各持有一份材质 —— 这正是"给某把武器上传说描边不会染到别的武器"的原因；
##   · weapon_spread 只累加、**从不清零**，所以一把武器打得越久越飘（现存行为，不是 bug 修复点）。
extends Node2D
class_name Weapon

## ── 节点引用（weapon_base.tscn 及其派生场景）──────────────────────────────
##   $Sprite2D         → 武器贴图。behavior 的挥砍/后座 tween 动的是它的 position；
##                       update_visuals() 动的是它的 scale.y（防倒持）
##   %CollisionShape2D → RangeArea/CollisionShape2D（场景唯一名）。它的 shape 半径 = 武器射程，
##                       由 setup_weapon() 写入
##   $CooldownTimer    → 攻击冷却计时器。weapon_base.tscn 里 one_shot = true → 响一次就停，
##                       于是 is_stopped() 正好可以当"可以再打"的判据
##   $WeaponBehavior   → 行为节点；场景里挂的是 MeleeBehavior 或 RangeBehavior 脚本，
##                       本文件只通过 WeaponBehavior 基类接口调用它
@onready var sprite: Sprite2D = $Sprite2D
@onready var collision: CollisionShape2D = %CollisionShape2D
@onready var cooldown_timer: Timer = $CooldownTimer
@onready var weapon_behavior: WeaponBehavior = $WeaponBehavior

## ── 数据与状态 ──────────────────────────────────────────────────────────
## 这把武器对应的道具数据（ItemWeapon 资源），由 setup_weapon() 注入。
## ⚠ _ready() 执行时它还是 null（Player.add_weapon 是 add_child 之后才调 setup_weapon），
## 所以任何在 _ready() 里读 data 的写法都会崩。
var data: ItemWeapon
## 是否正在出手（挥砍 / 开火动画进行中）。由 behavior 在攻击开始时置 true、收招完成时复位。
## 本文件用它做两件事：① 攻击中不重新选目标（不然会挥到一半改向）；
## ② 攻击中用"目标角度 + 散布"而不是纯目标角度。
var is_attacking := false
## 武器 sprite 的初始局部位置，_ready() 里记录一次。
## behavior 的所有 tween 都以它为基准：后座 = x 减 recoil，前冲 = x 加 max_range，最后回到它。
var atk_start_pos: Vector2
## 当前射程内的目标列表。元素类型是 Enemy —— 因为进入 RangeArea 的其实**就是敌人的根节点**
## （敌人根节点是 Area2D，collision_layer = 2；RangeArea collision_mask = 2）。
## 声明时没写 `= []`：类型化数组的默认值本来就是空数组，不需要显式初始化。
var targets: Array[Enemy]
## 当前锁定的最近目标；没有目标时是 null。
var closest_target: Enemy
## 散布累加值（弧度）。每次出手都会加上一个随机量，并且**从不清零**（见 calculate_spread）。
var weapon_spread : float


## 生命周期钩子：记录 sprite 的初始位置，供 behavior 的 tween 当基准。
## 参数/返回值：无。
## 副作用：写 atk_start_pos。
## 时机 / 坑：
##   · 此刻 data **还没有**注入（调用顺序见文件头），所以这里只能碰 sprite 这类节点属性；
##   · 子类若覆盖 _ready() 必须调 super._ready()，否则 atk_start_pos 会保持 (0, 0)，
##     behavior 的挥击/后座动画会全部错位（武器瞬移到原点附近）；
##   · sprite.position 在 weapon_base.tscn 里是 (0,0)，但在各武器场景里被覆盖成别的值
##     （例如拳套是 (18,0)、手枪是 (23,-7)），所以 atk_start_pos 是每把武器各自的"握持原点"。
# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	atk_start_pos = sprite.position


## 每帧：维护目标 → 转向 → 翻转贴图 → 冷却到点就出手。
## 参数 delta：距上一帧的秒数。⚠ 这里**没用它** —— 冷却走 Timer，转向是瞬时的。
## 返回值：无。
## 副作用：改 rotation、sprite.scale.y、closest_target；
##   命中冷却时会调 use_weapon()（进而启动 CooldownTimer 并让 behavior 出手/生成子弹）。
## 流程与顺序（顺序有讲究）：
##   1) Global.game_paused 直接 return（Spawner 波次结束时置 true）；
##   2) 非攻击状态下刷新目标：targets 非空就找最近的，空了就把 closest_target 置 null；
##   3) rotate_to_target()：先把朝向摆好；
##   4) update_visuals()：按朝向翻贴图；
##   5) can_use_weapon() → use_weapon()：**先转向再出手**，所以近战的判定框与远程的子弹方向
##      用的都是本帧刚算好的 rotation（use_weapon 里的 calculate_spread 还会在此基础上加散布）。
## 坑：
##   · 攻击中不会重新索敌、也不会因目标跑掉而中断 —— 一套动作必须播完（behavior 靠 tween 复位）；
##   · 本文件不认识"玩家朝向变化"以外的任何输入，武器完全自动攻击（没有开火键）。
# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta: float) -> void:
	# 暂停时不索敌、不转向、不攻击（Timer 和 tween 不受影响，见 Global.game_paused 的说明）。
	if Global.game_paused:
		return
	# 只有在"没在出手"时才刷新目标：攻击过程中锁住目标，避免挥到一半改向。
	if not is_attacking:
		if targets.size() > 0:
			update_closest_target()
		else:
			closest_target = null
	# 先转向（会写 rotation），再翻贴图（依据 rotation 判断要不要翻转）。
	rotate_to_target()
	update_visuals()
	
	# 冷却完毕且有目标 → 出手（use_weapon 内部会立刻重启冷却）。
	if can_use_weapon():
		use_weapon()

## 注入武器数据并完成"上膛"设置。
## 谁调用：Player.add_weapon()，紧跟 add_child(weapon) 之后（同步、同一个调用栈）。
## 参数 new_data：ItemWeapon 资源（含 scene 与 stats）。
## 返回值：无。
## 副作用（三处，都不 emit 信号）：
##   · 写成员 data（后续 _process / behavior 全靠它取数值）；
##   · **写碰撞形状的半径** collision.shape.radius = new_data.stats.max_range ——
##     ⚠ 这个 CircleShape2D 是场景的子资源，同一武器场景的多个实例共享它，
##     所以给一把武器改射程会连带改掉同类武器（它们本来就同射程，故平时无感）；
##   · 调 apply_tier_outline() 按稀有度改 sprite.material 的 shader 参数（或置 null）。
## 坑：new_data 或 new_data.stats 为 null（.tres 没配好）时，函数体第 2 句
##   （collision.shape.radius = new_data.stats.max_range）会直接报错；
##   本函数**不**重置 closest_target / weapon_spread，换武器数据不会清掉已有的散布累积。
func setup_weapon(new_data: ItemWeapon) -> void:
	self.data = new_data
	collision.shape.radius = new_data.stats.max_range
	apply_tier_outline()

## 真正"出手"：摇散布 → 交给 behavior 做动作 → 重置并启动冷却。
## 参数：无。返回值：无。
## 副作用：改 weapon_spread 与 rotation；调 weapon_behavior.execute_attack()
##   （近战会开关 hitbox / 跑 tween，远程会 instantiate 子弹并播枪声）；
##   写 cooldown_timer.wait_time 并 start() 计时器。
## 顺序（重要）：
##   1) calculate_spread() 必须在 execute_attack() **之前** —— 它会把随机散布加进 rotation，
##      而远程子弹的方向是在 behavior 里读 weapon.rotation 算出来的（近战则用朝向摆判定框）；
##      顺序反了，散布就只影响贴图朝向、不影响实际弹道；
##   2) 冷却最后设置：execute_attack() 可能是协程（远程有 await），本函数不等它 ——
##      冷却从"出手那一刻"开始算，而不是动作播完才算。
## 坑：data.stats.cooldown 若配成 0，Timer 会立刻超时，is_stopped() 马上又成立 → 等于每帧开火；
##   cooldown_timer 在场景里是 one_shot = true，所以不需要手动 stop()。
func use_weapon() -> void:
	# 先摇散布并写进 rotation —— 必须在 execute_attack() 之前，远程子弹方向就是读这个 rotation 算的。
	calculate_spread()
	# 交给具体行为（近战挥砍 / 远程开火）。它可能是协程，这里不等它，所以冷却立刻开始计时。
	weapon_behavior.execute_attack()
	# 冷却时长取自武器数据；CooldownTimer 是 one_shot，start() 后响一次即停（is_stopped() 重新变 true）。
	cooldown_timer.wait_time = data.stats.cooldown
	cooldown_timer.start()
	

## 按"是否正在出手"选择转向算法，并把结果写进 rotation。
## 参数：无。返回值：无。副作用：写 rotation（本节点自身的旋转，会带动 sprite 与判定框）。
## 两条分支：
##   · is_attacking 为 true → get_custom_rotation_to_target()（目标角度 **加上** weapon_spread）：
##     让挥砍/开火期间的可见朝向体现散布；
##   · 否则 → get_rotation_to_target()（纯目标角度，或没有目标时的待机角度）。
## 坑：攻击中那一支每次都会把 rotation **整个重设**成"角度 + 散布"，
##   于是 calculate_spread() 里那句 `rotation += weapon_spread` 的效果被抹掉了 ——
##   真正决定可见朝向的是这里的加法，而不是 calculate_spread 里的自增（后者只对"出手当帧"有意义，
##   例如远程 weapon.rotation 被拿去算子弹方向）。
func rotate_to_target() -> void:
	if is_attacking:
		rotation = get_custom_rotation_to_target()
	else:
		rotation = get_rotation_to_target()

## 攻击中的朝向：目标角度 + 散布偏移。
## 参数：无。返回值：float —— 弧度（Godot 里 0 = 朝右，PI/2 = 朝下，因为 Y 轴向下）。
## 副作用：无（纯计算）。
## 细节 / 坑：
##   · 与 get_rotation_to_target() 不同，这里**先判了目标有效性**
##     （`not closest_target or not is_instance_valid(closest_target)`）：
##     目标被释放（敌人在攻击途中被打死 queue_free）时直接返回当前 rotation，避免访问野引用；
##   · 方向用 direction_to(...).angle() 得到（单位向量 → 弧度，等价于 atan2(dy, dx)）；
##   · 加的是 weapon_spread —— 它会一路累加（从不清零），所以攻击动作看起来会逐渐偏斜。
func get_custom_rotation_to_target() -> float:
	if not closest_target or not is_instance_valid(closest_target):
		return rotation
	
	var rot := global_position.direction_to(closest_target.global_position).angle()
	return rot + weapon_spread
	
## 非攻击状态的朝向：有目标就指向最近目标，没目标就按玩家朝向待机。
## 参数：无。返回值：float —— 弧度。
## 副作用：无（纯计算，不写 rotation —— 赋值是调用方 rotate_to_target() 干的事）。
## 坑（与上一个函数的差别）：这里**没有**校验 closest_target 是否有效，
##   它依赖 _process() 里"targets 非空就先 update_closest_target()"这个前提；
##   如果以后有别的代码路径在不刷新目标的情况下直接调用本函数，就会访问到失效引用。
func get_rotation_to_target() -> float:
	if targets.size() == 0:
		return get_idle_rotation()
		
	var rot := global_position.direction_to(closest_target.global_position).angle()
	return rot
	

## 没有敌人时的待机朝向：跟着玩家的朝向走。
## 参数：无。返回值：float —— 面朝右时 0（弧度），面朝左时 PI（180°，也就是枪口朝左）。
## 副作用：读 Global.player（跨场景存活的引用）；不写任何状态。
## 谁在用：update_visuals() 靠它决定要不要翻转贴图 —— 换句话说，武器在待机时是"朝着玩家看的方向"。
## 坑：Global.player 失效（未实例化或已释放）时会报错。实践中武器永远是玩家的子节点，
##   玩家没了武器也一起没了，所以不会真的走到这一步。
func get_idle_rotation() -> float:
	if Global.player.is_facing_right():
		return 0
	else:
		return PI

## 防止武器贴图"倒着拿"：朝向偏到左半边时把 sprite 沿 Y 轴翻转。
## 参数：无。返回值：无。副作用：写 sprite.scale.y（固定 ±0.5，0.5 是场景里的基准缩放）。
## 原理：武器整体是靠 rotation 转的，转到 |rotation| > 90° 时贴图会上下颠倒/左右反向，
##   这时把 scale.y 取负就能把它翻回来（只翻 y、不翻 x，保持武器长度方向不变）。
## 坑：
##   · 判断用的是 abs(rotation)（弧度）与 PI/2 比较，覆盖了"指向左"的整个半圆；
##   · 这里写死的 0.5 与 weapon_base.tscn 里 Sprite2D 的 scale = (0.5, 0.5) 绑定 ——
##     改基准缩放要同步改这两个分支，否则武器显示大小会被这里"强行复位"；
##   · 翻转的是 sprite 的缩放，所以挂在 Sprite2D 下的子节点（近战的 HitboxComponent、
##     远程的 Muzzle 标记）会**一起被翻转** —— 它们的本地坐标因此跟着镜像。
func update_visuals() -> void:
	if abs(rotation) > PI / 2:
		sprite.scale.y = -0.5
	else:
		sprite.scale.y = 0.5


## 摇散布：把一次随机偏移累加进 weapon_spread，并把结果加到 rotation 上。
## 参数：无。返回值：无。副作用：写 weapon_spread（**累加，永不清零**）与 rotation。
## 数值口径（容易看错的地方）：
##   · accuracy 是 0~1 的"精度"（WeaponStats 里滑条限制 0.0~1.0），
##     随机范围写的是 randf_range(-1 + accuracy, 1 - accuracy)：
##       accuracy = 1.0 → 范围 [0, 0]（完全不抖）；accuracy = 0.9 → ±0.1；accuracy = 0.0 → ±1 弧度。
##   · ⚠ 单位是**弧度**不是度：±1 弧度 ≈ ±57°，是相当夸张的抖动；
##   · 因为是**累加**（weapon_spread += 随机量）而不是每帧重掷，偏差会像随机游走一样越走越远 ——
##     一把枪打久了枪口会持续偏在某一侧，这是现存行为，WeaponStats 里也标注过。
## 调用点：use_weapon() 的第一句，也就是每次出手摇一次。
## 时序：它改完 rotation 之后紧接着就调 behavior.execute_attack()，
##   所以"出手当帧"的 rotation 确实带上了新散布（子弹方向就是这么算出来的）；
##   但下一帧 rotate_to_target() 会用"目标角度 + weapon_spread"重设 rotation（见那个函数的坑）。
func calculate_spread() -> void:
	weapon_spread += randf_range(-1 + data.stats.accuracy, 1 - data.stats.accuracy)
	rotation += weapon_spread

## 刷新"最近目标"缓存（把 get_closest_target() 的结果写进 closest_target）。
## 参数：无。返回值：无。副作用：写 closest_target（可能被写成 null）。
## 谁调用：_process() 里 targets 非空时每帧调用一次 ——
##   所以 closest_target 的时效性只保证到"本帧的转向计算"为止。
## 注意：本函数是纯粹的"赋值包装"，可读性上分离了"找"和"存"两步。
func update_closest_target() -> void:
	closest_target = get_closest_target()
	

## 在 targets 里线性找出距离本武器最近的那个敌人。
## 参数：无（读成员 targets）。
## 返回值：Node2D —— 最近的目标节点；targets 为空时 `return`（无值）→ 实际返回 null。
##   返回类型写成 Node2D 而不是 Enemy，是为了能直接 `return`（空返回合法）；
##   元素本身是 Enemy 节点（敌人的根节点是 Area2D + Enemy 脚本）。
## 副作用：无（不缓存到 closest_target，缓存由 update_closest_target() 负责）。
## 实现：O(n) 线性扫描，先拿 targets[0] 当初始最优，再从下标 1 逐个比较。
##   武器最多 6 把、场上敌人几十个，这个复杂度完全够用；
##   `var closest_enemy = targets[0]`（没写类型）是刻意的宽类型，方便最后直接返回。
## 坑：不检查目标是否已被释放 —— 依赖引擎在敌人 queue_free 时补发 area_exited 把 target 从
##   targets 里摘掉（物理服务器会做这件事），所以正常不会扫到失效引用。
func get_closest_target() -> Node2D:
	# 找不到目标时走无值 return → 返回 null（调用方的 closest_target 就被置空）。
	if targets.size() == 0:
		return
	# 以第一个目标为初始最优，再从下标 1 起线性比较，只保留距离更小的那个。
	var closest_enemy = targets[0]
	var closest_distance := global_position.distance_to(closest_enemy.global_position)
	
	for i in range(1, targets.size()):
		# 显式标注成 Enemy：targets 的元素类型就是它，标注后能直接拿到 Enemy 的成员（编辑器补全/类型检查）。
		var target: Enemy = targets[i]
		var distance := global_position.distance_to(target.global_position)
		if distance < closest_distance:
			closest_enemy = target
			closest_distance = distance
	return closest_enemy

## 判断此刻能否出手。
## 参数：无。
## 返回值：声明为 bool，但实际返回的是 `is_stopped() and closest_target` ——
##   后者是一个**节点引用**，GDScript 会按"非 null 即 true"把它转成 bool。
## 副作用：无（纯查询）。
## 两个条件：
##   ① cooldown_timer.is_stopped() —— 只有在 one_shot 计时器**响过一次之后**才为 true，
##      weapon_base.tscn 里确实设了 one_shot = true；若改成循环计时器，这个条件将永远为 false、武器不再攻击；
##      注意 Timer 刚被创建、还没 start() 过时 is_stopped() 也是 true，所以武器出场即可开火；
##   ② closest_target 非 null —— 没有敌人就不打（也不会原地挥空）。
## 注意：没有"目标是否已被释放"的检查（只判非 null），依赖 _process 每帧刷新 closest_target。
func can_use_weapon() -> bool:
	return cooldown_timer.is_stopped() and closest_target
	
## 按稀有度给武器加描边（用 outline shader 的 color 参数）。
## 参数：无（读 data.item_tier 与 Global.TIER_COLORS）。
## 返回值：无。
## 副作用：改 sprite.material 的 shader 参数，或者把 sprite.material 整个置成 null。
## 两条分支：
##   · COMMON（普通）→ material = null，**直接 return**：普通武器不要描边。
##     ⚠ 这也意味着普通武器会失去场景里原本配好的 ShaderMaterial（连同它的 thickness、
##     tolerance 等参数一起），因为 weapon_base.tscn 的 Sprite2D 默认就挂着那个材质；
##   · 其他档 → 从 Global.TIER_COLORS 取颜色写进 shader 的 "color" 参数。
##     Global.TIER_COLORS 里**没有 COMMON 键**，所以上面必须先 return，否则取键会报错。
## 关键前提：sprite.material 必须真的是 ShaderMaterial（weapon_base.tscn 里配的就是），
##   否则 set_shader_parameter 会报错。
## 为什么不会互相污染：那个 ShaderMaterial 在 weapon_base.tscn 里设了
##   resource_local_to_scene = true → 每个武器实例各自持有一份材质副本，
##   于是"给这把武器上传说描边"不会把别的武器也染红。
##   （对比：同一场景里没设该标志的 CircleShape2D 就是共享的，见 setup_weapon 的说明。）
func apply_tier_outline() -> void:
	# 普通档：不要描边。直接摘掉材质并返回（TIER_COLORS 里没有 COMMON 键，不能往下走）。
	if data.item_tier == Global.UpgradeTier.COMMON:
		sprite.material = null
		return
	# 从全局配色表取颜色，写进 outline shader 的 color 参数。
	# 材质是 resource_local_to_scene 的副本，所以只影响本武器实例。
	var outline_color := Global.TIER_COLORS[data.item_tier]
	sprite.material.set_shader_parameter("color", outline_color)


## 敌人进入射程时登记目标。
## 信号来源：weapon_base.tscn 里 RangeArea.area_entered → 本方法（代码里没有 connect）。
## 参数 area：进入范围的 Area2D。⚠ 实际传进来的是**敌人的根节点**
##   （敌人根节点类型就是 Area2D，collision_layer = 2；而 RangeArea 是 collision_mask = 2、layer = 0）——
##   所以这里虽然形参写的是 Area2D，push_back 到 Array[Enemy] 却能通过类型检查。
## 返回值：无。
## 副作用：targets.push_back(area)（改本武器的目标列表）。
## 坑：
##   · 若未来有别的 layer=2 的 Area2D 飘进射程（不是 Enemy），
##     push_back 会因为类型不符**在运行时直接报错**（类型化数组会逐元素校验）；
##   · 没有做去重：正常情况下一个 Area 只会 enter 一次（离开时才有 exited），
##     但如果中途手工改过 monitoring，理论上可能重复登记同一个目标。
func _on_range_area_area_entered(area: Area2D) -> void:
	targets.push_back(area)


## 敌人离开射程（或目标节点被销毁）时注销目标。
## 信号来源：weapon_base.tscn 里 RangeArea.area_exited → 本方法。
## 参数 area：离开范围的 Area2D（同 entered：实际是敌人的根节点）。
## 返回值：无。
## 副作用：targets.erase(area)；若列表因此清空，把 closest_target 也置 null。
## 时机 / 坑：
##   · 敌人被 queue_free 时物理服务器会补发一次 area_exited，所以 targets 不会长期残留野引用 ——
##     这正是 get_rotation_to_target() 敢不判有效性的底气；
##   · erase 按**值**（对象引用）移除，找不到时什么也不做，不会报错；
##   · 这里没有重新计算"谁来当新目标"，只是把 closest_target 置空 ——
##     下一帧 _process 发现 targets 非空会重新选一个，所以最多空一帧。
func _on_range_area_area_exited(area: Area2D) -> void:
	# 按对象引用移除；找不到也不会报错。
	targets.erase(area)
	# 打空了就清掉目标缓存，下一帧 _process 会重新决定"没有目标"还是"还有别的目标"。
	if targets.size() == 0:
		closest_target = null
		
