## ═══════════════════════════════════════════════════════════════════════════
## UpgradePanel —— 每波打完弹出来的"四选一"升级面板
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   它是 Arena 的子节点（%UpgradePanel），平时隐藏。流程：
##     Spawner 波次计时结束 → Arena._on_spawner_on_wave_completed()
##       → clean_arena() → await 1.5 秒 → Arena.show_upgrades()
##       → 本文件 load_upgrade(spawner.wave_index) → show()
##     → 玩家点掉一张 UpgradeCard → 卡片 emit Global.on_upgrade_selected
##       → Arena._on_upgrade_selected() → upgrade_panel.hide() + shop_panel.load_shop() + show()
##   也就是说"升级面板 → 商店面板"的切换是**由 Arena 统一调度**的，本文件不知道后面还有商店。
##
## 数据流：
##   Global.UPGRADE_PROBABILITY_CONFIG（稀有度权重表）
##     + upgrade_list（@export，在 upgrade_panel.tscn 里挂的一批 ItemUpgrade 资源）
##     + 当前波数（决定哪些稀有度已"解锁"）
##     → Global.select_items_for_offer(pool, wave, config) 抽 4 个
##     → UPGRADE_CARD_SCENE.instantiate() 成 4 张 UpgradeCard 塞进 %ItemsContainer
##   本文件不写任何游戏状态；真正加属性的是 UpgradeCard → ItemUpgrade.apply_upgrade()。
##
## 场景里还有一块 StatsContainer（子场景），会每帧把玩家最新属性显示出来 ——
##   它是独立脚本，和本文件没有代码耦合。
##
## 坑：
##   · `for child in items_container.get_children(): child.queue_free()` 里的 queue_free 是
##     **延迟到帧末**才真正移除节点的，所以本次函数紧接着 add_child 的新卡片会和"待释放的旧卡片"
##     在同一个容器里共存到帧末 —— 容器会按两者一起排版，理论上可能看到一帧的错位。
##     要彻底避免就得先 remove_child(child) 再 queue_free()。现在的写法在动画/淡入遮罩下看不出来。
##   · 这些卡片是运行时 add_child 的，**owner 是 null**（不是本场景）；
##     所以卡片内部不能用 owner.queue_free() / get_node("../..") 之类的"场景内相对寻址"，
##     想释放自己只能直接 queue_free()（FloatingText 就是这么干的）。
##   · upgrade_list 里**不同**项必须 ≥ 4 个：select_items_for_offer() 是 while 到凑满 4 件为止，
##     池子太小时它会去重到抽不出新品而**死循环卡死游戏**（详见 global.gd 里的警告）。
##   · 本文件不调 show()/hide() —— 显隐由 Arena 决定，重复 show() 是幂等的。
extends Panel
class_name UpgradePanel

## 升级卡场景。用 **uid** 形式的 preload：uid 是 Godot 4 的资源唯一标识，
## 即使 .tscn 被移动/改名，只要 .uid 文件还在引用就不会断；反过来说，
## 删掉那个场景文件会在**脚本加载时**就报错（不是运行时才报）。
const UPGRADE_CARD_SCENE = preload("uid://mype27g20eg1")

## 升级候选池。在 upgrade_panel.tscn 里挂了 48 个 ItemUpgrade 资源（对应"伤害/生命/格挡/采集…"
## 各个档位）；必须是 Array[ItemUpgrade] 类型化数组，声明时没写 `= []` —— 类型化数组默认就是空数组。
## ⚠ 池子为空 / 不同项少于 4 时，load_upgrade 会让 select_items_for_offer 死循环。
@export var upgrade_list: Array[ItemUpgrade]

## 存放 4 张卡片的容器（unique_name_in_owner → 用 %ItemsContainer）。
## 它是一个 HBoxContainer（横向一排），会自己接管子卡的位置 —— 所以别去手改卡片的 position。
@onready var items_container: HBoxContainer = %ItemsContainer

## 重新抽取并铺好本波的 4 张升级卡（每次打开面板都会调一次）。
## 参数 current_wave：当前波数（Arena 传的是 spawner.wave_index）。
##   它只影响**稀有度权重**（哪些档已经解锁、概率多大），不影响数量 —— 数量固定 4 张。
## 返回值：无。
## 副作用：
##   · 先 queue_free() 掉容器里现有的所有子节点（上一波的卡；注意是"帧末才真的移除"）；
##   · 实例化 4 张 UpgradeCard 并 add_child 进 %ItemsContainer，然后逐个赋 item_data
##     （先 add_child 后赋值是必须的：卡片 setter 里要用 @onready 的 %Icon 等，没入树就是 null）；
##   · 会读取 Global.player.stats.luck（经由 calculate_tier_probability 里的幸运加成）
##     并在控制台 print 一行概率调试信息 —— 所以调用它之前 Global.player 必须已经存在；
##   · **不** show() 面板（显隐是 Arena 的事）。
## 节奏/顺序：Arena 是 `load_upgrade(); show()`，先备内容再显示，避免先显示空面板再填内容造成闪烁。
func load_upgrade(current_wave: int) -> void:
	# 清掉上一波的卡。注意 queue_free() 是**延迟到帧末**执行，本函数后面 add_child 的新卡
	# 会和这些"待释放"的旧卡在容器里共存到本帧结束（见文件头的坑）。
	# 编辑器里预置的 4 张 UpgradeCard 也走这条路径被清掉 —— 那些只是版式预览。
	for child in items_container.get_children():
		child.queue_free()
	
	# 概率配置表用 const 拿（不复制）：只读不改，所以直接引用没问题
	var config := Global.UPGRADE_PROBABILITY_CONFIG
	# 抽 4 个：返回值是**弱类型 Array**（不是 Array[ItemUpgrade]），所以下面循环必须自己标注
	# `random_upg: ItemUpgrade`，否则拿到的元素是 Variant。
	# 同时这个调用会读 Global.player.stats.luck 并 print 一行概率调试信息。
	var selected_upgrades := Global.select_items_for_offer(upgrade_list, current_wave, config)
	for random_upg: ItemUpgrade in selected_upgrades:
		var card_instance := UPGRADE_CARD_SCENE.instantiate() as UpgradeCard
		# 实例化并**先入树**：卡片脚本的 setter 里要用 %Icon 等 @onready 变量，
		# 只有进了场景树这些引用才有值。顺序颠倒会报 "null instance"。
		items_container.add_child(card_instance)
		# 入树之后再灌数据 —— 这是全套卡片类（UpgradeCard / ShopCard / ItemCard）的统一约定
		card_instance.item_data = random_upg
