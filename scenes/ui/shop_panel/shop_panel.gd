## ═══════════════════════════════════════════════════════════════════════════
## ShopPanel —— 商店面板（每波之间的买卖 / 合成 / 卖出界面）
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   它是 Arena 的子节点（%ShopPanel），平时隐藏。触发链：
##     UpgradePanel 里玩家选完升级卡 → 卡片 emit Global.on_upgrade_selected
##       → Arena._on_upgrade_selected() → 收起升级面板、本面板 load_shop() + show()
##     → 玩家买卖完点 NextWaveButton → 本面板 emit on_shop_next_wave
##       → （arena.tscn 里连好的）Arena._on_shop_panel_on_shop_next_wave()
##       → 收起本面板、start_new_wave()（解冻 game_paused、发下一波）
##
## 界面分区与对应容器（都是 unique_name_in_owner）：
##   %ItemsContainer   —— 上排 4 张 ShopCard（本波在卖的候选，会随购买消失）
##   %WeaponsContainer —— 右侧网格：已买的武器（ItemCard，上限 6）
##   %PassivesContainer—— 左侧网格：已买的被动道具（ItemCard，无上限，按 3 列排）
##   %CombineButton    —— "合成"：两张同名武器 → 下一档
##   %SellButton / %NextWaveButton —— 卖出 / 下一波（.tscn 里各自连了本脚本的回调）
##   面板上还内嵌了一个 StatsContainer 子场景（每帧显示玩家属性），与本文件无代码耦合。
##
## 数据流（谁在改什么）：
##   Global.SHOP_PROBABILITY_CONFIG（稀有度权重，比升级池慷慨）+ shop_items（@export 候选池）
##     + 当前波数 → load_shop() 用 Global.select_items_for_offer() 抽 4 件 → 4 张 ShopCard
##   购买：ShopCard 扣 Global.coins 并 emit on_item_purchased(item) → 本文件 _on_item_purchased()
##     · WEAPON → Global.player.add_weapon(weapon)（**造出 Weapon 节点**挂到玩家身上）
##                + Global.equipped_weapons.append(weapon)（**只存数据**）
##     · PASSIVE→ ItemPassive.apply_passive()（就地改 Global.player.stats，永久）
##   合成：两张同名武器 → 移除两把、load(upgrade_to.resource_path) 取下一档 → 再走上面的"购买后"逻辑
##   卖出：移除一把 → 返还 int(item_cost * 0.75) 金币 → 销毁那张 ItemCard
##   注意两套"武器记录"必须同步：current_weapons 是**场上节点**列表（Player 上的），
##   equipped_weapons 是**数据**列表（Global 上的，用来判"上限 6"和"同名两把可合成"）。
##
## 悬停提示：统一交给 TooltipManager（autoload）。卡片在**创建时**就把 mouse_entered /
##   mouse_exited 接好了，所以不需要事后遍历容器补信号。
##
## 坑（都是这份代码里真实存在的脆弱点）：
##   · _on_item_purchased() 只处理 WEAPON / PASSIVE 两种类型，**没有 else 分支**：
##     如果 shop_items 里混进了 UPGRADE 类型的资源，那张 ItemCard 既不会被 add_child，
##     又会执行 `item_card.item = item` —— 节点不在树里 → 它 setter 里的 %ItemIcon 还是 null → 报错，
##     而且这个游离节点不会被释放（内存泄漏）。往候选池里加道具时请只用武器/被动。
##   · 合成 / 卖出都依赖 `context_card`（最近一次点选的武器 ItemCard）。
##     它在 _on_item_card_selected 里被赋值、在合成与卖出之后都会被清成 null；
##     但**卖出之后不会重算 combine_button.disabled** —— 卖掉一把后按钮可能还亮着，
##     再点一次合成会因为没有第二把同名武器而静默失败（不会崩，只是没反应）。
##   · load(upgrade_to.resource_path) 要求下一档真的是磁盘上的 .tres；
##     运行时 new 出来的 ItemWeapon 没有 resource_path，load("") 会失败。
##   · 运行时 add_child 进来的卡片 **owner 是 null**（不属于本场景文件），
##     不能用 owner.queue_free() 之类相对寻址；释放它们只能直接 queue_free()。
extends Panel
class_name ShopPanel

