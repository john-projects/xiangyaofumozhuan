## ═══════════════════════════════════════════════════════════════════════════
## ShootingBehavior —— 远程敌人的行为脚本（周期性朝玩家打出一扇"弹幕"）
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   挂在 enemy_shooter.tscn 的 "ShootingBehavior" 节点上（根 EnemyShooter 继承自
##   enemy_chaser_slow.tscn → Enemy → Unit）。
##   与 ChargerBehavior 同属"旁挂的 Node2D 组件"：@export enemy 指回宿主敌人，
##   @export fire_pos 指出膛点；冷却走自己的 _process，站桩期间借 enemy.can_move 冻结宿主移动。
##
## 本文件负责什么：
##   冷却到点 → 朝玩家方向、以 fire_pos 为出生点打出一扇形 projectile_count 发子弹 →
##   站桩 1 秒 → 解冻。子弹本体是 scenes/projectiles/projectile_enemy.tscn（Projectile 脚本）。
##
## 数据流（从哪来到哪去）：
##   Global.player.global_position → 决定扇形的中心方向（每次开火重新取一次）
##   @export fire_pos（enemy_shooter.tscn 里是 Visuals/FirePos，一个 Marker2D）→ 子弹出生位置
##     ⚠ 它挂在 Visuals 下，会随敌人的左右镜像一起翻转，所以敌人转身后不会出现"朝身后开枪"
##   @export projectile_scene → instantiate() 出 Projectile，add_child 到 **/root** 下（不挂在敌人身上）
##   enemy.stats.damage → 传给子弹的伤害；critical 固定 false、knockback 固定 0
##   enemy.can_move ← 本脚本写；Enemy._process 读（false 时敌人停止追击，站着开枪）
##
## 关于 enemy_shooter.tscn 里那几行 "cooldown = null" / "projectile_count = null"：
##   那是编辑器保存场景时写下的"空覆盖"。实测（Godot 4.7.2）对类型化的脚本变量来说，
##   这种 null 赋值会被拒绝并**保留脚本里的默认值**（不报错、不变成 0）——
##   所以实际生效的是 3.0 秒 / 3 发 / 45° / 1800 像素每秒。
##   别把它们当成"0 冷却"；在编辑器面板里手动填一个值才会真正覆盖脚本默认值。
##
## 坑（改之前务必看）：
##   · projectile_count 为 1 时，angle_step 的分母会成为 0.0 → INF，而 INF * 0 = NaN，
##     方向算出来是 NaN 向量（单发配置目前**不可用**，详见 shoot()）；
##   · shoot() 是含 await 的协程，_process 里"调用但不等"，靠 can_move 与自己互斥；
##   · 子弹挂在 /root 下，owner 为 null，且**不随敌人销毁**；
##   · 本文件检查了 Global.game_paused（这点比 ChargerBehavior 规矩）。
extends Node2D
class_name ShootingBehavior

## ── 引用（enemy_shooter.tscn 用 node_paths 绑定）──────────────────────────
## enemy：宿主敌人（场景里填 NodePath("..")）。为 null 时 _process 直接 return（防呆）。
@export var enemy: Enemy
## fire_pos：出膛点（Marker2D）。用它的 global_position 当子弹起点。
## 因为它挂在 Visuals 下，敌人左右镜像时出膛点会跟着镜像（这正是"敌人转身后枪口换边"的实现方式）。
## 为 null 时 shoot() 会在读 global_position 处报错 —— 远程敌人场景必须摆一个 Marker2D。
@export var fire_pos: Marker2D
## ── 数值 ────────────────────────────────────────────────────────────────
## 开火间隔（秒），默认 3.0（场景里那句 null 覆盖被忽略，见文件头说明）。
## 用 delta 自减，不用 Timer。⚠ 它和"站桩 1 秒"是两套时间：冷却从开火那一刻开始算，
## 所以敌人实际上在冷却走完约 1/3 的时候就已经能重新移动了。
@export var cooldown:= 3.0
## 一次开火打出的子弹数，默认 3。子弹在 arc_angle 的扇形内**均匀分布**（含两端）。
## ⚠ 配成 1 会因除零算出 NaN 方向（见 shoot()）；配成 0 则一发都不打但冷却照走。
@export var projectile_count:= 3
## 扇形总张角（度），默认 45.0 —— 换算成弧度后是中心线左右各 22.5°。
## 单位是**度**（代码里靠 deg_to_rad 换），别在这里填弧度值。
@export var arc_angle:= 45.0
## 子弹场景（enemy_shooter.tscn 指向 res://scenes/projectiles/projectile_enemy.tscn）。
## 根节点必须挂 Projectile 脚本，否则 `instantiate() as Projectile` 得到 null，紧接着设置属性就崩。
@export var projectile_scene: PackedScene
## 子弹速度（像素/秒），默认 1800.0。velocity = 方向 * 本值，
## 之后由 Projectile._process 每帧 position += velocity * delta，所以这是"每秒走多少像素"。
@export var projectile_speed:= 1800.0

