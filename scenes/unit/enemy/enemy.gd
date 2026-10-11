## ═══════════════════════════════════════════════════════════════════════════
## Enemy —— 敌人基类（Unit 的子类）：追击 AI + 同伴分离 + 击退 + 死亡退场
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   场景模板是 scenes/unit/enemy/enemy_chaser_slow.tscn（"慢速追兵"），
##   其他敌人都是它的变体：enemy_chaser_mid / enemy_chaser_fast（只换 stats 与贴图）、
##   enemy_charger（多挂一个 ChargerBehavior）、enemy_shooter（多挂一个 ShootingBehavior）。
##   所有敌人都是 Unit 的实例，所以血量、白闪、飘字那套公共流程写在 unit.gd 里。
##
## 本文件负责什么：
##   1. 每帧朝玩家移动（_process），并靠"分离力"避免敌人叠成一坨
##   2. 用视觉镜像表达左右朝向（update_rotation）
##   3. 挨打后的击退（apply_knockback / reset_knockback）
##   4. 死亡退场：被打死 → 广播 on_enemy_died（Arena 掉金币）；
##      波次清场 → destroy_enemy()（播 die 动画后 queue_free，**不掉金币**）
##
## 数据流：
##   Global.player（autoload 里的当前玩家节点引用）→ 移动方向、朝向、距离判断
##   @export stats: UnitStats → 速度（移动）、血量/伤害（HealthComponent 与 hitbox 侧读）
##   VisionArea（Area2D，半径 150）→ 给出附近的**其他敌人**，供分离力使用
##   emit Global.on_enemy_died(self) → Arena._on_enemy_died() → spawn_coins.call_deferred()
##   （金币数量取 stats.gold_drop）
##
## 谁创建/销毁敌人：
##   Spawner.spawn_enemy() 先播 EnemySpawnEffect 再 add_child(敌人) 并登记进 spawned_enemies；
##   销毁有两条路：① HealthComponent 血量归零时 owner.queue_free()；
##   ② 波次结束时 Spawner.clear_enemies() 调 destroy_enemy()。
##
## 坑（改之前务必看）：
##   · 覆盖 _ready() 必须调 super._ready()，否则父类的 health_component.setup(stats) 不执行；
##   · 覆盖 _on_hurtbox_component_on_damaged() 也**必须**调 super（同名信号回调），
##     否则扣血/格挡/飘字全部失效，只剩击退；
##   · Global.player 是跨场景存活的旧引用，可能已失效，所以每个用到它的地方都要
##     is_instance_valid() 检查（本文件里出现了四次，不是冗余）；
##   · 暂停只看 Global.game_paused（各脚本自己在 _process 开头 return 的约定），
##     **不是** SceneTree.paused —— Timer 和 tween 在"暂停"期间照常跑。
extends Unit
class_name Enemy

## ── 数值 ────────────────────────────────────────────────────────────────
## 同伴分离力强度（无量纲）。作用方式：相邻敌人每个贡献 flock_push / 距离 的推力。
## 默认值 20.0 来自 enemy_chaser_slow.tscn 的显式赋值；单位不是像素/秒，
## 而是"叠加到方向向量上的权重"，最终还要乘 stats.speed，所以它和速度共同决定挤开的手感。
## 取值：调大 → 敌人散得开、不容易围成团；调大过头 → 敌人互相排斥而绕圈不敢近身。
## 注意：所有敌人共用同一套逻辑，谁的 VisionArea 里邻居多，谁受到的推力就大。
@export var flock_push := 20.0
## ── 节点引用（来自 enemy_chaser_slow.tscn，各敌人场景继承）──────────────────
##   VisionArea     → Area2D，半径 150 的圆（collision_layer = 0、collision_mask = 2），
##                    用来"看见"其他敌人（敌人根节点是 Area2D 且 layer = 2）。
##                    玩家在 layer 1 上，所以这里看不到玩家 —— 玩家是用 Global.player 直接定位的。
##   KnockbackTimer → 击退持续时间计时器，场景里 wait_time = 0.4、one_shot = true。
@onready var vision_area: Area2D = $VisionArea
@onready var knockback_timer: Timer = $KnockbackTimer