## 玩家点了"下一波"。**无参数** —— 具体做什么由订阅者决定（Arena 收到后关面板 + 开新波）。
## 连线写在 arena.tscn 里（[connection ... from="GameUI/ShopPanel" to="."]），
## 所以在编辑器里"断开连接"或在代码里改名都会静默失效。
signal on_shop_next_wave

## 在售候选卡（ShopCard）的场景。用 uid 形式 preload：文件被挪动也不易断，删掉则脚本加载时就报错。
## 注意它**不放在 Global 里**（对比 ITEM_CARD_SCENE / SELECTION_CARD_SCENE）——
## 因为只有本商店用得到它，没必要占全局常量表。
const SHOP_CARD_SCENE = preload("uid://ba8e7xllxa8c2")
# 旧方案（本地 hover card）已弃用，改用 TooltipManager；保留备查
# const HOVER_ITEM_CARD_SCENE = preload("uid://sojan35we4eq")

## 商店候选池（.tres 资源数组，在 shop_panel.tscn 里挂了 48 项：武器 + 被动）。
## ⚠ 里面**不同**项必须 ≥ 4 个：Global.select_items_for_offer() 是 while 到凑满 4 件为止，
##   池子太小会一直抽到重复而被去重掉 → **死循环卡死游戏**（详见 global.gd 的注释）。
## ⚠ 也请只放 item_type 为 WEAPON / PASSIVE 的道具：UPGRADE 类型会走 _on_item_purchased() 的
##   空档分支而报错（见文件头）。
@export var shop_items: Array[ItemBase]

## ── 三个容器 + 一个按钮（全部 unique_name_in_owner）────────────────────────
## items_container：HBoxContainer，放本波的 4 张 ShopCard；
## passives_container / weapons_container：GridContainer，放**已买到手**的 ItemCard 网格；
## combine_button：合成按钮，禁用与否由 _on_item_card_selected() 决定（**卖出按钮从来不置灰**）。
@onready var items_container: HBoxContainer = %ItemsContainer
@onready var passives_container: GridContainer = %PassivesContainer
@onready var weapons_container: GridContainer = %WeaponsContainer
@onready var combine_button: Button = %CombineButton

## 当前被点选的卡（%WeaponsContainer 里的那张 ItemCard）。合成 / 卖出都以它为操作对象。
## 写：_on_item_card_selected()（点选时赋值）、_on_combine_button_pressed() 与
##     _on_sell_button_pressed()（两个操作完成后都置 null，防止后续误操作指向已释放的卡）。
## 只写不读的地方：本文件没有别的逻辑读它；组合/卖出前都会 `if not context_card: return` 兜底。
var context_card: ItemCard
# 旧方案
# var hover_item_card: HoverItemCard

## 初始化：清掉两个"已拥有"网格里编辑期摆的占位卡片。
## 参数：无。返回值：无。
## 副作用：对 %PassivesContainer / %WeaponsContainer 的现有子节点逐个 queue_free()。
##   这些子节点是**编辑期预览用**的占位节点（.tscn 里摆了 15 个被动格 + 6 个武器格；
##   被动网格的第一个是真 ItemCard 场景实例，其余包括武器网格那 6 个都只是裸 Button），
##   运行时不删掉它们就会和真卡片挤在一起。
## 为什么 items_container 不在 _ready() 里清：那排 ShopCard 由 load_shop() 开头负责清，
##   而 _ready() 时商店还没开过 —— 提前清也行，只是没必要（面板此刻还是隐藏的）。
## ⚠ queue_free() 是**帧末**才真正移除：本帧内这些待删节点仍存在于容器中（参与排版）。
## 旧方案（本地 hover 提示卡）在这里实例化的代码已注释保留，不再生效。
func _ready() -> void:
	# 清空"被动 / 武器"两个网格里的占位节点（queue_free 延迟到帧末，见上面的说明）
	for child in passives_container.get_children(): child.queue_free()
	for child in weapons_container.get_children(): child.queue_free()

	# 旧方案：本地创建一张提示卡，自己跟随鼠标
	# hover_item_card = HOVER_ITEM_CARD_SCENE.instantiate()
	# add_child(hover_item_card)
	# hover_item_card.hide()


