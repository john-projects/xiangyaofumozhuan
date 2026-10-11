# ═══════════════════════════════════════════════════════════════════════════
# Spawner —— 竞技场(Arena)的波次调度器：管两个 Timer，负责刷怪 / 计波 / 结算
# ═══════════════════════════════════════════════════════════════════════════
# 在系统里的位置：
#   本脚本挂在 scenes/arena/arena.tscn 的 Spawner(Node2D) 节点上，是 Arena 的子节点
#   （Arena 用 `@onready var spawner: Spawner = $Spawner` 取它）。
#   它**只管战斗节奏**，不管画面：飘字、金币、升级/商店面板全是 Arena 的事。
#
# 场景构成（都在 arena.tscn 里，本文件不创建）：
#   Spawner(Node2D, 本脚本)       本身是个纯逻辑节点，没有可见内容
#   ├─ SpawnTimer(Timer)          刷怪间隔。⚠ one_shot = **true**（在场景里设的，
#   │                             不是引擎默认的 false）—— 所以它每响一次就自己停，
#   │                             必须在 set_spawn_timer() 里重新 start()
#   └─ WaveTimer(Timer)           一波总时长，同样 one_shot = true
#   两个 timeout 信号都在 arena.tscn 里预连到本文件的 _on_*_timeout
#
# 一次完整的波次循环（顺一遍就懂本文件了）：
#   Arena.start_new_wave() → spawner.wave_index += 1 → spawner.start_wave()
#     → find_wave_data() 找波次配置 → WaveTimer.start() → set_spawn_timer()
#   → SpawnTimer 每次超时 → _on_spawn_timer_timeout() → spawn_enemy()
#       （先播 EnemySpawnEffect 特效，await 播完才实例化真正的敌人，最后再起 SpawnTimer）
#   → WaveTimer 超时 → _on_wave_timer_timeout()
#       → Global.game_paused = true（冻住战斗）→ 结算采集金币 → emit on_wave_completed
#       → 停 SpawnTimer → clear_enemies() → update_enemies_new_wave()（就地加强敌人模板）
#   → Arena._on_spawner_on_wave_completed() 收到信号：清场 → 等 1.5 秒 → 弹升级面板
#     → 选完升级 → 商店 → 「下一波」→ Arena._on_shop_panel_on_shop_next_wave() → 循环
#
# 数据流：waves_data(WaveData .tres) 提供每波的时长/刷怪节奏/敌人权重；
#         enemy_collection(UnitStats 数组) 是**会被就地改强的共享资源池**；
#         Global.SPAWN_EFFECT_SCENE 是出场特效场景；敌人场景来自 WaveData.units。
#
# 坑（改之前务必看）：
#   · **Timer.one_shot 引擎默认是 false**（循环计时器，is_stopped() 永远返回 false）。
#     本场景里两个 Timer 都显式设成了 true。如果谁在编辑器里把 one_shot 关掉，
#     set_spawn_timer() 里那个 `if spawn_timer.is_stopped(): start()` 就永远不会成立 ——
#     于是 wait_time 虽被改了，但计时器不会用新间隔重新计时（下一次超时仍按旧周期）。
#   · update_enemies_new_wave() **就地修改共享 Resource**：改的是 enemy_collection 里那些
#     .tres 本体，所有引用同一资源的敌人一起变强，而且这种成长**不会在重开一局时重置**。
#   · spawn_enemy() 是个协程（中间有 await），内部会先 add_child 特效、播完后 queue_free。
#   · clear_enemies() 调用的 enemy.destroy_enemy() 也是协程（播死亡动画后才 queue_free），
#     本文件不 await 它 —— 所以清场是"发起后立即返回"的。
extends Node2D
class_name Spawner