## ── 状态 ────────────────────────────────────────────────────────────────
## 是否允许移动。默认 true。
## 这是给"行为脚本"用的冻结开关：ChargerBehavior 蓄力/冲撞期间、ShootingBehavior 开枪后 1 秒内
## 会把它置 false，_process 就会在移动之前提前 return。
## ⚠ 它只挡 _process 里的移动，不挡 ChargerBehavior 直接改 enemy.global_position 的冲撞位移。
var can_move := true

## 当前击退方向（一般由攻击者指向自己）与力度（无量纲倍数）。
## 两者都在 _process 里被当作附加速度使用：position += (移动方向 + knockback_dir * knockback_power) * speed * delta
## 所以 knockback_power = 1.0 大致等于"用 1 倍速度额外被顶开"，而最终位移仍与敌人自身 speed 挂钩
## （跑得快的敌人被打飞得更远）。
## knockback_dir 是值类型 Vector2，清零用 Vector2.ZERO，没有 null 可言。
var knockback_dir: Vector2
var knockback_power: float

## ── 生命周期 ────────────────────────────────────────────────────────────
## Godot 生命周期：子节点先 _ready，父类/本节点后 _ready；本函数第一件事就是补父类初始化。
## 参数/返回值：无。
## 副作用：父类 _ready() 的全部副作用（health_component.setup(stats)，把血量设满并刷新血条）。
## 坑：**这一行 super._ready() 不能删**。删掉之后敌人的血量会停在 HealthComponent 的默认值 1.0，
##   一碰就死、血条永远满格（因为没人 emit on_health_changed）—— 而且不会有任何报错提示。
# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	super._ready()


## 每帧的敌人 AI：追击 + 分离 + 击退位移。
## 参数 delta：距上一帧的秒数（引擎传入）。注意这里用的是**秒**，所以速度单位是"像素/秒"。
## 返回值：无。
## 副作用：直接修改 position（绕过物理体，Area2D 的判定形状跟着节点一起走）
##   与 visuals.scale（朝向）。
## 时序 / 坑：
##   · Global.game_paused 为 true 时整个函数直接 return —— 这是本项目"暂停"的实现方式
##     （Spawner 波次结束时置 true，Arena 开新波/选完人置 false）。
##     因为它不是 SceneTree.paused，所以计时器、tween、动画都不会停；
##   · can_move 为 false 时同样直接 return（蓄力中/开枪后的站桩）；
##   · 位移公式把**击退**和**移动**加在同一个向量里再乘 stats.speed，
##     所以击退力度是相对敌人速度的倍数 —— 想改"被打飞多远"要连速度一起考虑；
##   · 这里没有任何归一化：追兵贴脸时分离力会把合成向量拉长，移动会突然变快（见 get_move_direction）。
# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	if Global.game_paused:
		return
	if not can_move:
		return
	
	if not can_move_towards_player():
		return

	position += (get_move_direction() + knockback_dir * knockback_power) * stats.speed * delta
	update_rotation()


