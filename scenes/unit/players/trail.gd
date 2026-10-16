## ═══════════════════════════════════════════════════════════════════════════
## Trail —— 冲刺拖尾（Line2D 的子类）：把玩家的移动轨迹画成一条渐细的尾巴
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   挂在玩家场景的 "Visuals/Trail" 节点上（player_well_rounded.tscn），节点类型 Line2D + 本脚本；
##   线宽用场景里配好的 width_curve（两端 0→1 的 Curve）做"头粗尾细"的观感。
##   冲刺开始时由 Player.start_dash() 调 start_trail() 打开，到点由 TrailTimer 自动关闭。
##
## 本文件负责什么：
##   激活期间每帧把玩家的**世界坐标**采样进一个点列表，再整体交给 Line2D 渲染。
##   它不改位移、不参与碰撞、不发信号 —— 纯表现。
##
## 数据流：
##   Player.start_dash() → start_trail()（激活 + 清点 + 启动计时器）
##   @export player: Player（场景里用 node_paths 绑成 NodePath("../..")）
##     → 每帧读它的 global_position 作为采样点
##   %TrailTimer（**挂在玩家根节点上**，不是 Trail 的子节点）→ timeout → _on_trail_timer_timeout() 收尾
##   points_array（Array[Vector2]）→ 每帧赋给 Line2D.points（PackedVector2Array，渲染用）
##
## 坑（改之前务必看）：
##   · Trail 在场景里设了 **top_level = true**，这一点是必须的：采样用的是世界坐标，
##     而 Trail 挂在 Visuals 下，Visuals 有 0.5 的缩放、并且会被负 X 缩放镜像 ——
##     没有 top_level 的话，轨迹会被缩小一半，玩家一转身整条尾巴还会水平翻过去；
##   · %TrailTimer 是"场景唯一名"，注册在**玩家场景的 owner** 上，
##     所以从孙节点 Trail 里也能用 % 直接取到 —— 代价是本脚本离不开玩家场景；
##   · 本脚本不检查 Global.game_paused（纯视觉，无所谓），但 Timer 不受暂停影响，
##     所以暂停期间计时器照样到点把拖尾清掉。
extends Line2D
class_name Trail

## ── 引用与数值 ──────────────────────────────────────────────────────────
## 拖尾跟随的对象。场景里绑的是 NodePath("../..") —— Trail 的父是 Visuals、祖父才是玩家，
## 所以是两个 ".."；绑错的话 _process 从第一帧起就会因 null 报错。
@export var player: Player
## 点列表最大长度（保留多少个采样点），默认 25。
## 超出后从**头部**丢最老的点（pop_front），形成滑动窗口 —— 尾巴尖端随之前进、尾根被截断。
## 值越大尾巴越长越平滑，代价是每帧重建 PackedVector2Array 的元素更多。
@export var trail_length:= 25
## 拖尾持续时间（秒），默认 1.0。start_trail() 里作为 trail_timer.start(time) 的时长。
## ⚠ 场景没有覆盖它，而玩家的 dash_duration = 0.5 —— 所以冲刺结束后尾巴还会多飘约 0.5 秒才消失。
@export var trail_duration:= 1.0
## 采样最小间距（像素），**不是 @export**（硬编码 5.0）：
## 新点与"上一个记录点"的距离小于它就不记录。
## 作用：玩家原地不动或轻微挪动时不会往数组里堆大量重复点（否则 25 个点会瞬间被填满）。
## 它只影响采样密度，不控制尾巴的长短粗细。
var min_distance := 5.0
## 拖尾计时器。⚠ 它在玩家**根节点**上（player_well_rounded.tscn 里的 TrailTimer，one_shot = true），
## 靠"场景唯一名"从孙子节点访问它 —— 不是 Trail 的子节点。
@onready var trail_timer: Timer = %TrailTimer

## ── 状态 ────────────────────────────────────────────────────────────────
## 自己维护的点列表（世界坐标）。用 Array[Vector2] 而不是 PackedVector2Array，
## 因为要频繁 append / pop_front；每帧再整体转换给 Line2D.points。
## 语法提醒：Array[Vector2] 是**类型**，只能写在冒号后面（var x: Array[Vector2]），
## 写成 `= Array[Vector2]` 会解析报错。
var points_array: Array[Vector2] = []
## 是否正在记录轨迹。false 时 _process 第一行就 return（不采样、也不刷新渲染点）。
var is_active := false


## 生命周期钩子。本类 extends Line2D（引擎内建类，没有脚本父类），所以不需要 super._ready()。
## 参数/返回值：无。副作用：无 —— 函数体是空的（原作者留的占位）。
## 时序：@onready 变量（trail_timer）在本函数被调用**之前**就已赋值，所以以后往这里写逻辑也能用它。
## 注意：这个空的 _ready() 删掉也不影响行为，保留它只是为了以后加初始化逻辑方便。
# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.