# ───────────────────────────────────────────────────────────────────────────
#  ── 数值 / 配置 ──
# ───────────────────────────────────────────────────────────────────────────
## 刷怪区域的半宽半高（像素），以 Spawner 自身位置（竞技场原点）为中心。
## 实际生成坐标 = (randf_range(-x, x), randf_range(-y, y))，也就是 x、y 各取 ±1000、±500。
## 默认 (1000, 500)：和 Player._process 里 position.x/y 的 clamp(-1000..1000 / -500..500)
## 是同一组数字 —— 刷出来的敌人一定落在玩家能走到的范围内，不会刷到"走不到的地方"。
@export var spawn_area_size := Vector2(1000, 500)
## 波次配置表（resources/waves/*.tres）。**数组顺序有意义**：
## find_wave_data() 返回第一个匹配 wave_index 的配置，区间重叠时后面的永远轮不到。
@export var waves_data: Array[WaveData]
## 会被"每波加强"的敌人属性模板池（元素是 UnitStats 资源）。
## ⚠ 这里是**就地修改**：update_enemies_new_wave() 直接改这些 Resource 的 health/damage，
##   与 GameRoot._make_enemy_team() 那种 duplicate() 出去再改的语义完全不同。
##   在 arena.tscn 里目前没有填（保持默认空数组），空数组时那个 for 循环什么都不做。
@export var enemy_collection: Array[UnitStats]

# ───────────────────────────────────────────────────────────────────────────
#  ── 对外信号（在 arena.tscn 里预连到 Arena._on_spawner_on_wave_completed）──
# ───────────────────────────────────────────────────────────────────────────
## 一波打完时 emit（Arena 收到后清场、等 1.5 秒、弹升级面板）。
signal on_wave_completed

# ── 节点引用（$ = 相对本节点的普通路径；这两个 Timer 是 arena.tscn 里的子节点）──
## 刷怪间隔计时器。one_shot = true，每次超时后必须由 set_spawn_timer() 重新 start()。
@onready var spawn_timer: Timer = $SpawnTimer
## 一波总时长计时器。one_shot = true，由 start_wave() 启动，超时即"本波结束"。
@onready var wave_timer: Timer = $WaveTimer

# ───────────────────────────────────────────────────────────────────────────
#  ── 运行时状态 ──
# ───────────────────────────────────────────────────────────────────────────
## 当前波次序号，**从 1 开始**（不是 0）。
## 初值为 1，但真正的推进在 Arena.start_new_wave()（它 += 1 后再调 start_wave()），
## 而第一波是选人完成后 Arena._on_selection_panel_on_selection_completed() 直接调
## start_wave() 开的 —— 也就是说第 1 波用的是初值 1。
## 它同时被 UI 当"波数"显示（get_wave_text）和传进升级/商店的概率计算。
var wave_index := 1
## 本波正在用的配置（find_wave_data() 的结果）。为 null 表示"没有配到任何波次"，
## 此时 _on_spawn_timer_timeout() 会直接把 SpawnTimer 停掉。
var current_wave_data: WaveData
## 本波已生成、尚未清场的敌人节点列表。clear_enemies() 遍历它逐个调 destroy_enemy()。
var spawned_enemies: Array[Enemy] = []

## 按当前波次序号从 waves_data 里挑出适用的配置。
## 参数：无（读成员 wave_index）。
## 返回值：第一个"覆盖当前波次"的 WaveData；一个都没匹配上时返回 null。
## 副作用：无（纯查找，不改任何状态）。
## 注意"第一个"：waves_data 的顺序即优先级，重叠区间里靠后的配置永远不会生效。
func find_wave_data() -> WaveData:
	for wave in waves_data:
		if wave and wave.is_valid_index(wave_index):
			return wave
	return null