## 算出本帧的移动方向向量（**未归一化**，长度可能大于 1）。
## 参数：无。
## 返回值：Vector2 —— "朝向玩家"与"躲开同伴"的合成向量；玩家引用失效时返回 Vector2.ZERO（原地不动）。
## 副作用：无。只读 Global.player，以及 VisionArea.get_overlapping_areas() 的结果（物理帧产出的列表）。
## 组成（两步）：
##   1) 朝向玩家：global_position.direction_to(玩家位置)，即单位向量；
##   2) 同伴分离：遍历 VisionArea 里重叠的每个 Area2D。敌人的**根节点本身**就是 Area2D
##      （unit.tscn 根节点是 Area2D），敌人场景把它设成 collision_layer = 2，
##      而 VisionArea 的 collision_mask = 2，所以这里看到的就是"其他敌人"；
##      玩家在 layer 1，不会被看见（玩家位置另有来源）。
##      每个邻居的贡献是 flock_push * 单位向量 / 距离 —— 也就是反比衰减：越近推得越狠。
## 坑：
##   · 除法分母是 vector.length()：两个敌人位置**完全重合**时它是 0，
##     0/0 会得到 NaN，位置一旦变成 NaN 这个敌人就等于从画面里消失（不可见、还可能引发后续报错）。
##     刷怪坐标是随机的，正常不会精确重合；若把刷怪点写成固定值就要留意；
##   · 分离项按邻居**个数**累加，被一堆敌人围住时合成向量会远长于 1，
##     而 _process 是 position += 方向 * speed * delta，所以"向量变长"= 实际移动更快；
##   · area != self 排除自己（自己根节点也在 mask 命中范围内）；
##   · area.is_inside_tree() 排除已经被 queue_free、但物理服务器还没清理掉的邻居。
func get_move_direction() -> Vector2:
	if not is_instance_valid(Global.player):
		return Vector2.ZERO
	
	# 玩家方向
	var direction := global_position.direction_to(Global.player.global_position)
	
	# 附近所有敌人
	# 注意上面这行注释是原作者留下的；下面 for 的循环变量声明成 Node2D 而不是 Area2D，
	# 是因为元素实际是"敌人的根节点"（Area2D 也是 Node2D，两者都能用 global_position）。
	# 循环体后面的点号在同一行末尾，行尾那个多余空格不要动（它只是原文里的空白）。
	# 分离力公式 flock_push * v.normalized() / v.length() 可以化简成 flock_push / 距离 的方向分量，
	# 写成两步是为了可读性；代价是"完全重合"时会算出 NaN（见函数注释）。
	for area: Node2D in vision_area.get_overlapping_areas(): 
		if area != self and area.is_inside_tree():
			var vector := global_position - area.global_position
			direction += flock_push * vector.normalized() / vector.length()
	return direction


## 判断现在该不该朝玩家移动。
## 参数：无。
## 返回值：bool —— 玩家引用有效 **且** 与玩家距离 > 60 像素时为 true。
## 副作用：无（只读 Global.player）。
## 为什么要有 60 像素的"停止距离"：不加的话敌人会一路顶到玩家中心，
##   既让一堆敌人挤在同一个点上（分离力也随之爆表），又会让近战判定每帧重复触发；
##   这个阈值同时也是"何时能真正打到你"的手感来源 —— 想调贴身距离就改这里。
## 坑：返回的是复合条件，Global.player 失效时会短路成 false（不会去访问空引用），
##   Global 里注释也提过：旧的一局结束后 Global.player 可能还指向已被释放的节点。
func can_move_towards_player() -> bool:
	return is_instance_valid(Global.player) and global_position.distance_to(Global.player.global_position) > 60
	
## 让敌人面向玩家 —— 只用视觉镜像，不做真正的旋转。
## 参数：无。
## 返回值：无。
## 副作用：写 visuals.scale（视觉根节点的缩放）。
## 实现原理：Godot 里 **x 为负的缩放等价于水平镜像**，所以
##   Vector2(-0.5, 0.5) = 面朝右，Vector2(0.5, 0.5) = 面朝左。
##   这里的 0.5 是**写死的基准缩放**，必须与 unit.tscn 里 Visuals 的 scale = (0.5, 0.5) 一致；
##   若改了基准缩放，单位显示大小会一起变，但这两个分支会把它写回 0.5（相当于强行复位）。
## 注意：
##   · 变量名 moving_right 的真实含义是"玩家位于敌人的右侧"（敌人要看右边），
##     它**不依赖移动方向** —— 敌人站着不动、或者被击退时也一样会转身；
##   · 镜像会连带子节点一起镜像，远程敌人的 FirePos 就挂在 Visuals 下，
##     所以转身后子弹的出膛位置会自动跟着换边；
##   · 玩家引用失效时直接 return，保留上一次的朝向（避免访问空引用）。
func update_rotation() -> void:
	if not is_instance_valid(Global.player):
		return
	
	var player_pos := Global.player.global_position
	var moving_right := global_position.x < player_pos.x
	visuals.scale = Vector2(-0.5, 0.5) if moving_right else Vector2(0.5, 0.5)

