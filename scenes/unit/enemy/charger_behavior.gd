## ═══════════════════════════════════════════════════════════════════════════
## ChargerBehavior —— 冲撞型敌人的行为脚本（"蓄力 → 直线冲刺 → 冷却"）
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   挂在 enemy_charger.tscn 的 "ChargerBehavior" 节点上（那个场景的根 EnemyCharger 继承自
##   enemy_chaser_slow.tscn，也就是 Enemy + Unit 那一套）。
##   它**不是** Unit 的子类，而是一个旁挂的 Node2D 组件：@export enemy 指回宿主敌人，
##   状态机全在自己 _process 里跑；敌人的常规追击由 enemy.can_move 这个开关让位。
##   对照：ShootingBehavior（远程敌人）结构几乎一样 —— 冷却 → 到点执行动作 → 借用 can_move 站桩。
##
## 本文件负责什么：
##   周期性地"锁定玩家当前位置 → 播蓄力动画 → 以 5 倍速度直线冲过去 → 到位后进入冷却"。
##   冲撞期间的伤害判定不在本文件里 —— 靠敌人自带的 HitboxComponent 撞到玩家触发。
##
## 数据流：
##   Global.player.global_position → 冲撞目标点（**开冲前锁定一次**，冲的过程中不再修正，
##     所以玩家只要走开就能躲掉 —— 这是设计意图）
##   @export anim_effects（enemy_charger.tscn 里的独立节点 AnimationEffects，
##     只含 "charge" 与 "RESET" 两条动画，和宿主敌人的主 AnimationPlayer 是两套东西）
##     → play("charge")，并 await animation_finished 当作"蓄力时长"
##   enemy.stats.speed → 冲撞速度基数（实际用它的 5 倍）
##   enemy.can_move ← 本脚本写；Enemy._process 读（false 时敌人不走常规追击）
##
## 坑（改之前务必看）：
##   · 本脚本的 _process **没有**检查 Global.game_paused（Enemy / Player / Weapon 都检查了）：
##     商店、升级面板打开期间，冷却计时与冲撞位移照样推进 —— 表现为"暂停时敌人还在自己滑"，
##     这是现存行为，不是本文件注释写错；
##   · start_charge() 含 await，是个协程；_process 里调用它**没有 await**，
##     于是冷却被重置之前会每帧重复调用它（实测不会卡住，但会留下"隐藏地雷"，见 start_charge）；
##   · prep_time 声明了却没有任何代码读取它（实际蓄力时长由动画长度决定）。
extends Node2D
class_name ChargerBehavior

## ── 引用（enemy_charger.tscn 用 node_paths 绑定；改节点结构要同步改场景）───────
## enemy：宿主敌人，场景里填 NodePath("..") 即 EnemyCharger 根节点。
##   本文件里只做 null 判空（防呆）。注意它是**强类型 Enemy**，
##   挂到不是 Enemy 的节点上会在场景加载时类型检查失败。
@export var enemy: Enemy
## anim_effects：蓄力动画播放器，场景里指向兄弟节点 AnimationEffects。
##   与宿主敌人的主 AnimationPlayer（idle/move/die）完全独立，互不干扰。
@export var anim_effects: AnimationPlayer
## ── 数值 ────────────────────────────────────────────────────────────────
## 蓄力时长（秒）。⚠ **声明了但全工程没有任何代码读取**（历史遗留/预留参数）：
## 实际蓄力时长 = AnimationEffects 里 "charge" 动画的长度（enemy_charger.tscn 中为 0.7 秒）。
## 改这个值不会有任何效果；要调蓄力时间请改动画长度，或把本值接入 await 逻辑。
## 默认 1.0 只是"看起来像个合理的蓄力秒数"。
@export var prep_time := 1.0
## 冲撞结束后的冷却时间（秒），默认 3.0（enemy_charger.tscn 没有覆盖它，用的是这个脚本默认值）。
## 用它自己按 delta 递减（current_cooldown -= delta），没有用 Timer —— 好处是能随暂停逻辑一起被冻结
## （但本脚本又没检查 game_paused，所以实际并不受暂停影响）。
## 调小 → 冲得更频繁；调到 0 → 冷却一结束就立刻再冲（会放大 start_charge 的每帧重入现象）。
@export var cooldown := 3.0

