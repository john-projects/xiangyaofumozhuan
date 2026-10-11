# ═══════════════════════════════════════════════════════════════════════════
# Arena —— 竞技场模式的中枢（"一波怪 → 结算 → 升级 → 商店 → 下一波"的循环）
# ═══════════════════════════════════════════════════════════════════════════
# 在系统里的位置：
#   本脚本是 scenes/arena/arena.tscn 的根脚本。整条链路是
#   TitleScreen(「经典模式」) → GameRoot.enter_arena() → _swap(arena, world_root)
#   → 本节点被挂到 main.tscn 的 WorldRoot(Node2D) 下。
#   竞技场是"自成一体的玩法"（自带选人 / 波次 / 商店），和世界地图 + 回合制战斗那条线并行。
#   注意：竞技场**没有** MapData / GameRoot 的直接引用（除了 _swap 时被 add_child），
#   它只通过 Global 的全局信号与各系统解耦。
#
# 场景构成（详见 arena.tscn）：
#   Arena(Node2D, 本脚本)          中枢；同时是下面这些节点的父节点
#   ├─ BlackBG / GrassBG          背景两层贴图（本文件不碰）
#   ├─ Camera2D                   挂 camera_2d.gd，每帧硬跟随 Global.player
#   ├─ Spawner(Node2D)            波次调度器（见 spawner.gd），本文件用 $Spawner 取
#   │   └─ SpawnTimer / WaveTimer
#   └─ GameUI(CanvasLayer)        UI：CoinsBag / 波次文字 / UpgradePanel / ShopPanel / SelectionPanel
#   MusicPlayer(AudioStreamPlayer, autoplay)  BGM（本文件不碰）
#
# 职责（也就是本文件里的五个部分）：
#   1. 订阅 Global 的全局信号 —— **本节点是全项目唯一订阅者**：
#        on_create_block_text / on_create_damage_text / on_create_heal_text → 弹飘字
#        on_upgrade_selected → 升级选完 → 切到商店面板
#        on_enemy_died      → 敌人死了 → 掉金币
#      如果换了场景（例如回主菜单）这些连接会随本节点一起销毁；但若在别的场景也订阅，
#      就会"一次事件被处理两次"，所以注意别在多处重复 connect。
#   2. 每帧刷新顶部两个标签（波数 / 剩余秒数），从 spawner 取文本
#   3. 波次流转：波次结束 → 清场 → 等 1.5 秒 → 升级面板 → 商店 → 下一波
#   4. 提供两个全场公用的工厂函数：create_floating_text() / spawn_coins()
#   5. 开局：选人完成 → 造出玩家、发初始武器、开第一波
#
# 数据流（谁改 Global）：
#   · Global.player         写：_on_selection_panel_on_selection_completed() 里
#                              Global.get_selected_player() 内部赋值（本文件只调它）
#   · Global.game_paused    写：_on_selection_panel_on_selection_completed() 末尾置 false、
#                              start_new_wave() 置 false；置 true 的是 Spawner 的波次超时
#   · Global.coins          写：Coins.add_coins()（金币节点自己加），本文件不直接加
#   · Global.equipped_weapons 写：本文件开局把初始武器 append 进去
#
# 坑（本文件有几处顺序/时序上的讲究，改之前务必看）：
#   · 飘字节点挂在 **get_tree().root** 下，不在 Arena 下 —— 所以 Arena 被清掉时飘字不会被连带清；
#     反过来说，飘字必须在 add_child 之后再设 global_position（见 create_floating_text 注释）。
#   · _on_enemy_died() 里掉金币用的是 **call_deferred**：敌人死亡信号是在物理回调里发出的，
#     那个时刻不允许直接 add_child/改碰撞状态，必须推迟到帧末空闲时执行。
#   · _on_spawner_on_wave_completed() 里那个 await 1.5 秒：等待期间玩家仍可操作、
#     视觉上还在收金币，所以 await 之后要再 clean_arena() 收尾一次。
#   · start_new_wave() 里是先 `spawner.wave_index += 1` 再 `start_wave()`。
#   · 本文件**不连** GameUI 里的 SelectionPanel / ShopPanel 的信号：它们在 arena.tscn 里
#     被编辑器直接连到了本脚本的 _on_selection_panel_on_selection_completed /
#     _on_shop_panel_on_shop_next_wave（这也是 Arena 能收到开局与下一波事件的原因）。
extends Node2D
class_name Arena