# ──────────────────────────────────────────────────────────────
#  新方案：悬停提示统一交给 TooltipManager（autoload，独立 CanvasLayer）
#  卡片在"创建时"各自接好信号，所以不需要事后遍历容器
# ──────────────────────────────────────────────────────────────

## 鼠标进入一张**在售**卡（ShopCard）→ 弹提示卡。
## 参数 card：触发悬停的卡片（由 load_shop() 里 .bind(card_instance) 带进来）。
## 返回值：无。
## 副作用：若卡片已绑定数据，转调 TooltipManager.show_for_control(card, card.shop_item)
##   —— 由那个 autoload 负责延迟 / 淡入 / 定位 / 防抖；数据为空则**什么都不做**
##   （注意不是 hide：这里不主动收起，收起由 mouse_exited → _on_card_hover_ended 负责）。
## 为什么从 card 身上取数据而不是单独传参：卡片已经是数据的持有者，少一层参数传递，
##   也避免了"信号已经发出但卡片被 queue_free"时的悬空引用问题（本函数只在卡片活着时被调）。
func _on_shop_card_hover_started(card: ShopCard) -> void:
	if card.shop_item == null:
		return
	TooltipManager.show_for_control(card, card.shop_item)


## 鼠标进入一张**已拥有**卡（ItemCard）→ 弹提示卡。与 _on_shop_card_hover_started 对称，
## 只是数据字段名是 card.item 而不是 card.shop_item。
## 参数 card：触发悬停的 ItemCard（create_item_card() 里 .bind(item_card) 带进来的）。
## 返回值：无。副作用：转调 TooltipManager.show_for_control；card.item 为空时直接返回。
## 注意：ItemCard 自己还 emit on_item_card_hover 信号（供旧方案用），本条路径不依赖它。
func _on_item_card_hover_started(card: ItemCard) -> void:
	if card.item == null:
		return
	TooltipManager.show_for_control(card, card.item)


## 鼠标离开任意卡片（在售的 ShopCard 或已拥有的 ItemCard）→ 收起提示卡。
## 参数：无（mouse_exited 无参，所以直接把本方法连上去即可）。返回值：无。
## 副作用：TooltipManager.hide_tip() —— 那个 autoload 会递增内部 token 让等待中的延迟显示作废、
##   启动 0.06 秒淡出，并在淡出结束的回调里才 card.hide() + emit tooltip_closed。
## 注意与"新提示打断旧提示"的区别：被新提示直接顶掉时旧卡片**不会**补发 tooltip_closed
##   （TooltipManager 内部 kill 掉了旧 tween），所以别把 tooltip_closed 当成"每次必到"的通知。
func _on_card_hover_ended() -> void:
	TooltipManager.hide_tip()


# ──────────────────────────────────────────────────────────────
#  旧方案（本地 hover card，已弃用）——保留备查，不再生效
# ──────────────────────────────────────────────────────────────
# func _process(delta: float) -> void:
# 	if hover_item_card.visible:
# 			_follow_mouse()
#
# func _follow_mouse() -> void:
# 	var vp := get_viewport().get_visible_rect().size
# 	var pos := get_local_mouse_position() + Vector2(16, 16)      # 相对 ShopPanel 的局部坐标
# 	pos.x = min(pos.x, vp.x - hover_item_card.size.x - 8)              # 别跑出屏幕
# 	pos.y = min(pos.y, vp.y - hover_item_card.size.y - 8)
# 	hover_item_card.position = pos
#
# func _on_shop_card_hover_started(weapon: ItemWeapon) -> void:
# 	if weapon == null:
# 		return
# 	hover_item_card.item = weapon
# 	hover_item_card.show()
# 	_follow_mouse()
#
# func _on_card_hover_ended() -> void:
# 	hover_item_card.hide()