## ── 状态 ────────────────────────────────────────────────────────────────
## 距下一次开火还剩多少秒。由 _ready() 初始化成 cooldown，
## 所以敌人生成后不会立刻开枪，要先等满一个冷却。
var current_cooldown := 0.0



## 生命周期钩子（extends Node2D，父类没有脚本，不需要 super）。
## 参数/返回值：无。
## 副作用：把 current_cooldown 设成 cooldown —— "出场自带一个完整冷却"。
## 时机：导出属性（enemy / fire_pos / projectile_scene）在 _ready() 之前就已由场景赋好值；
##   _ready() 也早于第一次 _process()，所以不会有"冷却未初始化就被减"的窗口。
# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	current_cooldown = cooldown


## 冷却倒计时，到点就开火（每帧调用）。
## 参数 delta：距上一帧的秒数（引擎传入）。
## 返回值：无。
## 副作用：调用 shoot()（协程，不等它）、重置 current_cooldown。
## 时序 / 坑：
##   · 第一道检查是 Global.game_paused（和 Enemy._process 一致）—— 商店/升级界面停留期间冷却**不**推进；
##   · 重置冷却发生在 shoot() **之后**，而 shoot() 内部 await 1 秒：因为 _process 不等它，
##     所以这一帧就把 current_cooldown 设回了 cooldown，下一帧开始重新倒计时 ——
##     于是"开火冷却"与"站桩 1 秒"是两条并行的计时线；
##   · 如果开火时玩家引用已失效，shoot() 里会提前 return（一发不打），但冷却照样被重置 ——
##     相当于空放一次（现有行为）。
# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	if Global.game_paused:
		return
	if enemy == null:
		return
	if current_cooldown > 0:
		current_cooldown -= delta
	else:
		shoot()
		current_cooldown = cooldown

