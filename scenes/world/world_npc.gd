# ═══════════════════════════════════════════════════════════════════════════
# WorldNPC —— 世界地图上的一个 NPC（纯"表现 + 数据容器"，几乎没有自己的逻辑）
# ═══════════════════════════════════════════════════════════════════════════
# 在系统里的位置：
#   本脚本是 scenes/world/world_npc.tscn 的根脚本。它不是自动加载的，
#   而是由 WorldMap._add_npc() 用 preload 的 NPC_SCENE 实例化后 add_child 到
#   WorldMap 下面的（WorldMap 开了 y_sort_enabled，所以玩家能绕到 NPC 前面/后面）。
#
# 职责边界（很重要）：
#   · 本文件**不做**距离判定、不做输入处理、不做传送 —— 那些全在 WorldMap 里；
#   · 本文件只负责两件事：把 MapNPC 数据画出来（setup），以及切换"高亮"表现（set_highlight）。
#   这样拆是为了让"谁离玩家最近""能不能交谈"这类全局判断只有一个地方（WorldMap）。
#
# 场景节点构成（都是 unique_name_in_owner，所以脚本里用 % 取）：
#   Shadow(Polygon2D)   脚下的椭圆阴影（场景里预置，本脚本不碰）
#   Fallback(Polygon2D) 金色方块占位，MapNPC.texture 为空时显示
#   Sprite(Sprite2D)    NPC 立绘，scale 在场景里设为 1.3
#   NameLabel(Label)    NPC 名字，位置在头顶（offset_top 为负）
#   Mark(Label)        "按 E 交谈"提示，默认 visible = false，高亮时才显示
#
# 数据流：MapNPC(.tres 资源) → WorldMap._add_npc() → npc.setup(data) → 本文件的显示逻辑。
#         本文件只**读** data，从不修改它（就地改 .tres 资源会污染所有引用同一资源的 NPC）。
#
# 坑：
#   · setup() 必须在 add_child 之后调用 —— 它要访问 @onready 变量（%Sprite 等），
#     而 @onready 是在节点 _ready() 之前才赋值的，早于进树调用会拿到 null。
#   · set_highlight() 每次都会 create_tween()，如果每帧调用会不断堆积 tween；
#     所以 WorldMap._update_nearest() 只在"最近 NPC 真的换了"时才调用它。

extends Node2D
class_name WorldNPC

## 地图上的 NPC：显示立绘/名字，玩家靠近时高亮提示可以交谈
## 位置与行为由 WorldMap 决定（WorldMap 负责距离判定和交互）

## 高亮时的缩放倍率（倍）。1.1 = 放大 10%，足够让玩家注意到，又不至于顶到别的 NPC。
## 注意：缩放的基准是 self（整个 NPC 节点），所以名字标签和提示标记也会跟着一起放大。
const HIGHLIGHT_SCALE := 1.1

## 本 NPC 的配置数据（MapNPC 资源：id / display_name / texture / position / dialogue /
## destinations / teleport_label）。由 WorldMap 在 setup() 里注入；本文件只读不写。
## 类型是 Resource（不是节点），运行时改它会影响所有引用同一 .tres 的 NPC，务必小心。
var data: MapNPC

# ── 节点引用（% = unique_name_in_owner）──────────────────────────────────────
## NPC 立绘。有 texture 时用它；没有则隐藏并显示 Fallback 色块。
@onready var sprite: Sprite2D = %Sprite
## 占位色块（金色方块）。仅当 MapNPC.texture 为空时可见，用来"没美术也能跑"。
@onready var fallback: Polygon2D = %Fallback
## 头顶的名字标签，内容取 data.display_name。
@onready var name_label: Label = %NameLabel
## 头顶的"按 E 交谈"提示标签。默认隐藏，只有被高亮时显示（见 set_highlight）。
@onready var mark: Label = %Mark


## 用配置数据初始化本 NPC 的外观。
## 参数 p_data：该 NPC 的 MapNPC 资源（调用方保证非 null）。
## 返回值：无。
## 副作用：写 data、sprite.texture、fallback.visible、name_label.text，
##        并间接调用 set_highlight(false) —— 后者会 create_tween() 造一条缩放动画。
## 调用时机：必须在节点**已进树**之后调用（add_child 之后），否则 @onready 变量全是 null；
##   WorldMap._add_npc() 正是"先 add_child(npc)，再 npc.setup(data)"这个顺序。
## 注意：这里没做 data 为 null 的兜底，传 null 会在 data.texture 处直接报错。
func setup(p_data: MapNPC) -> void:
	data = p_data
	if data.texture != null:
		sprite.texture = data.texture
		fallback.visible = false
	else:
		fallback.visible = true
	name_label.text = data.display_name
	set_highlight(false)


## 切换"可交谈"高亮表现：显示/隐藏头顶提示 + 平滑放大/还原。
## 参数 value：true = 玩家在交互半径内（高亮）；false = 恢复常态。
## 返回值：无。
## 副作用：
##   · 改 mark.visible；
##   · create_tween() 新建一条 tween，0.1 秒内把 self.scale 补间到目标值。
## 为什么用 tween 而不是直接赋 scale：直接跳变太生硬；0.1 秒是"够快不拖沓"的折中。
## 坑：
##   · create_tween() 是"绑定在本节点上"的 tween，本节点被 queue_free 后会自动失效，
##     不需要手动 kill；
##   · 每次都新建 tween：短时间内连续调用（例如每帧）会让多条 tween 同时改 scale，
##     所以调用方必须做"只在状态变化时调用"的优化（WorldMap._update_nearest 已这么做）。
func set_highlight(value: bool) -> void:
	mark.visible = value
	var tween := create_tween()
	tween.tween_property(self, "scale", Vector2.ONE * (HIGHLIGHT_SCALE if value else 1.0), 0.1)