## 开始一波：找配置 → 起时长计时器 → 起刷怪计时器。
## 参数：无（读 wave_index）。
## 返回值：无。
## 副作用：
##   · 写 current_wave_data；
##   · 设 wave_timer.wait_time 并 start()；
##   · 通过 set_spawn_timer() 启动 spawn_timer。
## 异常路径（很重要）：找不到配置时打印错误并**把两个计时器都停掉** —— 这是必要的，
##   否则上一波遗留的计时器会继续在"没有 current_wave_data"的状态下超时刷怪。
##   注意此时函数直接 return，**不会**再调 set_spawn_timer()（那个函数会空引用 current_wave_data）。
func start_wave() -> void:
	current_wave_data = find_wave_data()
	if not current_wave_data:
		printerr("No valid wave.")
		spawn_timer.stop()
		wave_timer.stop()
		return
	
	wave_timer.wait_time = current_wave_data.wave_time
	wave_timer.start()
	
	set_spawn_timer()
	
## 根据本波配置决定"下一次刷怪间隔"，并（在需要时）重启刷怪计时器。
## 参数：无（读 current_wave_data）。
## 返回值：无。
## 副作用：改 spawn_timer.wait_time；条件满足时 spawn_timer.start()。
## 调用时机（两处）：start_wave() 开头一次；spawn_enemy() 结尾每次刷完再排下一次。
##
## 两种模式（来自 WaveData.spawn_type）：
##   FIXED  —— wait_time 固定 = fixed_spawn_time（节奏可预测）
##   RANDOM —— wait_time = randf_range(min, max)（每次刷完重抽，节奏不可预测）
##
## 坑（这条最容易踩）：
##   末尾用的是 `if spawn_timer.is_stopped(): start()`。只有当计时器**已经停下**时才重启。
##   因为场景里 spawn_timer.one_shot = true，它每次超时后都会停，
##   所以"从超时回调里再排下一次"能正常跑起来；
##   但**如果 one_shot 被改成 false**（引擎默认值），is_stopped() 会一直返回 false，
##   这个 start() 就永远不执行 —— 新设的 wait_time 要等这一次旧的周期走完才生效，
##   表现为"刷怪间隔和配置对不上"。
##   另外在 start_wave() 里调用时，计时器也可能是"上一波遗留仍在跑"的状态（is_stopped 为 false），
##   这时它会用旧周期继续跑一轮，然后被超时回调重新排期 —— 属于既有的可接受行为。
func set_spawn_timer() -> void:
	match current_wave_data.spawn_type:
		WaveData.SpawnType.FIXED:
			spawn_timer.wait_time = current_wave_data.fixed_spawn_time
		WaveData.SpawnType.RANDOM:
			var min_t := current_wave_data.min_spawn_time
			var max_t := current_wave_data.max_spawn_time
			spawn_timer.wait_time = randf_range(min_t, max_t)
	
	if spawn_timer.is_stopped():
		spawn_timer.start()

## 在刷怪区域内随机取一个生成点。
## 参数：无。
## 返回值：相对本节点（Spawner）的**局部坐标** —— 竞技场里 Spawner 与 Arena 原点重合，
##   所以它同时也等于 Arena 坐标系下的位置。
## 副作用：推进全局随机数状态（randf_range 两次）。
## 说明：x、y 互相独立均匀分布，所以刷怪区域是一个矩形（不是圆盘）——
##   四个角落同样可能刷出怪物，这是有意的"包围感"。
func get_random_spawn_position() -> Vector2:
	var random_x := randf_range(-spawn_area_size.x, spawn_area_size.x)
	var random_y := randf_range(-spawn_area_size.y, spawn_area_size.y)
	return Vector2(random_x, random_y)