# ───────────────────────────────────────────────────────────────────────────
#  ── 视觉：飘字颜色（在 arena.tscn 里已经填好，改动等于改 UI 表现，不影响任何数值）──
# ───────────────────────────────────────────────────────────────────────────
## 普通伤害数字的颜色。场景里的取值是接近白色 (0.98, 0.98, 0.994)——干净、最不抢眼。
@export var normal_color: Color
## 被格挡时的飘字颜色（纯表现，不代表任何减伤）。场景里是粉红 (1, 0.28, 0.45)，
## 注意"格挡"这条路径传的文本是固定的 "Blocked!"，不显示数字。
@export var blocked_color: Color
## 暴击伤害数字的颜色。场景里是暖橙 (0.996, 0.78, 0.38)，比普通伤害醒目，
## 用来让玩家一眼区分"这一下暴击了"。判定来源是 HitboxComponent.critical。
@export var critical_color: Color
## 回血飘字（"+ N"）的颜色。场景里是青绿 (0, 0.627, 0.482)——和伤害色系完全区分开。
@export var hp_color: Color

# ── 节点引用（% = unique_name_in_owner；$ = 普通相对路径）──────────────────────
## 顶部"Wave N"标签。Arena._process 每帧覆盖它的 text。
@onready var wave_index_label: Label = %WaveIndexLabel
## "Wave N"下面那行剩余秒数标签，同样每帧覆盖。
@onready var wave_time_label: Label = %WaveTimeLabel
## 右上角的钱包（HBoxContainer）。本文件只读它的 global_position / size 来当"金币吸收点"。
@onready var coins_bag: CoinsBag = %CoinsBag

## 波次调度器。用 $ 而不是 %：arena.tscn 里的 Spawner 没有标 unique_name_in_owner。
## 它是本文件最重要的协作者：波数推进、刷怪、波次结束信号都由它管。
@onready var spawner: Spawner = $Spawner
## 升级面板（三/四选一的卡牌面板）。默认隐藏，波次结束时由 show_upgrades() 弹出。
@onready var upgrade_panel: UpgradePanel = %UpgradePanel
## 商店面板。升级选完后由 _on_upgrade_selected() 弹出；它的「下一波」按钮直接连到
## 本文件的 _on_shop_panel_on_shop_next_wave()（连接是在 arena.tscn 里预置的）。
@onready var shop_panel: ShopPanel = %ShopPanel

# ───────────────────────────────────────────────────────────────────────────
#  ── 运行时状态 ──
# ───────────────────────────────────────────────────────────────────────────
## 场上未被拾取的金币节点列表。谁往里加：spawn_coins()（敌人死亡时）。
## 谁清它：clean_arena()（波次结算时把它们的目标设成钱包中心，然后 clear）。
## ⚠ 这里保存的是**节点引用**，金币可能已经被 Coins.add_coins() 里 queue_free() 掉了，
##   所以遍历时必须 is_instance_valid() 判断（clean_arena 里就是这么做的）。
var gold_list: Array[Coins]


