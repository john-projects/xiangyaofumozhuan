## ═══════════════════════════════════════════════════════════════════════════
## ShopCard —— 商店里"待售商品"的候选卡（含价格与购买按钮）
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   和 ItemCard 是一对：**ShopCard = 在卖的候选（会自己消失），ItemCard = 已买到手的记录（常驻）**。
##   由 ShopPanel.load_shop() 实例化（preload 常量 SHOP_CARD_SCENE 写在 ShopPanel 里，
##   不在 Global 里 —— 因为只有商店用得到它）。
##
## 数据流（一次购买的完整链路）：
##   ShopPanel.load_shop() → Global.select_items_for_offer() 抽 4 件 ItemBase
##     → 每件实例化成一张 ShopCard，add_child 之后赋 shop_item
##     → _set_shop_item() 填图标/名字/类型/描述/价格 + 按稀有度换描边
##   → 玩家点 BuyButton → _on_buy_button_pressed()
##     → 校验（武器最多 6 把、金币够不够）→ 扣 Global.coins → emit on_item_purchased(shop_item)
##     → ShopPanel._on_item_purchased() 把道具真正发给玩家（装武器 / 加被动）并生成一张 ItemCard
##     → 回到本函数，queue_free() 自己：这件商品从货架上消失
##
## 坑：
##   · 自己 queue_free() 自己：这是刻意的（买完即下架，格子空出来）。
##     因此 ShopPanel **不能**在购买后还持有本卡片的引用；它拿到的是信号参数里的 ItemBase。
##   · 校验用的是 `shop_item` 属性、emit 出去的也是 `shop_item`，没用到局部变量；
##     只要 setter 正常跑过就不会不一致。
##   · _set_shop_item() 没有判空（同其他卡片脚本）；赋值必须在 add_child() 之后，
##     否则 %ItemIcon 这些 @onready 还是 null。
##   · 价格显示用的是 item_cost 原值；**卖出**返还的 75% 是 ShopPanel 那边算的，和本文件无关。
##   · item_cost 为 0 表示"非卖品"（见 ItemBase 注释）—— 本文件不会拦它，
##     0 金币的道具在这里可以直接白拿；要拦得在 _on_buy_button_pressed 里加判断。
extends Panel
class_name ShopCard

## 购买成功（金币已扣、卡即将自毁）。参数是本卡对应的 ItemBase 数据。
## 订阅者：ShopPanel._on_item_purchased()（它在 load_shop 里边创建边连）。
signal on_item_purchased(item: ItemBase)

## 本卡在卖的道具。setter 形式，赋值即刷新整张卡。
## ⚠ 变量名 shop_item 和 ShopPanel 上的同名 @export（那是个数组池）容易看混：
##   这里是**单个商品实例**，那边是**候选池**。
@export var shop_item: ItemBase: set = _set_shop_item

## 五个 % 节点都是 unique_name_in_owner。
## coins_label 在场景树里其实位于 BuyButton/HBoxContainer 内部（和金币小图标并排），
## 但因为勾了"访问为唯一名称"，这里照样能用 %CoinsLabel 直接取到，不受层级影响。
## item_description 是 RichTextLabel（吃 BBCode），显示的是 ItemBase.get_description()。
@onready var item_icon: TextureRect = %ItemIcon
@onready var item_name: Label = %ItemName
@onready var item_type: Label = %ItemType
@onready var item_description: RichTextLabel = %ItemDescription
@onready var coins_label: Label = %CoinsLabel

## shop_item 的 setter：整卡刷新（图标、名字、类型名、BBCode 描述、价格、稀有度描边）。
## 参数 value：要卖的道具（null 会崩，没有判空）。
## 返回值：无。
## 副作用：写五个子控件 + add_theme_stylebox_override("panel", ...)（共享样式，只挂不改）；
##   不 emit 信号、不读写 Global。
## 时序：ShopPanel.load_shop() 在 add_child() 之后调用它，保证 @onready 已就绪。
func _set_shop_item(value: ItemBase) -> void:
	shop_item = value
	item_icon.texture = value.item_icon
	item_name.text = value.item_name
	item_type.text = ItemBase.ItemType.keys()[value.item_type]
	item_description.text = value.get_description()
	# 价格单独一行显示在购买按钮里；item_cost 单位是金币（整数），直接 str() 不做格式化。
	# 注意这个 Label 是"按钮里的价格"，它不会随 Global.coins 变化 —— 它显示的是**售价**，
	# 不是玩家余额（余额由商店面板上的 CoinsBag 负责显示）。
	coins_label.text = str(value.item_cost)
	
	var style := Global.get_tier_style(value.item_tier)
	add_theme_stylebox_override("panel", style)


## "购买"按钮的回调（shop_card.tscn 里编辑器把 BuyButton.pressed 连到这里）。
## 参数：无。返回值：无。
## 副作用（成功购买时，按顺序）：
##   1) 扣 Global.coins（**唯一的全局状态写入点**，扣的就是本卡的 item_cost）；
##   2) emit on_item_purchased(shop_item) —— ShopPanel 在同一个调用栈里同步执行，
##      负责把武器装到 Global.player 身上（或执行被动效果）并生成一张常驻的 ItemCard；
##   3) queue_free() 自己 —— 买完即下架（emit 返回后才执行，所以订阅者仍能正常处理）。
## 两条早退分支（都**静默**返回：不扣钱、不 emit、不销毁，只在进函数时响了一声 UI 音效）：
##   · 武器且 Global.equipped_weapons 已有 6 把 —— 上限 6 是写死在这里的，
##     和"同名两把可合成"的判定（ShopPanel._on_item_card_selected）没有关系；
##   · 金币不够 item_cost。
## 为什么用 `>=`：到 6 就彻底不能再买（含合成空间），不是"超过 6 才拦"。
## 注意：被动（PASSIVE）道具**没有**数量上限，金币够就能一直买。
func _on_buy_button_pressed() -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	# 上限 6：只对武器生效（被动道具不限量）。6 这个数字是硬编码的，
	# Global.equipped_weapons 是"已装备武器的数据列表"，商店买入/合成/卖出都在增删它。
	# 提示：这里没有给玩家任何反馈（没有变灰、没有提示音差异），玩家只会觉得"按钮没反应"。
	if shop_item.item_type == ItemBase.ItemType.WEAPON and Global.equipped_weapons.size() >= 6:
		return
	
	# 先扣钱再广播，保证订阅者看到的是"已经付过款"的状态；
	# emit 是同步的（Godot 信号默认直连调用），所以下面这行 queue_free() 一定在
	# ShopPanel._on_item_purchased() 跑完之后才执行 —— 订阅者期间访问本卡是安全的。
	if Global.coins >= shop_item.item_cost:
		Global.coins -= shop_item.item_cost
		on_item_purchased.emit(shop_item)
		queue_free()
