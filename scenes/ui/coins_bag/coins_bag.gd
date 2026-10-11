## ═══════════════════════════════════════════════════════════════════════════
## CoinsBag —— 金币显示条（HUD 小控件：一个钱袋图标 + 一串数字）
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   纯展示型 UI，不参与任何数值计算，也不改变任何状态。
##   它被挂在两处：Arena 的 HUD（scenes/arena/arena.tscn 的 %CoinsBag，
##   arena.gd 里用 @onready var coins_bag: CoinsBag 持有）和商店面板
##   （shop_panel.tscn 里的 CoinsBag 实例，让玩家边买边看余额）。
##
## 数据流（单向，只读）：
##   Global.coins（int，全局跨场景状态，默认 500）
##     → _process() 每帧读一次 → str() → $Coins(Label).text
##   谁在**写** Global.coins（本文件一行都不写）：
##     · Coins 金币拾取物（被玩家吃到时 +value）
##     · ShopCard._on_buy_button_pressed()（买道具时扣 item_cost）
##     · ShopPanel._on_sell_button_pressed()（卖出返还 75%）
##     · Main.start_new_game()（开新档重置回 500）
##   因为 Global.coins 是**裸变量、没有 changed 信号**，所以这里只能每帧轮询，
##   没法做成"事件驱动"。这是当前结构下最省事也最不会漏刷新的做法。
##
## 与 Arena.clean_arena() 的隐含耦合（容易被忽略）：
##   Arena 里 gold_list 存着场上散落的金币节点，clean_arena() 会让它们飞向
##   `coins_bag.global_position + coins_bag.size / 2.0` —— 也就是说本节点的
##   **位置和尺寸**被 Arena 当成"金币吸附动画的目标点"用。改本场景的锚点或大小，
##   会连带改变那段金币飞入动画的落点（居中偏移刚好抵消，所以现在看着是准的）。
##
## 坑：
##   · 根节点是 HBoxContainer（容器）。容器会接管子节点的 position/size，
##     想调布局请改容器的 separation / alignment，别去手改 $Coins 的 offset。
##   · _process 里每帧无条件赋值，即使本控件 visible = false（例如商店关着）也照写。
##     这点开销可以忽略，但别在这里加更重的东西。
extends HBoxContainer
class_name CoinsBag

## $Coins 用的是**普通子节点路径**，不是 unique_name_in_owner 的 %Coins ——
## coins_bag.tscn 里 Coins 只是 HBoxContainer 下的一个子 Label，没勾"访问为唯一名称"，
## 所以这里必须写 $Coins；一旦改名或把它挪进别的容器，这行会直接报错。
## 类型标注成 Label 只是为了拿自动补全与静态检查。
## 另外：@onready 变量在 _ready() 之前（也就是 _init / 构造阶段）还是 null，
## 任何早于 _ready() 的访问都会崩。
@onready var coins: Label = $Coins


## 每帧把全局金币数同步到 Label 上。
## 参数 delta：引擎传入的帧间隔（秒）。这里**用不到**，因为只是读一个值、不按时间累积，
##   所以参数没有被引用（GDScript 会为此给一条 UNUSED_PARAMETER 警告，属正常现象）。
## 返回值：无。
## 副作用：
##   · 写 $Coins.text（每帧都写；字符串没变时 Godot 内部会跳过重绘，不用担心闪烁）；
##   · **只读** Global.coins，绝不修改 —— 金币的增减全在 Coins / ShopCard / ShopPanel / Main 里。
## 为什么不做成信号驱动：Global.coins 是裸 int 变量，没有对应的 changed 信号，
##   所以"每帧轮询"是当前结构下最不容易出错的做法。
## Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	coins.text = str(Global.coins)