## 施加一次击退。注意击退**不是瞬移**，而是被写进 _process 的一个速度分量，随时间到期自动清掉。
## 参数 knock_dir：击退方向（约定传单位向量；实际由调用方算好，本函数不校验长度）。
## 参数 knock_power：击退力度，无量纲倍数。最终位移 = (移动方向 + knock_dir * 力度) * stats.speed * delta，
##   所以 1.0 ≈ 用自身速度额外被顶开，而且**速度快的敌人被打飞得更远**。
## 返回值：无。
## 副作用：写 knockback_dir / knockback_power，并操作 knockback_timer（stop/start）。
##   不 emit 任何信号，击退完全是本地状态。
## 时序 / 坑：
##   · 上一次击退还没过完时（time_left > 0）先 stop()、再 reset_knockback()、最后 start()：
##     目的是让新击退**完全覆盖**旧的，否则方向与力度会叠加成莫名其妙的斜向位移；
##     顺序不能反 —— 先 start() 的话 time_left 会被重置，stop() 那个判断就没意义了；
##   · KnockbackTimer 在场景里是 wait_time = 0.4、one_shot = true → 0.4 秒后 timeout → reset_knockback()。
##     ⚠ 若把 one_shot 改回 Timer 的默认值 false，计时器会循环重启，
##     虽然 reset_knockback() 幂等不会出错，但 time_left > 0 恒成立，
##     每次挨打都要多走一遍 stop/reset（语义从"覆盖旧击退"变成"永远覆盖"）；
##   · 连续被多个攻击判定框命中（同一帧内多次调用）时，后一次方向会覆盖前一次 —— 只生效最后一次。
func apply_knockback(knock_dir: Vector2, knock_power: float) -> void:
	knockback_dir = knock_dir
	knockback_power = knock_power
	if knockback_timer.time_left >0:
		knockback_timer.stop()
		reset_knockback()
	knockback_timer.start()

## 清空击退状态（方向归零、力度归零）。
## 参数：无。
## 返回值：无。
## 副作用：写 knockback_dir / knockback_power 两个成员；不 emit 信号、不碰计时器。
## 调用点：① KnockbackTimer 超时（正常到期，见场景连接）；
##         ② apply_knockback() 里覆盖旧击退之前的清理。
## 注意：方向清零用 Vector2.ZERO，而不是 null —— Vector2 是值类型，根本没有 null。
func reset_knockback() -> void:
	knockback_dir = Vector2.ZERO
	knockback_power = 0.0

## 敌人的"退场"流程：播死亡动画 → 动画播完再真正删除节点。
## 谁调用：Spawner.clear_enemies()（每波计时结束时清场）。
##   ⚠ 注意：**敌人被打死时不走这里** —— 那条路是 HealthComponent 血量归零 → emit on_unit_died
##   → _on_health_component_on_unit_died() → Arena 掉金币 + HealthComponent.die() 直接 owner.queue_free()
##   （也就是说被打死的敌人**不播 die 动画**，只有清场退场才播）。
## 参数：无。
## 返回值：无。函数体里有 await，所以它实际是个协程，
##   调用方（Spawner）没有 await 它 —— 这是刻意的"发射后不管"。
## 副作用：can_move = false（立刻冻结移动）、播放 AnimationPlayer 的 "die" 动画、
##   await 动画结束后 queue_free() 自己。不 emit 任何全局信号。
## 时序 / 坑：
##   · await 期间敌人**依然在场上**（还能被玩家打到、还能走进 hurtbox 判定），只是不再移动；
##   · "die" 动画在 unit.tscn 里长 0.5 秒（上抛 + 旋转倒地），所以清场到敌人真的消失有半秒延迟；
##   · 如果这半秒内场景被切换/释放，协程中断，queue_free() 不会执行 —— 但节点随场景一起销毁了，不算泄漏；
##   · 若把本函数改成 emit on_enemy_died，清场时就会掉一地金币（目前是故意不掉的）。
func destroy_enemy() -> void:
	can_move = false
	animation_player.play("die")
	await animation_player.animation_finished
	queue_free()