# Called when the node enters the scene tree for the first time.
## 生命周期：进树时执行一次，把全局信号接到本节点。
## 参数：无。返回值：无。
## 副作用：建立 5 条 Global 信号连接（见文件头"职责 1"）。
## 重点说明（为什么必须由 Arena 来订阅）：
##   Unit / Enemy / Player 这些单位只负责 `emit`，完全不知道谁在听；
##   是 Arena 订阅后把"事件"翻译成画面（飘字、金币）。好处是战斗逻辑与 UI 表现互不引用，
##   在没有 Arena 的场景里 emit 也完全安全（没人听就什么也不发生）。
##   ⚠ 代价是：**全项目只能有一个 Arena 在同时订阅**，否则一次伤害会弹出两套飘字。
## 注意：本函数没有调 super._ready() —— 它是 Node2D 的直接子类，没有父脚本要照顾；
##   若以后给 Arena 加了中间基类，则必须显式调用 super._ready()，否则基类初始化会被吃掉。
func _ready() -> void:
	Global.on_create_block_text.connect(_on_create_block_text)
	Global.on_create_damage_text.connect(_on_create_damage_text)
	Global.on_create_heal_text.connect(_on_create_heal_text)
	Global.on_upgrade_selected.connect(_on_upgrade_selected)
	Global.on_enemy_died.connect(_on_enemy_died)

# Called every frame. 'delta' is the elapsed time since the previous frame.
## 每帧刷新顶部两个 HUD 标签。
## 参数 delta：帧间隔秒数（本函数用不到，只是 _process 的固定签名）。
## 返回值：无。
## 副作用：改 wave_index_label.text / wave_time_label.text。
## 为什么"每帧取一次文本"而不做成信号：波数和倒计时本来就是连续变化的量，
##   每帧拉取比"每帧 emit 一次信号"更省事，也不会漏帧。
## 为什么 game_paused 时要提前 return：暂停期间 spawner 的计时器虽然还在跑，
##   但画面应该冻住 —— 这样"选完升级弹商店"的那段时间里倒计时数字不会继续跳。
func _process(delta: float) -> void:
	if Global.game_paused:
		return
	wave_index_label.text = spawner.get_wave_text()
	wave_time_label.text = spawner.get_wave_timer_text()

## 在单位头顶随机偏一点的位置弹一个飘字节点（本文件最重要的工具函数，三处调用）。
## 参数 unit：飘字要跟着谁 —— 只用它的 global_position，不建立父子关系（**不**跟随移动）。
## 返回值：新建的 FloatingText 节点（调用方接着调它的 setup(text, color)）。
## 副作用：实例化一个飘字节点并 add_child 到 get_tree().root（**注意：不是 Arena 下**）。
##
## 三个实现细节，都有原因：
##   · 挂在 get_tree().root（Window）而不是 Arena 下 —— 这样弹字不会被 Arena 的子节点
##     层级/裁剪影响，也不会在"清场"时被连带处理；代价是它在本场景销毁后仍会在 root 上活到
##     自己播完（FloatingText 自己负责销毁）；
##   · 先 add_child 再设 global_position —— 节点进树之前 global_position 是按"还没有父节点"
##     算出来的，进树后会被父节点变换重新套算；所以顺序反了位置就会偏（root 是单位变换，
##     但仍应遵守"进树后再定位"这个惯例）；
##   · 位置用 Vector2.RIGHT.rotated(rad) * 35 —— 把单位向量旋转一个随机角度再乘 35 像素，
##     等价于"在以单位为中心、半径 35 的圆上随机取一点"。注意 random_pos 变量名有点误导：
##     它其实是**弧度**（randf_range(0, TAU) 是 0~2π），不是像素位置。
func create_floating_text(unit: Node2D) -> FloatingText:
	var instance := Global.FLOATING_TEXT_SCENE.instantiate() as FloatingText
	get_tree().root.add_child(instance)
	var random_pos = randf_range(0, TAU) * 35
	var spawn_pos = unit.global_position + Vector2.RIGHT.rotated(random_pos)
	instance.global_position = spawn_pos
	return instance

## 波次结束时弹出升级面板（让玩家从几张卡里选一张强化）。
## 参数：无。返回值：无。
## 副作用：调 upgrade_panel.load_upgrade(波数)（内部会按波数算稀有度概率并铺卡）
##        然后 upgrade_panel.show()。
## 传的是 spawner.wave_index（当前波）—— 概率表里"第几波开始出稀有"就是拿它比较的。
func show_upgrades() -> void:
	upgrade_panel.load_upgrade(spawner.wave_index)
	upgrade_panel.show()