## 刷一只敌人：先播出场特效，特效演完再放真正的敌人，最后排下一次刷怪。
## 参数：无（敌人种类由 current_wave_data 按权重随机）。
## 返回值：无。
## 副作用（比较多）：
##   · get_parent().add_child(特效) —— 特效挂在 **Spawner 的父节点(Arena)** 上，不是 Spawner 下；
##     这样它不受 Spawner 的变换影响，层级上也不会被 Spawner 内部的东西遮住；
##   · 特效播完后 spawn_anim.queue_free()；
##   · new 出敌人实例、设 global_position、add_child 到 Arena，并登记进 spawned_enemies；
##   · 末尾调 set_spawn_timer() 重排下一次刷怪（所以本函数是"自续期"的循环）。
## 时序（这是本函数的关键）：
##   本函数是**协程** —— `await spawn_anim.anim_player.animation_finished` 会在这里挂起，
##   期间引擎继续跑别的逻辑（敌人仍在移动、受击）。也就是说：
##   "刷怪计时器 → 特效 0.8 秒 → 敌人才真正出现"，
##   而 set_spawn_timer() 是在**敌人出现之后**才执行的 —— 于是实际刷怪间隔会被拉长一个特效时长。
## 坑：
##   · WaveData.get_random_unit_scene() 可能返回 null（units 没配 / 权重抽到了空条目），
##     这里用 `if enemy_scene:` 兜住：本次不刷怪，但**仍然会走到末尾重排计时器**，不会卡死；
##   · 敌人先设 global_position 再 add_child：add_child 之后 global_position 会被按父节点变换重算，
##     因为 Arena 的变换是单位变换，所以结果不变；若以后给 Arena 加了位移/缩放，这里要改成局部坐标；
##   · 如果特效场景的 AnimationPlayer 被删了，这个 await 会永远等不到信号（卡住不刷怪）。
func spawn_enemy() -> void:
	var enemy_scene := current_wave_data.get_random_unit_scene() as PackedScene
	if enemy_scene:
		var spawn_pos = get_random_spawn_position()
		var spawn_anim := Global.SPAWN_EFFECT_SCENE.instantiate() as EnemySpawnEffect
		get_parent().add_child(spawn_anim)
		spawn_anim.global_position = spawn_pos
		await spawn_anim.anim_player.animation_finished
		spawn_anim.queue_free()
		
		var enemy_instance := enemy_scene.instantiate() as Enemy
		enemy_instance.global_position = spawn_pos
		get_parent().add_child(enemy_instance)
		spawned_enemies.append(enemy_instance)
	set_spawn_timer()

## 波次结算时的"敌人成长"：把模板池里的敌人**就地**变强一点。
## 参数：无（读 enemy_collection）。
## 返回值：无。
## 副作用（重）：**直接修改共享 Resource** —— enemy_collection 里每个 UnitStats 的
##   health += health_increase_per_wave、damage += damage_increase_per_wave。
## 为什么说它危险：
##   Resource 是引用语义，这些 .tres 可能同时被别的场景/别的波引用，
##   改一次**所有引用者一起变强**；而且这种成长**跨局累计**，重开游戏（重启进程才会重置）前不会回退。
##   与 GameRoot._make_enemy_team() 的做法（duplicate() 出一份副本再缩放）正好相反，别混着理解。
## 调用时机：_on_wave_timer_timeout() 的最后，也就是"下一波开始之前"。
## 说明：enemy_collection 为空时循环体不执行（arena.tscn 目前就没填）——
##   也就是说现在这条成长逻辑实际上是空转的，"变强"主要靠 GameRoot 那边按地图序号的 duplicate 缩放。
func update_enemies_new_wave() -> void:
	for stat: UnitStats in enemy_collection:
		stat.health += stat.health_increase_per_wave
		stat.damage += stat.damage_increase_per_wave

## 清掉本波所有敌人（一波结束时调用）。
## 参数：无。返回值：无（**不 await**，发起清场就返回）。
## 副作用：
##   · 对每个还活着的敌人调用 enemy.destroy_enemy() —— 那是个协程：先关 AI（can_move = false）、
##     播 "die" 动画、等动画结束再 queue_free()；本函数不等它，所以"清场"在画面上是渐进的；
##   · 清空 spawned_enemies 列表（列表清了，但节点还在演死亡动画 —— 这是刻意的，
##     避免下一波又去操作这些正在退场的节点）。
## 用 is_instance_valid() 判断的原因：敌人可能已经因为血量归零自己 queue_free 了。
func clear_enemies() -> void:
	if spawned_enemies.size() > 0:
		for enemy: Enemy in spawned_enemies:
			if is_instance_valid(enemy):
				enemy.destroy_enemy()
	spawned_enemies.clear()