## 打出一扇子弹。⚠ 函数体里有 await，所以它是**协程**，不是同步函数。
## 参数：无（全部数值取自导出属性与宿主敌人）。
## 返回值：无（调用方拿到协程对象；_process 里没有 await 它）。
## 副作用：
##   · enemy.can_move = false —— 立刻冻结宿主追击（敌人站桩开枪），1 秒后置回 true；
##   · 往 /root 下 add_child 出 projectile_count 个 Projectile 节点（**不挂在敌人身下**）；
##   · 配置每个子弹的 velocity / damage / critical=false / knockback=0 / source=enemy。
## 算法（5 步）：
##   1) direction = 敌人 → 玩家的单位向量（扇形中心线）；
##   2) start_angle = -arc_angle / 2 —— 扇形从中心线**左侧**半个张角处开始；
##   3) angle_step = arc_angle / (发数 - 1) —— 让 projectile_count 发均匀铺满整个扇形（含两端）；
##   4) 第 i 发方向 = direction.rotated(deg_to_rad(start_angle + angle_step * i))，
##      rotated() 逆时针为正，所以 i 递增时子弹依次"扫"过扇形；
##   5) velocity = 该方向 * projectile_speed，之后交给 Projectile 自己每帧积分位移。
## 坑（重要）：
##   · 分母写作 `float(projectile_count -1 if projectile_count > 1 else 0.0)`：
##     当 projectile_count == 1 时走 else 分支 → 分母 0.0 →
##     arc_angle / 0.0 = **INF**（GDScript 浮点除零不报错，已实测），
##     接着 angle_step * 0 = INF * 0 = **NaN**，方向向量变成 (nan, nan)：
##     子弹会原地不动、位置变 NaN。也就是说"单发远程敌人"目前是坏的（想支持 1 发必须改这个表达式）；
##   · 先 add_child 再设 global_position：节点不在树里时 global_position 没有有效的父变换；
##   · 子弹挂到 get_tree().root（/root）下，而不是敌人身下：
##     好处是敌人死亡/清场不会带走飞行中的子弹；代价是这些子弹的 owner 为 null ——
##     谁都不能用 owner.queue_free() 删它们，只能靠子弹自己在命中 hurtbox 或飞出屏幕时 queue_free()；
##   · set_peojectile 是原作者的拼写（不是 set_projectile），签名是
##     (velocity, damage, critical, knockback, source)。这里 critical 传 false（敌人不暴击）、
##     knockback 传 0（子弹不击退）；source 传 enemy，供受击方算击退方向（此处用不上）；
##   · 末尾 `await get_tree().create_timer(1).timeout` 的 1 秒是**硬编码**的，与 cooldown 无关；
##     它创建的是 SceneTreeTimer（不受 Global.game_paused 影响）；
##     如果这 1 秒内敌人被清场或打死（queue_free），await 恢复后那句 enemy.can_move = true
##     会访问已释放实例并报 "previously freed instance"（现有行为，原文照旧）；
##   · 开火方向取的是 enemy.global_position（敌人中心），出生点却是 fire_pos（枪口），
##     所以视觉上子弹是"从枪口斜着飞出去"的 —— 枪口离中心越远，起始偏差越明显。
func shoot() -> void:
	# 玩家引用可能已失效（Global.player 是跨场景存活的旧引用），先判有效性再访问 global_position。
	if not is_instance_valid(Global.player):
		return
	# 站桩：冻结宿主敌人的常规追击。注意这里没有"敌人已死"的检查 —— 由 _process 的冷却与清场时机兜住。
	enemy.can_move = false
	# 扇形中心线：从敌人中心指向玩家（单位向量）。
	var direction := enemy.global_position.direction_to(Global.player.global_position)
	# 扇形起始角：中心线左侧半个张角（单位是度，后面再 deg_to_rad）。
	var start_angle := -arc_angle / 2.0
	# 两发之间的夹角（度）：除以 (发数-1) 是为了让首尾两发正好落在扇形边界上。
	# ⚠ 发数为 1 时 else 分支给出分母 0.0 → INF，再乘 i=0 得 NaN（见函数注释，实测 Godot 4.7.2）。
	var angle_step := arc_angle / float(projectile_count -1 if projectile_count > 1 else 0.0)
	
	for i in range(projectile_count):
		# 每发都 new 一个子弹实例；`as Projectile` 是运行时类型转换，场景根节点挂错脚本会得到 null。
		var projectile := projectile_scene.instantiate() as Projectile
		# 挂到 /root 下（不是敌人身下）：子弹的生命周期与发射者解耦，敌人死了子弹照样飞。
		# 副作用：这个节点的 owner 是 null，只能用 queue_free() 删除自己。
		get_tree().root.add_child(projectile)
		# 先入树再设位置：global_position 只有在节点有有效父变换时才是世界坐标。
		projectile.global_position = fire_pos.global_position
		
		# 把中心线方向按"起始角 + 步进×序号"旋转：i 越大越偏离中心线（逆时针为正），从而铺开成扇形。
		var rotated_direction := direction.rotated(deg_to_rad(start_angle + angle_step * i))
		# 速度向量（像素/秒）；子弹自己每帧 position += velocity * delta。
		var velocity := rotated_direction * projectile_speed
		# 交给子弹初始化：参数依次是 (速度, 伤害, 是否暴击, 击退力度, 伤害来源节点)。
		# 敌人的子弹固定不暴击、不击退；source 传 enemy 以便受击方算击退方向（此处用不到，因为击退为 0）。
		projectile.set_peojectile(velocity, enemy.stats.damage, false, 0, enemy)
		
	# 站桩 1 秒（硬编码，与 cooldown 无关；SceneTreeTimer 不受 Global.game_paused 影响）。
	await get_tree().create_timer(1).timeout
	# 解冻移动。⚠ 若这 1 秒内敌人已被 queue_free，这一行会报 "previously freed instance"（现有行为）。
	enemy.can_move = true
	