# ──────────────────────────────────────────────────────────────

## 开商店：抽 4 件候选、铺成 4 张 ShopCard。
## 参数 current_wave：当前波数（Arena 传 spawner.wave_index）。它只影响**稀有度权重**
##   （哪些档解锁、概率多少），不影响数量。
## 返回值：无。
## 副作用：
##   · 先清空 %ItemsContainer（queue_free 是帧末生效，本帧内新卡会与待删卡共存）；
##   · 读 Global.SHOP_PROBABILITY_CONFIG 调 Global.select_items_for_offer() ——
##     该调用会读 Global.player.stats.luck 并 print 一行概率调试信息（所以 Global.player 必须已存在）；
##   · 每张卡：连 on_item_purchased → _on_item_purchased（购买后的业务）、
##     mouse_entered → _on_shop_card_hover_started.bind(卡片)、mouse_exited → _on_card_hover_ended，
##     然后 **add_child 之后再赋 shop_item**（卡片 setter 要用 @onready 的 % 节点，没入树就是 null）；
##   · **不** show() 面板 —— 显隐由 Arena 负责（Arena 的顺序是 load_shop() 然后 show()）。
## 提示：本函数不清空 weapons/passives 两个"已拥有"网格 —— 那是 _ready() 的活，
##   而它们在整局里是跨波累积的，正是想要的。
func load_shop(current_wave: int) -> void:
	# 清掉上一轮的货架（queue_free 帧末生效，所以本帧内新旧卡会共存）
	for child in items_container.get_children(): child.queue_free()
	
	# 概率配置是 const 字典，只读不改所以直接引用
	var config := Global.SHOP_PROBABILITY_CONFIG
	# 抽 4 件商品：返回值是**弱类型 Array**，所以下面循环要自己标注 `shop_item: ItemBase`。
	# ⚠ 这个调用会读 Global.player.stats.luck —— 必须已经选完人、玩家已存在。
	# ⚠ 池里不同项少于 4 时会**死循环**（见 Global.select_items_for_offer 的注释）。
	var selected_items := Global.select_items_for_offer(shop_items, current_wave, config)
	for shop_item: ItemBase in selected_items:
		# 类型标注成 ShopCard 就是做一次断言式转换；场景根节点不是 ShopCard 会在赋值时报错
		var card_instance := SHOP_CARD_SCENE.instantiate() as ShopCard
		# 信号一律在这里（创建时）接好 —— 这是"不需要事后遍历容器"的关键。
		# 购买信号不带额外参数：ShopCard emit 的就是它自己的 shop_item，正好是回调要的 ItemBase。
		card_instance.on_item_purchased.connect(_on_item_purchased)
		# 悬停要额外传"是哪张卡"（当锚点），所以用 .bind(card_instance) 追加参数
		card_instance.mouse_entered.connect(_on_shop_card_hover_started.bind(card_instance))
		# mouse_exited 无参，直接接
		card_instance.mouse_exited.connect(_on_card_hover_ended)
		# ★ 必须先进树：卡片 setter 里要用 @onready 的 %ItemIcon 等，没入树就是 null
		items_container.add_child(card_instance)
		# 入树之后再灌数据
		card_instance.shop_item = shop_item
	
	# 旧方案：事后遍历容器去接信号（错的，遍历的是节点不是数组）
	# for weapon: ItemWeapon in weapons_container:
	# 	hover_item_card.mouse_entered.connect(_on_shop_card_hover_started.bind(weapon))
	# 	hover_item_card.mouse_exited.connect(_on_card_hover_ended)