## ── 状态 ────────────────────────────────────────────────────────────────
## 距下一次可以冲撞还剩多少秒。由 _ready() 初始化成 cooldown，所以敌人**刚生成时不会立刻冲**，
## 要先等满一个完整冷却；冲撞结束时由 end_charge() 重新赋值。
var current_cooldown := 0.0
## 本次冲撞的目标点（世界坐标）。⚠ 它并不是"决定要冲的那一帧"就锁死的：
## 蓄力期间 _process 每帧都在刷新它，所以真正定格的时刻是**蓄力动画播完那一帧的玩家位置**
## （is_charging 置 true 之后 _process 改走冲撞分支，就再也不会更新它了）。
## 也就是说蓄力过程中玩家一直在"被瞄准"，动画一结束才锁定 → 之后走开就能躲掉。
var charge_attack_position := Vector2.ZERO
## 是否处于"冲撞位移"阶段。true → _process 走冲向目标点分支；
## false → 走"冷却倒计时 / 蓄力"分支。注意蓄力期间它是 false（置位发生在 await 之后）。
var is_charging := false

## 生命周期钩子（extends Node2D，父类没有脚本，不需要 super 调用）。
## 参数/返回值：无。
## 副作用：把 current_cooldown 设成 cooldown，即"出场自带一个完整冷却"。
## 时机：Godot 保证导出属性（enemy / anim_effects，由场景的 node_paths 绑定）在 _ready() 之前
##   就已经赋好值，所以这里若要用 enemy 是安全的；本文件没用到而已。
## _ready() 也早于第一次 _process()，所以敌人不会一出生就冲出去。
func _ready() -> void:
	current_cooldown = cooldown

## 冲撞状态机（每帧调用）。
## 参数 delta：距上一帧的秒数（引擎传入）。注意它只用于"冷却递减"和"冲撞步长"，与帧率无关。
## 返回值：无。
## 副作用：
##   · 冲撞中**直接修改 enemy.global_position** —— 绕过 Enemy._process 的追击、绕过击退分量、
##     也绕过"离玩家 60 像素就停"的限制（也就是说冲撞可以糊到玩家脸上）；
##   · 通过 start_charge()/end_charge() 读写 is_charging 与 enemy.can_move；
##   · 让 anim_effects 播放动画。
## 两个分支：
##   【冲撞中】global_position.move_toward(目标点, enemy.stats.speed * 5 * delta)：
##     每帧最多前进 speed*5*delta 像素 —— 固定 5 倍速的匀速直线运动（5 这个倍数写死在表达式里，
##     想让冲撞更猛就改这里）；与目标点距离 < 50 像素即视为到达，调 end_charge()。
##   【非冲撞】先 current_cooldown -= delta；归零后检查 Global.player 是否有效，
##     把玩家**当前**位置记为冲撞终点，然后 start_charge()。
##     注意：冷却在蓄力期间一直是 <= 0 的（end_charge() 才重置它），
##     所以蓄力动画播放的每一帧都会再执行一遍"刷新目标点 + start_charge()"。
## 时序 / 坑（重要）：
##   · "到了没有"用 < 50 像素的接近判据而不是相等：move_toward 在剩余距离不足一步时会**正好落到目标点**，
##     理论上可以判 ==，但 50 像素的容差是为了让"玩家挪了一点、目标点稍微错过"时也能收招，
##     避免绕着目标点来回微调；
##   · start_charge() 是协程，这里调用它**没有 await**（发射后不管），于是蓄力期间会每帧调用一次。
##     实测（Godot 4.7.2）：对**同一个**动画重复 play() 是无操作，不会重启动画、也不会吞掉
##     animation_finished —— 所以蓄力不会卡住，这个写法"能跑"。
##     但它每帧都会新建一个挂在 await animation_finished 上的协程，等到动画结束的那一瞬间
##     **全部一起恢复**，于是 start_charge() 尾巴上的语句会被重复执行 N 遍（当前只有一句
##     `is_charging = true`，无害）。以后若在它后面加"只应发生一次"的动作
##     （扣冷却、发信号、生成特效、播别的动画），就会一次触发几十遍 —— 这是留给后人的地雷；
##   · 冲撞分支只判了 enemy == null，没有 is_instance_valid：真被释放时，
##     ChargerBehavior 作为敌人的子节点会一起被释放，Godot 不会再对已释放节点调用 _process，所以不会崩；
##   · enemy.stats 在冲撞分支被读取：stats 为 null（场景没填 .tres）会报错，不是本文件的锅。
func _process(delta: float) -> void:
	if enemy == null:
		return
	if is_charging:
		# 冲撞位移：每帧最多走 (speed * 5 * delta) 像素，朝锁定好的目标点直线逼近。
		# 这里直接改 global_position，因此不受 Enemy._process 的 can_move / 击退 / 60 像素停止距离影响。
		enemy.global_position = enemy.global_position.move_toward(charge_attack_position, (enemy.stats.speed * 5) * delta)
		# 用 50 像素的接近容差判"到位"：move_toward 步长不足时会精确落到目标点，容差是为了宽容"目标点稍微错过"。
		if enemy.global_position.distance_to(charge_attack_position) < 50:
			end_charge()
	else:
		if current_cooldown > 0:
			current_cooldown -= delta
		else:
			# 到这里说明冷却已归零。玩家引用可能失效（旧的一局结束后 Global.player 会残留旧节点），
			# 所以必须先 is_instance_valid —— 否则下一次访问 global_position 会报错。
			if is_instance_valid(Global.player):
				charge_attack_position = Global.player.global_position
				start_charge()