## 开始新的一波（由商店面板的「下一波」按钮触发）。
## 参数：无。返回值：无。
## 副作用（顺序有意义）：
##   1. Global.game_paused = false —— 先解除冻结，玩家在下一次 _process 就能动；
##   2. Global.player.update_player_new_wave() —— 玩家也吃"每波成长"（回血/加血上限等），
##      ⚠ 这里**没有判空**：如果 player 已失效会直接报错，前提是场上确实有玩家；
##   3. spawner.wave_index += 1 —— 推进波数（所以 UI 上显示的是新波数）；
##   4. spawner.start_wave() —— 找配置、起时长计时器、起刷怪计时器，开始刷怪。
## 注意顺序：先 += 1 再 start_wave() —— 若写反，start_wave() 会按**旧**波数找配置，
##   导致每一波都用上一波的配置（刷怪节奏与时长整体错位一波）。
func start_new_wave() -> void:
	Global.game_paused = false
	Global.player.update_player_new_wave()
	spawner.wave_index += 1
	spawner.start_wave()

## 清场结算：把场上遗留的金币全部吸向钱包，并清掉剩余敌人。
## 参数：无。返回值：无。
## 副作用：
##   · 对 gold_list 里每个仍有效的金币调 set_collection_target(钱包中心的世界坐标)，
##     随后金币的 _process 会把它们飞向钱包（见 coins.gd）；
##   · gold_list.clear()（⚠ 只是清空列表，金币节点还活着，会自己飞到钱包后 queue_free）；
##   · spawner.clear_enemies()（逐个播死亡动画后销毁）。
## 为什么目标是"钱包中心"：coins_bag 是 CanvasLayer 上的 UI 控件，它的 global_position
##   属于 UI 坐标系，所以取 global_position + size / 2.0 得到控件中心，交给 Coins 那边
##   用 canvas_transform 反算成世界坐标（这是既有的两段式坐标约定，别只改一头）。
## 调用时机：波次一开始结束就调一次（把战场腾空，让玩家看清升级面板），
##   升级面板弹出后再调一次（收掉这 1.5 秒里刚飞完/刚掉出来的金币）。
func clean_arena() -> void:
	if gold_list.size() > 0:
		var target_center_pos := coins_bag.global_position + coins_bag.size / 2.0
		for gold in gold_list:
			if is_instance_valid(gold):
				var gold_item := gold as Coins
				gold_item.set_collection_target(target_center_pos)
	gold_list.clear()
	spawner.clear_enemies()

## 在敌人尸体位置掉一枚金币（敌人死亡时由 _on_enemy_died 延迟调用）。
## 参数 enemy：刚死掉的敌人节点 —— 这里要读它的 global_position 和 stats.gold_drop。
## 返回值：无。
## 副作用：实例化 Global.COINS_SCENE、登记进 gold_list、设 global_position、add_child 到本节点。
##
## 细节：
##   · 掉落位置 = 敌人位置 + 半径 35 的圆上随机一点（和飘字同一个套路，避免叠在正中央）；
##   · 先 append 进 gold_list 再 add_child —— 顺序无所谓，但列表是 clean_arena() 的唯一依据，
##     一定要登记，否则这枚金币永远不会被"吸向钱包"；
##   · global_position 在 add_child **之前**设置：Arena 自身是单位变换（位置 0、无缩放旋转），
##     所以先设后设结果一样；若以后给 Arena 加位移，这里要改成局部坐标。
## 注意：本函数**不**判 is_instance_valid(enemy)，因为调用链是"敌人刚死 → deferred 调用"，
##   到执行时敌人可能已经 queue_free（destroy_enemy 的动画还没播完时它仍在树上，
##   所以这里读它的 global_position 一般是安全的）。
func spawn_coins(enemy: Enemy) -> void:
	var random_angle := randf_range(0, TAU)
	var offset := Vector2.RIGHT.rotated(random_angle) * 35
	var spawn_pos := enemy.global_position + offset
	
	var gold_instance := Global.COINS_SCENE.instantiate() as Coins
	gold_list.append(gold_instance)
	
	gold_instance.global_position = spawn_pos
	gold_instance.value = enemy.stats.gold_drop
	add_child(gold_instance)
	

