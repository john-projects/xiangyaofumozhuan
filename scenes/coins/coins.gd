# ═══════════════════════════════════════════════════════════════════════════
# Coins —— 敌人死亡后掉落的金币（会自己飞向玩家 / 钱包的 Area2D）
# ═══════════════════════════════════════════════════════════════════════════
# 在系统里的位置：
#   竞技场(Arena)玩法专用。完整链路：
#     敌人血量归零 → Enemy._on_health_component_on_unit_died() emit Global.on_enemy_died
#       → Arena._on_enemy_died() 用 call_deferred 调 Arena.spawn_coins(enemy)
#         → 本文件（Global.COINS_SCENE 实例化出来的）add_child 到 Arena 下开始 _process
#         → 玩家碰到（area_entered）置 collected = true → 飞向玩家 → 距离够近就 add_coins()
#           → 直接改 Global.coins += value 并 queue_free() 自己
#
#   另一条"飞向目标点"的路径：一波打完时 Arena.clean_arena() 会调用
#   set_collection_target(钱包中心的世界坐标)，把场上没捡完的金币一次性吸进 CoinsBag 位置。
#
# 场景构成（scenes/coins/coins.tscn）：
#   Coins(Area2D, 本脚本)    collision_layer = 0、collision_mask = 默认值 1（见下面的碰撞说明）
#   Shadow / AnimatedSprite2D(旋转金粒动画, autoplay="default")
#   CollisionShape2D(CircleShape2D, radius ≈ 92)  ← 拾取范围，比视觉大很多，方便玩家吃到
#   场景里预连了 `area_entered → _on_area_entered`（所以本文件不需要自己 connect）
#
# 碰撞方向（很容易搞反，必须看清）：
#   Area2D 的判定方向是"我（mask）去检测别人（layer）"：
#   · coins.tscn 里 collision_layer = 0 —— 金币**不在任何层上**，
#     所以没有任何别的 Area 能检测到金币（玩家那侧的 area_entered 不会因金币触发）；
#   · coins.tscn 没写 collision_mask → 用 Area2D 默认的 1，也就是金币检测"第 1 层"的 Area；
#     而玩家根节点 Unit(Area2D) 恰好就在第 1 层（unit.tscn 没改 layer，玩家场景只覆盖了 mask = 2）；
#   · 结论：是**金币检测到玩家**，然后触发**挂在金币自己身上**的 area_entered → _on_area_entered。
#   改层/掩码时务必保持这条对应关系，改错了金币就永远捡不起来（而且不会报任何错）。
#
# 数据流：value 由 Arena.spawn_coins() 从 enemy.stats.gold_drop 写入；
#         最终去处是 Global.coins（CoinsBag 每帧把它显示出来）。
#
# 坑（这一条接口设计得比较绕，务必看清）：
#   · **target_pos 的零值 (0,0) 被当成"还没设过目标"的哨兵**（见 _process 里那个
#     `if target_pos != Vector2.ZERO`）。后果：金币刚生成、还没被碰到的那段时间，
#     target_pos 是 (0,0)，于是 move_toward() 会把金币往**世界原点（画面左上方向）**拖 ——
#     这是刻意保留的"小碎步抖向原点"表现，不是"静止待拾"；
#   · 距离判定 `distance_to(target_pos) < collect_distance` 在 target_pos 为 (0,0) 时
#     仍然成立（只要金币飘到原点附近就会自动进账），所以远处没捡的金币最终也会被收走；
#   · add_coins() 只是一句 `Global.coins += value` —— **没有防重复调用**，靠随后的
#     queue_free() 让它活不过这一帧末；但它一帧内确实会被调用多次（无害，因为只在
#     那一次调用里 queue_free 后就不再处理）。

extends Area2D
class_name Coins

# ───────────────────────────────────────────────────────────────────────────
#  ── 数值 ──
# ───────────────────────────────────────────────────────────────────────────
## 飞行速度，单位「像素/秒」（世界坐标）。默认 1000.0 偏快：
## 金币是"即时反馈"，慢了会显得拖沓；再快就看不到飞行过程了。
@export var move_speed := 1000.0
## 判定"到达目标"的距离阈值，单位像素。默认 15.0（约半个金币大小）：
## 太大会导致还差一截就消失（视觉突兀），太小则可能因单帧位移 >5px 而"抖动着追不上"。
@export var collect_distance := 15.0

# ───────────────────────────────────────────────────────────────────────────
#  ── 运行时状态 ──
# ───────────────────────────────────────────────────────────────────────────
## 这枚金币值多少（会被整份加进 Global.coins）。由 Arena.spawn_coins() 从
## enemy.stats.gold_drop 写入；默认 1 只是为了"手动丢一个 Coins 也有意义"。
var value := 1
## 目标点的**屏幕坐标**（不是世界坐标！）。由 Arena.clean_arena() 通过
## set_collection_target() 传入（钱包中心）。Vector2.INF = "没有这个目标"（哨兵值）。
## 为什么用屏幕坐标：钱包(CoinsBag)是 CanvasLayer 上的 UI 控件，它的 global_position
## 属于 UI 坐标系，不能直接和世界坐标混用 —— 必须每帧用 canvas_transform 反算（见 _process）。
var target_screen_pos := Vector2.INF
## 每帧真正用来 move_toward 的目标点（**世界坐标**）。两个来源：
##   · 被玩家碰到后 → Global.player.global_position；
##   · target_screen_pos 有效时 → 由屏幕坐标反算出的世界坐标（优先级更高）。
## 注意它默认是 (0,0)，而 (0,0) 在本文件里同时充当"尚未设置"的哨兵 —— 见文件头部的坑。
var target_pos: Vector2
## 是否已被玩家碰到（由 area_entered 置 true）。为 true 后金币才开始"追着玩家跑"。
var collected := false