## 开始蓄力。⚠ 本函数含 await，是**协程**，不是同步函数。
## 参数：无。
## 返回值：无（调用方拿到的是协程对象；本文件里没有任何地方 await 它）。
## 副作用：
##   · enemy.can_move = false —— 立刻冻结宿主敌人的常规追击（Enemy._process 下一帧就会提前 return）；
##   · anim_effects.play("charge") 播放蓄力动画（0.7 秒的红白闪烁，定义在 enemy_charger.tscn）；
##   · await animation_finished 之后把 is_charging 置 true —— 所以"蓄力阶段"和"冲撞阶段"是两回事，
##     is_charging 只代表后者。
## 时序要点：
##   · can_move = false 在**动画开始之前**就设好了，整个蓄力期敌人都不会自己走；
##   · is_charging 在 await **之后**才置位：await 期间 _process 仍在每帧运行，
##     并且因为 current_cooldown 已经 <= 0，会反复进入"该冲了"分支再次调用本函数
##     （见 _process 里的坑说明：重复 play 同一动画是无操作，所以动画能正常播完，
##     代价是每帧都新建一个协程，它们会在动画结束的瞬间一起恢复）；
##   · 若宿主敌人在 await 期间被 queue_free（死亡/清场），它发出的信号连接会被断开，
##     这个协程就再也不会恢复 —— 不会访问已释放对象，代价是它永远停在那儿（无害，节点已销毁）。
## 为什么蓄力时长不用 prep_time：见 prep_time 的注释 —— 那个导出值没有被任何代码读取。
func start_charge() -> void:
	# 先冻结敌人的常规追击，再播动画：顺序反过来的话，动画第一帧敌人还会往前挪一点。
	enemy.can_move = false
	# 播放蓄力动画（0.7 秒）。对同名动画的重复 play() 是无操作（实测），所以每帧重入不会打断它。
	anim_effects.play("charge")
	# await 让出控制权：本协程在此挂起，直到动画播完才继续执行下面那行。
	# 正因为它挂起了，_process 里"没 await 就调用"的写法才不会阻塞游戏主循环。
	# ⚠ 信号是按"发射一次唤醒所有等待者"工作的：这一帧有 N 个协程在等，动画结束时 N 个都会醒来。
	await anim_effects.animation_finished
	# 动画结束 = 蓄力完成，从这里开始才算"冲撞中"。重复恢复时这句会被执行多次（幂等，无害）。
	is_charging = true

## 结束冲撞：复位状态并把移动权还给敌人。
## 参数：无。
## 返回值：无。
## 副作用（三行都是写状态，没有信号）：
##   · is_charging = false —— 下一帧 _process 回到"冷却/蓄力"分支；
##   · current_cooldown = cooldown —— **重置冷却**，下一次冲撞要再等一整个 cooldown；
##   · enemy.can_move = true —— Enemy._process 恢复追击。
## 由谁调用：只有本文件 _process 里"距离目标点 < 50 像素"那一处（同步调用）。
## 坑：can_move 是无条件置 true 的 —— 如果冲撞期间敌人正在被别的机制冻结
##   （比如刚被 Shot 的 ShootingBehavior 借走，或后续新增了别的行为脚本），
##   这里会把那份冻结一起解除。多个行为脚本共用同一个 can_move 标志，属于已知的设计耦合。
func end_charge() -> void:
	# 先退出"冲撞中"状态，再重置冷却，最后解冻移动 —— 顺序不影响正确性，但这样读起来是"收招三步"。
	is_charging = false
	current_cooldown = cooldown
	# 无条件解冻：如果这期间别的行为脚本也借用了 can_move，这里会把它的冻结一起解除（已知耦合）。
	enemy.can_move = true