# ══════════════════════════════════════════════════════════════════════════
#  Global 信号回调（飘字 / 面板流转 / 掉金币）
# ══════════════════════════════════════════════════════════════════════════

## 格挡成功 → 在该单位头顶弹一个固定的 "Blocked!" 飘字。
## 参数 unit：格挡发生的单位（Unit 里 emit 时传的 self）。
## 返回值：无。副作用：新建一个飘字节点并 setup 文案与颜色。
## 说明：文本是写死的（不显示具体数值），所以格挡表现是"定性"的 —— 玩家只知道挡住了。
func _on_create_block_text(unit: Node2D) -> void:
	var text := create_floating_text(unit)
	text.setup("Blocked!", blocked_color)
	
## 受到伤害 → 弹伤害数字飘字。
## 参数 unit：被打的单位；hitbox：造成这次伤害的判定盒 —— **它身上带着数据**：
##   damage（伤害数值）和 critical（是否暴击）。这是"事件带参数"设计的典型用法：
##   单位侧不用关心颜色，颜色由表现层（本文件）按 critical 决定。
## 返回值：无。副作用：新建飘字节点并 setup(str(damage), 暴击?橙:白)。
## 注意这里用 var color 而没标类型：两个分支都是 Color，推断出来就是 Color（原有写法，保持不动）。
func _on_create_damage_text(unit: Node2D, hitbox: HitboxComponent) -> void:
	var text := create_floating_text(unit)
	var color = critical_color if hitbox.critical else normal_color
	text.setup(str(hitbox.damage), color)
	
## 回血 → 弹 "+ N" 飘字。
## 参数 unit：被治疗的单位；heal：治疗量（**float**，所以可能显示 "3.5"）。
## 返回值：无。副作用：新建飘字节点并 setup("+ %s", 绿色)。
## 发出这个信号的来源（见代码引用）：玩家 hp_regen 的定时器、以及武器的吸血结算。
func _on_create_heal_text(unit: Node2D, heal: float) -> void:
	var text := create_floating_text(unit)
	text.setup("+ %s" % heal, hp_color)

## 玩家选完一张升级卡 → 关升级面板，接着弹商店面板。
## 参数：无（信号本身不带参数）。
## 返回值：无。
## 副作用：upgrade_panel.hide()、shop_panel.load_shop(spawner.wave_index)、shop_panel.show()。
## 为什么传 wave_index：商店的稀有度概率也按波数走（见 Global.SHOP_PROBABILITY_CONFIG）；
##   此刻 wave_index 仍是"刚打完的那一波"，所以升级和商店看到的是同一个波数（一致）。
func _on_upgrade_selected() -> void:
	upgrade_panel.hide()
	shop_panel.load_shop(spawner.wave_index)
	shop_panel.show()

## 一波结束（Spawner 的 on_wave_completed，场景里预连到本函数）。
## 参数：无。返回值：无（内含 await，是协程）。
## 副作用：
##   · 若玩家已失效直接 return；
##   · clean_arena() 第一次：立刻把场上金币吸向钱包、清掉残留敌人；
##   · await 1.5 秒（create_timer，**用的是 SceneTree 计时器**，所以即使
##     Global.game_paused = true 也照样走 —— game_paused 只冻游戏逻辑，不影响 Timer/tween）；
##   · show_upgrades()：弹升级面板；
##   · clean_arena() 第二次：把刚才那 1.5 秒里飞完的金币收干净。
## 为什么要两次 clean_arena：第一次是为了"腾空战场"，第二次是为了处理
##   "结算瞬间刚掉出来、还没飞走的金币"（金币飞行需要时间，一次清不干净）。
## 为什么第一行要 if not Global.player: return：玩家可能已经死亡/被清掉，
##   继续走会弹出一个没有玩家可强化的升级面板 —— 直接不处理更安全。
func _on_spawner_on_wave_completed() -> void:
	if not Global.player:
		return
	clean_arena()
	await get_tree().create_timer(1.5).timeout
	show_upgrades()
	clean_arena()