## 击退计时结束回调。
## 信号来源：enemy_chaser_slow.tscn 里 KnockbackTimer.timeout → 本方法。
## 参数：无（Timer.timeout 不带参数）。返回值：无。
## 副作用：调用 reset_knockback()，把击退速度分量清掉，敌人恢复正常追击。
## 注意：KnockbackTimer 在场景里是 one_shot = true，每次击退只响一次；
##   若在击退中途被新的击退覆盖，apply_knockback() 会 stop + start 重新计时，本回调相应延后。
func _on_knockback_timer_timeout() -> void:
	reset_knockback()

## 敌人受击：先跑父类的通用流程，再补上"被打飞"。
## 信号来源：unit.tscn 里 HurtboxComponent.on_damaged → 本方法。
##   ⚠ 父类 unit.gd 里有一个**同名**函数，Godot 的信号只连到最派生类的实现上，
##   所以这里必须显式 super 调用，否则扣血、格挡、白闪、伤害飘字会统统失效（只剩击退）。
## 参数 hitbox：攻击判定框。除了父类用的 damage，这里还要读 knockback_power（力度）
##   与 source（攻击者节点，用于算击退方向）。
## 返回值：无。
## 副作用：父类的全部副作用（可能只弹格挡飘字、也可能贴白闪 + 扣血 + 伤害飘字 + 触发死亡销毁），
##   外加设置本敌人的击退状态。
## 时序 / 坑（重要）：
##   · super(...) 内部可能因为"格挡成功"或"已经死了"而提前 return，但 super() 返回后本函数会**继续往下走**，
##     结果是：① 格挡成功也会被击退（不扣血但会被顶开）；② 已经 0 血、等着被 queue_free 的敌人
##     被补刀时也会被顶开；
##   · 方向 = 攻击者 → 自己（direction_to），也就是顺着攻击方向被推开；
##     若攻击者与自己位置完全重合，direction_to 返回零向量，这次击退就没有位移（力度再大也没用）；
##   · source 是 HitboxComponent.source，近战/远程 behavior 里传的都是 weapon.get_parent()，
##     即**玩家节点**而不是武器节点 —— 所以方向永远是"从玩家指向敌人"。
func _on_hurtbox_component_on_damaged(hitbox: HitboxComponent) -> void:
	super._on_hurtbox_component_on_damaged(hitbox)
	
	if hitbox.knockback_power > 0:
		var dir := hitbox.source.global_position.direction_to(global_position)
		apply_knockback(dir, hitbox.knockback_power)


## 敌人死亡广播。
## 信号来源：enemy_chaser_slow.tscn 里 HealthComponent.on_unit_died → 本方法
##   （连接写在**敌人场景**里；unit.tscn 本身没连这个信号，所以纯 Unit 实例不会广播死亡）。
## 参数：无。
## 返回值：无。
## 副作用：emit Global.on_enemy_died(self)。Arena 订阅后据此掉金币
##   （Arena._on_enemy_died → spawn_coins.call_deferred(enemy)，金币数量取 stats.gold_drop）。
##   用 call_deferred 是为了避开"物理回调期间往场景树加节点"的限制。
## 时序：本函数被调用时敌人节点**还没被销毁** —— HealthComponent.take_damage() 的顺序是
##   先 emit on_unit_died（到这里），再 die() → owner.queue_free()，
##   所以此刻读 global_position / stats 都是有效数据，Arena 才能算出金币掉落位置。
##   注意 queue_free() 只是"排队"，真正释放在当前帧结束时。
func _on_health_component_on_unit_died() -> void:
	Global.on_enemy_died.emit(self)