## **唯一的 ItemCard 工厂**：所有"已拥有"的卡片（初始武器 / 买到的武器 / 买到的被动 / 合成后的新武器）
## 都必须经过这里创建，好处是三条信号**只在一处接**，不会漏接或重复接。
## 参数：无。返回值：ItemCard —— 注意它**还没有被 add_child**，也还没赋 item；
##   调用方负责 add_child() + 赋 item（顺序不能反：ItemCard 的 setter 要用 $ItemIcon）。
## 副作用：
##   · 实例化 Global.ITEM_CARD_SCENE（这个场景常量放在 Global 里，因为它是公共资源）；
##   · 连三条信号：
##       on_item_card_selected → _on_item_card_selected（点选 → 决定"合成"按钮可不可用）
##       mouse_entered        → _on_item_card_hover_started.bind(卡片)（TooltipManager 弹提示）
##       mouse_exited         → _on_card_hover_ended（收起提示）
##   · 注意 ItemCard 自己的 .tscn 也把 pressed/mouse_entered 自连到了它自己的回调（放音效），
##     所以鼠标进入一张 ItemCard 会同时触发"音效"和"弹提示"两条独立连接。
##   · 不 add_child、不 emit、不碰 Global。
func create_item_card() -> ItemCard:
	var item_card := Global.ITEM_CARD_SCENE.instantiate() as ItemCard
	item_card.on_item_card_selected.connect(_on_item_card_selected)
	# ItemCard 全部经过这里创建（购买/合成/初始武器），一处接好就够了
	item_card.mouse_entered.connect(_on_item_card_hover_started.bind(item_card))
	item_card.mouse_exited.connect(_on_card_hover_ended)
	return item_card


## 便捷封装：创建一张 ItemCard 并放进 %WeaponsContainer（"已装备武器"网格）。
## 参数 weapon：这张卡代表的武器数据。
## 返回值：无（不返回卡片 —— 需要引用请直接用 create_item_card() 那一套）。
## 副作用：转调 create_item_card()（连好信号）→ add_child 进 weapons_container → 赋 item。
## 谁在用：Arena._on_selection_panel_on_selection_completed() ——
##   开局把选中的初始武器显示到"已拥有"格子里（那一把武器是**没经过商店**获得的）。
func create_item_weapon(weapon: ItemWeapon) -> void:
	var card := create_item_card()
	weapons_container.add_child(card)
	card.item = weapon


## "下一波"按钮的回调（shop_panel.tscn 里编辑器把 NextWaveButton.pressed 连到这里）。
## 参数：无。返回值：无。
## 副作用：播一次 UI 音效 → emit on_shop_next_wave（无参）→
##   （arena.tscn 里连好的）Arena._on_shop_panel_on_shop_next_wave()：hide 本面板 + start_new_wave()
##   → start_new_wave() 会把 Global.game_paused 置 false、让玩家 +1 波成长、spawner 开新波。
## 注意：本函数**不关面板、不发钱、不校验**任何东西 —— 就是个信号转发口。
##   之所以绕一圈交给 Arena，是因为"开新波"需要 Spawner / Arena 的信息，商店不该知道这些。
func _on_next_wave_button_pressed() -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	on_shop_next_wave.emit()