## 商店面板的「下一波」按钮回调（信号在 arena.tscn 里预连到本函数）。
## 参数：无。返回值：无。
## 副作用：关掉商店面板，然后 start_new_wave()（解除暂停、玩家成长、波数 +1、开刷）。
## 注意此处不直接改 wave_index —— 推进波数的唯一入口是 start_new_wave()，别在别处也加。
func _on_shop_panel_on_shop_next_wave() -> void:
	shop_panel.hide()
	start_new_wave()

## 敌人死亡（Global.on_enemy_died）→ 掉金币。
## 参数 enemy：刚死掉的敌人。
## 返回值：无。
## 副作用：print 一行调试信息（刻意保留）；把 spawn_coins 排到 **帧末空闲** 执行。
## 为什么必须 call_deferred：
##   这个信号是在**物理回调**（HealthComponent 的 died → Enemy 转发）里发出的，
##   物理回调期间不允许增删节点/改碰撞状态（Godot 会报 "Can't change this state while
##   flushing queries"）。call_deferred 把它推迟到本帧空闲时执行，从而安全地 add_child 金币。
## 注意 print 的是 enemy.stats.name（显示名），不是节点名 —— 调平衡时方便按名字核对掉落。
func _on_enemy_died(enemy: Enemy) -> void:
	print("die: ", enemy.stats.name)
	spawn_coins.call_deferred(enemy)


## 选人完成（SelectionPanel 的 on_selection_completed，场景里预连到本函数）—— 整个竞技场的开局。
## 参数：无（选人结果放在 Global.main_player_selected / main_weapon_selected）。
## 返回值：无。
## 副作用（开局全套，顺序重要）：
##   1. Global.get_selected_player() —— 按选中的名字实例化玩家节点，并把 Global.player 指向它
##      （该函数**不会**把节点加进场景树，add_child 由本函数负责）；
##   2. add_child(player) —— 玩家进树（进树后它的 _ready 才会跑，才能安全访问 @onready 子节点）；
##   3. player.add_weapon(初始武器) —— 给玩家挂上武器节点；
##   4. shop_panel.create_item_weapon(...) —— 让商店面板也认识这把武器（卖/合成都基于这份数据）；
##   5. Global.equipped_weapons.append(...) —— 记进全局已装备列表（上限 6 由商店那边检查）；
##   6. spawner.start_wave() —— 开第一波（此刻 wave_index 还是初值 1）；
##   7. Global.game_paused = false —— 最后解除冻结。
## 顺序上的两个讲究：
##   · 必须 add_child 之后再 add_weapon：武器的 _ready/@onready 依赖玩家已在树里；
##   · game_paused 放到最后解除：前 5 步都在"冻结"状态下完成，避免刚进树的玩家
##     在被摆好位置/武器之前就先动一帧。
## 注意这里没有把 player 存成成员变量 —— 全场都通过 Global.player 访问（这也是
##   camera_2d.gd 每帧读 Global.player 的原因）。
## 若 main_player_selected 为 null（玩家没选人就点了完成），Global.get_selected_player()
##   会在内部直接报错 —— 界面流程上不会走到这一步，本函数不做额外兜底。
func _on_selection_panel_on_selection_completed() -> void:
	var player := Global.get_selected_player()
	add_child(player)
	player.add_weapon(Global.main_weapon_selected)
	shop_panel.create_item_weapon(Global.main_weapon_selected)
	Global.equipped_weapons.append(Global.main_weapon_selected)
	
	spawner.start_wave()
	Global.game_paused = false