## 每帧采样：把玩家当前位置追加进点列表，并刷新 Line2D 的渲染点。
## 参数 delta：距上一帧的秒数。⚠ 这里**完全没用它** —— 采样是"每帧一次"而不是"按时间间隔"，
##   所以帧率越高采样越密。这也正是用 min_distance（距离）而不是用时间做过滤的原因。
## 返回值：无。
## 副作用：写 points_array（append，可能再 pop_front）与 Line2D.points；
##   不 emit 信号、不碰其他节点、不检查 Global.game_paused。
## 流程：
##   1) 未激活 → 直接 return；
##   2) 取 player.global_position（**世界坐标**，这是 Trail 必须 top_level 的根本原因）；
##   3) 与列表末尾的点比较距离，太近（< min_distance）就结束本帧、不记点；
##   4) append 新点；超过 trail_length 就把最老的点 pop_front 掉；
##   5) 把整个数组赋给 Line2D.points，交给渲染。
## 坑：
##   · points_array[-1] 是"最后一个元素"（负下标从尾部数，等价于 size() - 1）；
##     对**空数组**取 -1 会越界报错，所以外面那层 is_empty() 判断不能省；
##   · `points = points_array` 每帧都做一次 Array[Vector2] → PackedVector2Array 的隐式转换
##     （等于整表拷贝 + 每帧分配）。最多 25 个点，开销可忽略，但要知道 points 和 points_array
##     是**两份数据**：清空时两个都得清（见 start_trail / _on_trail_timer_timeout）；
##   · 采样点是玩家的节点原点（脚底），不是 sprite 位置，所以尾巴贴地；配合场景里
##     Trail 的 position 偏移和 width_curve，得到"地面拖影"的观感。
# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta: float) -> void:
	if not is_active:
		return

	# 取世界坐标：Line2D 自己 top_level = true（脱离父变换），所以这里必须给世界坐标而不是局部坐标。
	var current_pos = player.global_position
		# 如果数组不为空，检查当前位置和上一个记录的点距离够不够远
	if not points_array.is_empty():
		# 负下标从尾部数：points_array[-1] 就是最后追加的那个点，也就是尾尖的上一帧位置。
		var last_pos = points_array[-1]
		# 如果移动距离太小，直接结束这一帧，不记录点
		if current_pos.distance_to(last_pos) < min_distance:
			return
	# 注意 append 的是重新读一次 player.global_position（而不是上面缓存的 current_pos）——
	# 同一帧内两者相等，但这么写能保证"记录的点"永远和判断距离时用的是同一个值。
	points_array.append(player.global_position)
	# 滑动窗口：超过上限就从**头部**丢最老的点，保证尾巴只保留最近 trail_length 个采样点。
	if points_array.size() > trail_length:
		points_array.pop_front()
	
	# 每帧整表赋值：Array[Vector2] → PackedVector2Array 的隐式转换，Line2D 就是按这个数组顺序画线的。
	points = points_array
	
## 开始记录拖尾（由 Player.start_dash() 在冲刺开始那一刻调用）。
## 参数：无。返回值：无。
## 副作用：is_active = true、clear_points()（清 Line2D 的渲染点）、points_array.clear()、
##   trail_timer.start(trail_duration)（重启计时器）。
## 为什么两份数据都要清：Line2D.points 与 points_array 是两份东西，
##   只清其中一份，下一帧 `points = points_array` 就会把旧点重新灌回渲染里，
##   表现为"上一条尾巴瞬间回魂"。
## 时序 / 坑：
##   · start(time) 的语义是"先设 wait_time 再 start"，所以不必单独写 wait_time；
##   · TrailTimer 在场景里是 one_shot = true → 只响一次，超时后由 _on_trail_timer_timeout() 收尾，
##     这里不需要 stop()；
##   · 冷却很短时连续冲刺会反复调用本函数：每次都清空并重启计时，尾巴是"重新拉一条"而不是续上一条。
func start_trail() -> void:
	is_active = true
	clear_points()
	points_array.clear()
	trail_timer.start(trail_duration)

## 拖尾结束回调。
## 信号来源：player_well_rounded.tscn 里 TrailTimer.timeout → 本方法
##   （连接的目标节点是 "Visuals/Trail"，不是玩家根节点 —— 见场景文件末尾的 [connection]）。
## 参数：无（Timer.timeout 不带参数）。返回值：无。
## 副作用：is_active = false、clear_points()、points_array.clear()。
## 之后 _process 每帧仍会被调用，但第一行就 return（几乎零开销）。
## 注意：这里是**立刻清空**，所以尾巴是"啪"地消失，而不是渐渐缩短/淡出；
##   想让它自然收尾得改逻辑（本注释只描述现状）。
func _on_trail_timer_timeout() -> void:
	is_active = false
	clear_points()
	points_array.clear()
	
