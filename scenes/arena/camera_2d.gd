# ═══════════════════════════════════════════════════════════════════════════
# Camera —— 竞技场(Arena)模式的跟随相机
# ═══════════════════════════════════════════════════════════════════════════
# 在系统里的位置：
#   本脚本挂在 scenes/arena/arena.tscn 里那唯一的 Camera2D 节点上
#   （是 arena.tscn 的直接子节点，**不是**玩家的子节点）。
#   竞技场里玩家是运行时由 Global.get_selected_player() 造出来的，Arena 事前拿不到它的
#   节点路径，所以相机没法像 world_map.tscn 那样"挂在玩家下面自动跟随"，
#   只能在 _process 里每帧手写同步。
#
# 为什么不用 parent（父节点）关系：
#   1. 玩家节点在相机之后才 add_child 进来，父子关系要在运行时接，反而更绕；
#   2. 每帧直接抄 global_position 最简单，也不用担心"重新挂父节点"带来的坐标重算。
#
# 与 world_map 的 Camera 的区别：
#   · 那边用的是 Camera2D 自带的 position_smoothing_enabled（平滑跟随 + limit 边界）；
#   · 这边是硬跟随（无平滑），镜头的唯一使命是"让玩家始终在屏幕中间"，竞技场没有边界。
#
# 坑：
#   · @onready 变量的赋值时机是 "_ready() 之前"；本文件没有 @onready，纯靠 Global 取值；
#   · Global.player 是**跨场景存活的旧引用**（切场景不会自动清空），可能已被 queue_free，
#     所以每帧必须先 is_instance_valid() 再访问，否则会报 "Invalid access to property
#     on a previously freed instance"（这就是下面那个 if 存在的原因）。

extends Camera2D
class_name Camera

# Called when the node enters the scene tree for the first time.
## 生命周期回调：本相机不需要任何初始化。
## 参数：无。返回值：无。副作用：无。
## 说明：函数体是 `pass` 占位（Godot 编辑器新建脚本时的默认模板），保留是为了
##   明确"这里确实什么都不用做"，而不是漏写。可以直接删掉，删了行为完全一样。
func _ready() -> void:
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
## 每帧把相机挪到玩家身上（硬跟随，无平滑）。
## 参数 delta：帧间隔秒数 —— 本函数**用不到**它（没有插值计算），保留只是为了符合
##   _process 的固定签名。
## 返回值：无。
## 副作用：改本节点（Camera2D）的 global_position —— 也就是唯一会动的镜头。
## 为什么不看 Global.game_paused：暂停时玩家不动，相机跟着不动，无需额外判断。
## 为什么用 is_instance_valid 而不是 `!= null`：
##   Global.player 指向的节点可能已经被释放，此时引用既不是 null 也不能访问，
##   `!= null` 判断不出来，只有 is_instance_valid() 能安全拦住。
func _process(delta: float) -> void:
	if is_instance_valid(Global.player):
		global_position = Global.player.global_position