## 每帧驱动：确定目标点 → 朝目标飞 → 到了就进账。
## 参数 delta：帧间隔（秒），用来把速度换算成本帧位移。
## 返回值：无。
## 副作用（比较重，注意）：
##   · 改本节点的 global_position（每帧都在移动）；
##   · 可能调用 add_coins() → **直接修改 Global.coins** 并 queue_free() 掉本节点自己。
##
## 三段逻辑：
##   1) 刚被碰到、且还没有其它目标时，把目标设成玩家的世界坐标 —— 之后就一直追着玩家；
##      用的是 is_instance_valid(Global.player) 而不是 != null：Global.player 是跨场景
##      存活的旧引用，玩家可能已被 queue_free，只有 is_instance_valid 能安全拦住；
##   2) target_screen_pos 有效（一波结算时被吸向钱包）时，用
##      get_canvas_transform().affine_inverse() 把"屏幕坐标"反变换回"世界坐标"，
##      覆盖掉第 1 步的目标 —— 所以两条路径同时存在时，钱包优先于玩家；
##   3) move_toward 是"朝目标走固定步长"（步长 = 速度 × delta），不会过冲，
##      比"每帧赋 position = target"更有飞行过程感；到达阈值内就进账。
##
## 为什么是 affine_inverse() 乘法而不是别的：
##   canvas_transform 是"世界 → 屏幕"的变换矩阵，求逆后乘屏幕坐标即得世界坐标；
##   每一帧都重算，是因为相机在移动，这个变换随时在变。
func _process(delta: float) -> void:
	# ① 被玩家碰到后开始追玩家。只设一次（之后的帧 target_pos 已经不是零值了）。
	if collected and target_screen_pos == Vector2.INF:
		if is_instance_valid(Global.player):
			target_pos = Global.player.global_position
	
	# ② 一波结算时被吸向钱包：屏幕坐标 → 世界坐标，覆盖上面的玩家目标。
	if target_screen_pos != Vector2.INF:
		target_pos = get_canvas_transform().affine_inverse() * target_screen_pos

	# ③ 向目标推进。（target_pos 为 (0,0) 时也会执行 —— 这是"未设置"哨兵带来的既有行为）
	if target_pos != Vector2.ZERO:
		global_position = global_position.move_toward(target_pos, move_speed * delta)
		
	# ④ 到达即进账。注意：这个判断**不受 target_pos 是否为 (0,0) 影响**，
	#    所以停在世界原点附近的金币也会自动被收走（防止"漏捡的金币永远躺在地上"）。
	if global_position.distance_to(target_pos) < collect_distance:
		add_coins()

## 进账：把钱加进全局金币，然后销毁自己。
## 参数：无。返回值：无。
## 副作用：
##   · **直接修改 Global.coins**（因此 CoinsBag 的下一个 _process 就会显示新数额，无需通知）；
##   · queue_free() 掉本节点（帧末真正释放）—— 之后本节点的 _process 不会再被调用。
## 坑：
##   · 没有防重入标记：_process 在同一帧内可能多次进入本函数（例如 ④ 每帧都成立），
##     之所以看不出问题，是因为 queue_free() 之后本帧不会再被 _process 调度；
##   · 不 emit 任何信号，也不判 is_inside_tree，所以即使节点已在退场队列里调用它也是安全的；
##   · 运行时 new 出来的节点 owner 为 null —— 这里用的是 queue_free() 而不是
##     owner.queue_free()，后者在这种情况下会直接失败。
func add_coins() -> void:
	Global.coins += value
	queue_free()

## 设置"最终吸收目标"（一波打完时 Arena 把金币吸进钱包用）。
## 参数 screen_pos：目标点的**屏幕坐标** —— 调用方传的是
##   `coins_bag.global_position + coins_bag.size / 2.0`（钱包控件的中心）。
##   之所以传屏幕坐标而不是世界坐标：钱包是 CanvasLayer 上的 UI，其 global_position
##   属于 UI 坐标系，只能靠 _process 里的 canvas_transform 反算成世界坐标。
## 返回值：无。副作用：只写 target_screen_pos（把哨兵 INF 换成真实值，从而启用第 ② 段逻辑）。
## 注意：设置之后是本文件的 _process 负责飞行，Arena.clean_arena() 只是"下命令"就走。
func set_collection_target(screen_pos: Vector2) -> void:
	target_screen_pos = screen_pos


## 拾取判定回调（信号在 coins.tscn 里预先连好：area_entered → 本函数）。
## 参数 area：被本节点的碰撞形状检测到的另一个 Area2D —— 按默认掩码，它应该就是
##   玩家的根节点 Unit(Area2D)（第 1 层），见文件头部的"碰撞方向"说明。
##   本函数不检查它到底是谁，也就是说**任何**进了拾取圈的 Area（且层号命中 mask）都会让
##   金币开始飞向 Global.player —— 以后若加了别的 Area（例如某种立场），要留意这一点。
## 返回值：无。副作用：collected = true（于是下一帧 _process 的第一段开始追玩家）。
## 为什么这里不直接 add_coins()：
##   直接加钱会显得"金币凭空消失"，先让金币飞过去再进账，反馈手感更好。
## 注意：这个回调在**物理帧**里被调用；本函数只改一个 bool，没有动碰撞形状/层掩码，
##   所以不需要 set_deferred —— 若以后要在这里改 collision_layer/mask 或 disabled 之类，
##   就必须用 set_deferred（物理回调期间改碰撞状态会被引擎拒绝并报错）。
func _on_area_entered(area: Area2D) -> void:
	collected = true