## 购买成功回调（ShopCard emit on_item_purchased 时触发；金币**已经在卡片那边扣过了**）。
## 参数 item：刚买到的道具数据。
## 返回值：无。
## 副作用（按 item_type 分支）：
##   · WEAPON ：把卡放进 %WeaponsContainer；
##     Global.player.add_weapon(weapon) —— 这一步会 **instantiate 出 Weapon 节点**挂到玩家身上，
##       并加入 Player.current_weapons（场上节点列表）；
##     Global.equipped_weapons.append(weapon) —— 这是**数据**列表，用来判"上限 6"和"同名两把可合成"。
##       两条记录必须同时维护，少一条就会出现"格子有卡但合成按钮不亮"之类的怪象。
##   · PASSIVE：把卡放进 %PassivesContainer；passive.apply_passive() **就地修改
##       Global.player.stats**（永久加减，无回滚），StatsContainer 下一帧就会显示新数值。
##   · 最后 `item_card.item = item` 给卡片填数据 —— 位置在 add_child **之后**（顺序不能反）。
## ⚠ 没有 else 分支：如果 item 是 UPGRADE 类型（正常不该出现在商店），
##   这张卡既不会被加进任何容器，又会被赋 item —— 节点不在树里 → setter 里的 $ItemIcon 是 null → 报错，
##   而且这个游离节点不会被释放。往 shop_items 里加道具时务必只用武器/被动。
## 时序：本函数是在 ShopCard._on_buy_button_pressed() 的 emit 里**同步**执行的；
##   等本函数返回后，那张 ShopCard 才会执行自己的 queue_free()（买完下架）。
func _on_item_purchased(item: ItemBase) -> void:
	var item_card := create_item_card()
	
	# 注意：这里先把卡片塞进对应容器、再做实际生效的玩法操作（装武器 / 加被动），
	# 顺序上"界面先出现，数值随后"，两者之间没有 await，玩家看不到中间态。
	if item.item_type == ItemBase.ItemType.WEAPON:
		weapons_container.add_child(item_card)
		# as ItemWeapon：ItemBase → 子类，类型不符会得到 null 并在下一行报错
		var weapon := item as ItemWeapon
		# 这一步才真正"拥有"这把武器：往玩家节点上挂 Weapon 节点（Player.add_weapon 内部 instantiate）
		Global.player.add_weapon(weapon)
		# 同时登记进"已装备武器的数据列表"（上限 6 / 同名可合成的判定都读它）
		Global.equipped_weapons.append(weapon)
		
	elif item.item_type == ItemBase.ItemType.PASSIVE:
		passives_container.add_child(item_card)
		var passive := item as ItemPassive
		# 被动立刻生效：就地改 Global.player.stats（共享 Resource），不可撤销
		passive.apply_passive()
		
	item_card.item = item


## 某张"已拥有"卡片被点选 → 记住它，并据此决定"合成"按钮是否可用。
## 参数 card：被点中的 ItemCard（来自 create_item_card() 里连的 on_item_card_selected）。
## 返回值：无。
## 副作用：
##   · 写 context_card（后续合成 / 卖出都以它为操作对象）；
##   · 写 combine_button.disabled —— 这是本函数**唯一**的界面效果；
##   · 不 emit 信号、不改 Global。
## 判定规则：只有**武器**才可能可合成；在 Global.equipped_weapons（数据列表）里数同名武器的**数量**，
##   ≥ 2 就把按钮点亮。注意数的是"装备数据"而不是"网格里的卡片" —— 理论上两者应该一致，
##   但合成/卖出时若只同步了一边，这里就会与实际不符。
## ⚠ 两个已知缺口：
##   · 只用一个 bool 决定按钮状态，**卖出按钮从来不置灰** —— 点了也没反应的唯一保护是
##     _on_sell_button_pressed() 里的 `if not context_card: return`；
##   · 点被动道具也会走这里（card.item 是 ItemPassive），此时 can_merge 保持 false、按钮置灰，
##     但 context_card 仍被设成那张被动卡 —— 于是紧接着点"卖出"会拿被动当武器处理
##     （`as ItemWeapon` 得到 null → 下一行访问 item_cost 报错）。属于潜在崩溃点。
func _on_item_card_selected(card: ItemCard) -> void:
	context_card = card
	var can_merge := false
	if card.item.item_type == ItemBase.ItemType.WEAPON:
		# 同名武器计数：遍历"已装备武器的数据列表"，数 item_name 相同的数量。
		# 比的是 item_name（字符串）而不是资源引用 —— 所以不同 .tres 只要名字一样就算同名，
		# 这也是"武器名写错/写重"会引发意外合成的原因。
		var count := 0
		for weapon: ItemWeapon in Global.equipped_weapons:
			if weapon.item_name == card.item.item_name:
				count += 1
		if count >= 2:
			can_merge = true
		
	combine_button.disabled = not can_merge


