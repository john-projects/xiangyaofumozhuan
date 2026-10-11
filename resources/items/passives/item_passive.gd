## ═══════════════════════════════════════════════════════════════════════════
## ItemPassive —— 商店里的"被动道具"（有得有失的属性置换）
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   ItemBase 的子类，item_type 固定为 ItemType.PASSIVE（.tres 里写 item_type = 2）。
##   它不生成任何节点、不进战斗、不参与每帧逻辑，只做一件事：改一份数据 —— Global.player.stats。
##
## 数据流（从哪来到哪去）：
##   resources/items/passives/data/*.tres（当前 4 个：cape / mighty_sword / power_ball / rage）
##     → 挂到 ShopPanel.shop_items 当候选池
##     → Global.select_items_for_offer() 按稀有度随机抽 4 张 → 实例化成 ShopCard
##     → 玩家点"购买" → ShopCard._on_buy_button_pressed() 检查并扣 Global.coins
##     → ShopPanel._on_item_purchased() 判定 item_type == PASSIVE 时调用下面的 apply_passive()
##     → 之后战斗里读到的 Global.player.stats 就是被改过的值（永久生效，之后没有任何环节会把它改回来）
##
## 设计意图：
##   这类道具是"置换"而不是纯增强（例如 Cape：+5 life_steal 但 -2 health），
##   所以加和减两边都各自允许为 0 —— 为 0 的那半边既不显示也不生效。
##
## 坑：
##   · add_stats / remove_stats 是字符串键，会被直接拿去索引 Global.player.stats（UnitStats 资源）。
##     写错一个字母不会编译报错，只会等到购买那一刻运行时才炸。可用键名 = resources/units/unit_stats.gd
##     里的 @export 变量名（health / damage / speed / luck / block_chance / hp_regen / life_steal / harvesting …）。
##   · 本类没有做任何去重，同一件被动可以反复购买、效果线性叠加。
extends ItemBase
class_name ItemPassive

@export var add_value: float      # 要"加"多少。单位随 add_stats 而定（life_steal 这类百分比属性填 5 表示 +5%）；0 = 无加成，不显示也不生效
@export var add_stats: String     # 加成的目标属性名，必须是 UnitStats 的 @export 字段名，如 "life_steal" / "damage" / "speed"
@export var remove_value: float   # 要"减"多少。单位随 remove_stats 而定；0 = 无代价（纯增益道具）
@export var remove_stats: String  # 代价属性名，同样是 UnitStats 的字段名，如 "health" / "speed"

## 生成商店卡 / 悬停提示卡上显示的富文本描述。
## 格式：整段包在 [code] 里等宽显示；"加"的那半标绿、"减"的那半标红，各占一行。
## 实现细节（改的时候注意）：
##   · 用 += 逐段拼接，最后才补上 "[/code]" —— 所以只有"减"没有"加"时不会多出一个空行
##     （绿的模板末尾带 \n，红的模板末尾不带）；
##   · 数值用 %s 直接拼，不取整、不补符号；"+"号是硬写在模板里的，减号靠 apply_passive 里的减法，
##     所以 remove_value 请填正数。
## 参数：无。返回值：BBCode 字符串。
## 副作用：无（纯函数；注意它读的是自身字段，不是 Global.player.stats 的实际值）。
func get_description() -> String:
	var description := "[code]"
	if add_value != 0:
		description += "[color=green] +%s %s[/color]\n" % [add_value, add_stats]
	if remove_value != 0:
		description += "[color=red] -%s %s[/color]" % [remove_value, remove_stats]
	
	description += "[/code]"
	return description

## 把本道具的增益 / 代价真正写进玩家属性。由 ShopPanel._on_item_purchased() 在购买成功时调用一次。
## 这是本文件唯一的"副作用点"：
##   · 直接就地修改 Global.player.stats（一个 UnitStats **Resource** 实例）上的字段；
##     由于 Resource 在内存里是共享引用，"改这份数据"= 改全局那份数据，没有副本可回滚；
##   · 不 emit 任何信号、不刷新 UI —— StatsContainer 要等它下一次刷新才会显示新数值；
##   · 也不做范围校验：health 被减到 0 以下该道具也照减不误（是否允许买由 ShopCard 管）。
## 参数：无（数据来自自身的 4 个 @export 字段）。
## 返回值：无。
func apply_passive() -> void:
	if add_value != 0:
		Global.player.stats[add_stats] += add_value        # 字符串当键索引 Resource 的属性，等价于 stats.set(add_stats, 旧值 + add_value)
	
	if remove_value != 0:
		Global.player.stats[remove_stats] -= remove_value  # 这里用的是减号：remove_value 本身填正数，负号语义由这句决定