## 顶部"Wave N"文字（Arena._process 每帧取一次）。
## 参数：无。返回值：形如 "Wave 3" 的字符串。副作用：无。
## 为什么用 %s 而不是 %d：wave_index 是 int，%s 会隐式转字符串，效果一样，属于原有写法。
func get_wave_text() -> String:
	return "Wave %s" % wave_index

## 本波剩余秒数（取整，Arena._process 每帧取一次）。
## 参数：无。返回值：剩余时间取整后的字符串；波次未开始时 time_left 为 0 → 返回 "0"。
## 副作用：无。
## 说明：max(0, int(...)) 是双重兜底 —— Timer 停止后 time_left 可能残留极小的负数/浮点误差，
##   直接 int() 会出现 "-0"，所以先截断再和 0 取大。
func get_wave_timer_text() -> String:
	return str(max(0, int(wave_timer.time_left)))
	

## 刷怪计时器超时回调（信号在 arena.tscn 里预连）。
## 参数：无。返回值：无。
## 副作用：调 spawn_enemy()（协程，内部会重排下一次计时器）；异常时停掉 spawn_timer。
## 两个守卫条件的含义：
##   · not current_wave_data —— 没有任何波次配置（配置被删或波次超出范围）；
##   · wave_timer.is_stopped() —— 本波已经结束（WaveTimer 已超时），此时不该再刷怪。
##   两者任一成立就停掉刷怪计时器并 return，**不会**再排下一次 —— 这是"波次结束后停止刷怪"的
##   第一道闸门（第二道是 _on_wave_timer_timeout 里主动 spawn_timer.stop()）。
## 注意：这里没有判断 Global.game_paused —— 因为波次结束后计时器已经被停掉了，
##   理论上不会在暂停期间超时。
func _on_spawn_timer_timeout() -> void:
	if not current_wave_data or wave_timer.is_stopped():
		spawn_timer.stop()
		return
	spawn_enemy()


## 一波计时结束（WaveTimer 超时）—— 本波的收尾流程，顺序不能乱。
## 参数：无。返回值：无。
## 副作用（按执行顺序）：
##   1. Global.game_paused = true —— 立刻冻住玩家/武器/敌人的 _process（"冻结逻辑"而不是
##      SceneTree.paused，所以 tween 和 Timer 照跑）；
##   2. Global.get_harvesting_coins() —— 把 player.stats.harvesting 折算成金币加进 Global.coins
##      （⚠ 该函数内部没有判空，靠"玩家一定已经实例化"这个前提，而波次计时器保证了这一点）；
##   3. emit on_wave_completed —— 通知 Arena 进入"清场 → 升级 → 商店"流程；
##   4. spawn_timer.stop() —— 停掉刷怪（若上一步 spawn_enemy 的协程还挂在 await 里，
##      它醒来后仍会再生成一只并调 set_spawn_timer()，而因为 one_shot=true
##      且 stop() 后 is_stopped() 为 true，它会重新 start() —— 这是已知的小瑕疵：
##      极少数情况下"波次结束后"还会多出一只敌人，但它会被下一波的 clear_enemies() 收掉）；
##   5. clear_enemies() —— 清掉本波残留的敌人；
##   6. update_enemies_new_wave() —— 就地加强敌人模板（见该函数的注释）。
## 注意：这里**不**推进 wave_index，也不开始下一波 —— 那由 Arena 在玩家选完升级/商店后
##   调 start_new_wave() 才做，所以"暂停 → UI → 恢复"的节奏掌握在 Arena 手里。
func _on_wave_timer_timeout() -> void:
	Global.game_paused = true
	Global.get_harvesting_coins()
	on_wave_completed.emit()
	spawn_timer.stop()
	clear_enemies()
	update_enemies_new_wave()