## "合成"按钮的回调（shop_panel.tscn 里编辑器把 CombineButton.pressed 连到这里）。
## 作用：把**两张同名武器**合并成它的下一档（ItemWeapon.upgrade_to），
##   两把旧武器连节点带卡片一起删掉，再按新武器补一把。
## 参数：无（操作对象是 context_card，由 _on_item_card_selected 设好）。返回值：无。
## 副作用（按顺序）：
##   1) 删除旧武器：Global.player.current_weapons.erase(节点)（场上节点列表）、
##      Global.equipped_weapons.erase(weapon.data)（数据列表）、weapon.queue_free()（销毁节点）；
##   2) 删除两张旧卡片：card.queue_free()；
##   3) 生成升级版：load(clicked_weapon.upgrade_to.resource_path) → add_weapon + append；
##   4) 补一张新的 ItemCard 显示升级后的武器；
##   5) context_card = null（**这一步很关键**，否则下次点"合成"会拿已释放的卡当操作对象）。
## 三条静默早退（都只在进函数时响了一声音效）：
##   · context_card 为空（还没点选任何卡）；
##   · 点的那把武器没有 upgrade_to（是最高档或本来就不能合成）—— 注意 combine_button 的
##     disabled 只保证"同名 ≥ 2"，**不保证有下一档**，所以这里必须再查一次；
##   · 找齐的两边数量不足 2（数据列表和 UI 卡片对不上时）。
## 实现要点：
##   · 两个 filter 各取前 2 个（slice(0, 2)）。`current_weapons` 里装的是 **Weapon 节点**，
##     要拿名字得走 `w.data.item_name`（节点持有 ItemWeapon 数据）；卡片侧则是 `c.item.item_name`。
##   · `filter(func(c: ItemCard): ...)` 对元素做了**类型标注**：如果 weapons_container 里混进了
##     不是 ItemCard 的节点（比如编辑期那些裸 Button 占位），这里会直接报错 ——
##     平时没事是因为 _ready() 已经把占位节点清掉了。
##   · 为什么用 load(path) 重新读一遍，而不是直接用 upgrade_to 对象：按路径加载拿到的是
##     引擎缓存里的**规范资源**（和别的引用是同一份），也顺手验证了"下一档真的存在于磁盘"。
##     ⚠ 反过来说：upgrade_to 指向的资源如果是运行时 new 出来的（没有 resource_path），
##     load("") 会失败并返回 null，后面 add_weapon(null) 就会崩。
func _on_combine_button_pressed() -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	if not context_card:
		return
		
	var clicked_weapon := context_card.item as ItemWeapon
	if not clicked_weapon.upgrade_to:
		return
	
	# 一边是"场上的 Weapon 节点"（走 .data 拿名字），一边是"UI 上的 ItemCard"（走 .item 拿名字）。
	# slice(0, 2) 只取前两个：即使同名武器有 3 把以上，也只合成最早的两把。
	var weapons_to_remove: Array[Weapon] = Global.player.current_weapons.filter(func(w: Weapon):
		return w.data.item_name == clicked_weapon.item_name).slice(0, 2)
		
	# get_children() 返回的是 Node 数组，靠 lambda 的 `c: ItemCard` 标注做类型过滤
	var card_to_remove = weapons_container.get_children().filter(func(c: ItemCard):
		return c.item.item_name == clicked_weapon.item_name).slice(0, 2)
	
	# 两边都得凑齐 2 个才动手 —— 否则宁可什么都不做（避免删一半留下烂摊子）
	if weapons_to_remove.size() < 2 or card_to_remove.size() < 2:
		return
	
	# 两套记录都删：节点列表 + 数据列表。只删一边会导致"上限 6"和"合成判定"与实际不符。
	for weapon: Weapon in weapons_to_remove:
		Global.player.current_weapons.erase(weapon)
		Global.equipped_weapons.erase(weapon.data)
		weapon.queue_free()
		
	for card: ItemCard in card_to_remove:
		card.queue_free()
	
	# 按路径重新加载"下一档"武器资源：拿到的是引擎缓存里的规范资源，
	# 同时能验证该 .tres 真的存在于磁盘（内存里 new 出来的资源没有 resource_path，这里会失败）
	var upgraded_weapon: ItemWeapon = load(clicked_weapon.upgrade_to.resource_path)
	Global.player.add_weapon(upgraded_weapon)
	Global.equipped_weapons.append(upgraded_weapon)
	
	var new_card := create_item_card()
	weapons_container.add_child(new_card)
	new_card.item = upgraded_weapon

	# ★ 必须清空：context_card 指向的那张卡刚刚已经 queue_free 了，
	# 留着它的话，下次点合成/卖出会去访问一个已释放的对象。
	context_card = null


## "卖出"按钮的回调（shop_panel.tscn 里编辑器把 SellButton.pressed 连到这里）。
## 作用：把当前点选的武器卖掉一把，返还**售价的 75%（向下取整）**。
## 参数：无（操作对象是 context_card）。返回值：无。
## 副作用：
##   · 从 Global.player.current_weapons 删掉**找到的第一把**同名武器节点并 queue_free()，
##     同时从 Global.equipped_weapons 删掉它的数据（两套记录必须同步）；
##   · 销毁 context_card 那张卡片，并把 context_card 置空；
##   · **Global.coins += coins**（金币变多；CoinsBag 会在下一帧显示出来）。
## 早退：context_card 为空时只响一声音效就返回（卖出按钮从来不置灰，全靠这句兜底）。
## 换算：`int(item_cost * 0.75)` —— 先算浮点再 int()，是**截断**不是四舍五入，
##   所以 21 金币的武器卖 15（15.75 截断），不是 16。留了 25% 的"折旧"。
## 注意与合成的差别：合成用 .slice(0, 2) 要凑两把，卖出只用 .front() 拿**第一把**
##   （`.front()` 是取数组首元素的写法，等价于 [0]；数组为空会返回 null，
##    代码紧接着用 `if weapon_to_remove:` 兜住了这个 null）。
## 一个已知缺口：卖完之后**没有**重算 combine_button.disabled（按钮可能还亮着，
##   再点合成会因为凑不齐两把同名武器而静默失败）；
##   另外 `as ItemWeapon` 若拿到 null（例如点的是被动道具），下一行读 item_cost 会直接报错。
func _on_sell_button_pressed() -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	if not context_card:
		return
	var clicked_weapon := context_card.item as ItemWeapon
	# 返还价：售价的 75%，int() 是**截断**（21 → 15，不是 16）
	var coins := int(clicked_weapon.item_cost * 0.75)
	# .front() 取数组首个元素（等价 [0]）；找不到同名武器时返回 null，
	# 所以下面必须用 `if weapon_to_remove:` 兜住 —— 否则删除操作会拿 null 去调用
	var weapon_to_remove: Weapon = Global.player.current_weapons.filter(func(w: Weapon): 
		return w.data.item_name == clicked_weapon.item_name).front() as Weapon

	if weapon_to_remove:
		Global.player.current_weapons.erase(weapon_to_remove)
		Global.equipped_weapons.erase(weapon_to_remove.data)
		weapon_to_remove.queue_free()
	
	# 卡片自己销毁自己（queue_free 帧末生效），然后把引用清空 —— 和合成那侧一样要清，
	# 否则下次点"卖出/合成"会去操作一张已经被释放的卡。
	context_card.queue_free()
	context_card = null
	# 金币入账。注意顺序是"先销毁卡片、最后加钱"，中间没有 await，玩家看不到中间态；
	# CoinsBag 是每帧轮询 Global.coins 的，所以下一帧数字就会变。
	Global.coins += coins
