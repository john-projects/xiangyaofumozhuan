## ═══════════════════════════════════════════════════════════════════════════
## ItemBase —— 所有"可购买 / 可获得道具"的数据基类（Resource）
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   道具数据体系的根。工程里三个子类都继承它：
##     · ItemWeapon  （resources/items/weapons/item_weapon.gd）—— 武器（近战 / 远程）
##     · ItemUpgrade （resources/items/upgrade/item_upgrade.gd）—— 波次结算给出的整局升级
##     · ItemPassive （resources/items/passives/item_passive.gd）—— 商店被动（有得必有失）
##   注意：resources/items/skills/item_skill.gd 并没有继承本类 —— 那是更早一版
##   "实时战斗"设计的遗留文件（它内部只依赖 SkillStats），当前工程里没有任何
##   .gd / .tres 引用 ItemSkill 与 SkillStats，读到时不必去找调用方。
##
## 数据从哪来：
##   每件道具 = 一个 .tres 资源（resources/items/**/data/*.tres，共 70 多个）。
##   数值和图标在编辑器里填，代码只按 item_type 分派行为、按 item_tier 决定外观与抽取概率。
##
## 数据到哪去：
##   · 商店：ShopPanel.shop_items 挂一批候选 → Global.select_items_for_offer() 按稀有度随机抽 4 张
##     → 实例化成 ShopCard 展示 → 玩家点购买 → ShopCard 扣 Global.coins（扣的就是本类的 item_cost）
##     → ShopPanel._on_item_purchased() 按 item_type 分派（装武器 / 加被动）
##   · 升级：UpgradePanel.upgrade_list 同样走 Global.select_items_for_offer()，抽 4 张给 UpgradeCard
##   · 展示：ItemCard 只取 item_icon，并用 item_tier 去 Global.get_tier_style() 拿描边 StyleBoxFlat
##   · 悬停提示：TooltipManager 登记了 ItemBase → hover_item_card.tscn（属性名 "item"），
##     它按"继承链"查找登记项，所以登记基类就能命中所有子类；卡片会调用本类的 get_description()
##
## 坑：
##   · item_tier 的类型写作 Global.UpgradeTier —— 枚举其实定义在 autoload 的 global.gd 里，
##     跨文件用 autoload 名当命名空间是允许的，前提是 global.gd 已在 project.godot 里登记为自动加载。
##   · .tres 里存的是整数下标（item_tier = 1、item_type = 2 …）。枚举成员顺序一旦调整，
##     所有旧资源都会静默错位、不报错。因此下面两个枚举只能在末尾追加成员。
extends Resource
class_name ItemBase

## 道具大类。决定"到手之后走哪条分支"（见 ShopPanel._on_item_purchased）：
##   WEAPON  = 0 → 装到玩家身上（Player.add_weapon）并追加进 Global.equipped_weapons；
##                 同名两把可在商店里点"合成"升级（走 ItemWeapon.upgrade_to）
##   UPGRADE = 1 → 属于波次结算的升级池（UpgradePanel.upgrade_list），不会出现在商店里
##   PASSIVE = 2 → 立即执行 ItemPassive.apply_passive()，永久加减 Global.player.stats，不可撤销
## .tres 里写的就是这个顺序的下标，所以只能在末尾追加新成员。
enum ItemType{
	WEAPON,
	UPGRADE,
	PASSIVE
}

@export var item_name: String                # 显示名。商店卡 / 道具卡 / 提示卡标题都用它；同时也是"两把同名武器可合成"的判定键
@export var item_icon: Texture2D             # 图标。ItemCard / ShopCard / SelectionCard / HoverItemCard 都直接取这张贴图
@export var item_tier: Global.UpgradeTier    # 稀有度（COMMON=0 / RARE=1 / EPIC=2 / LEGENDARY=3）。只影响描边颜色与抽取概率，不直接改数值
@export var item_type: ItemType              # 道具大类，见上面的 ItemType 注释；决定购买后的行为分支
@export var item_cost: int                   # 商店售价（单位：金币，默认由 .tres 决定，常见 20~60）。0 表示非卖品；卖出时按 75% 向下取整返还

## 返回 BBCode 富文本描述，供 RichTextLabel.set_text() 直接使用（支持 [color=...]、[code] 等标签）。
## 基类返回空串：因为"描述长什么样"完全取决于子类怎么解释自己的字段：
##   · ItemWeapon / ItemSkill 拼伤害、冷却、射程、暴击率
##   · ItemPassive 拼加 / 减属性
##   · ItemUpgrade 不走这里，它自己另有一个纯文本的 @export var description
## 参数：无（数据全在自身字段里）。
## 返回值：BBCode 字符串。
## 副作用：无。纯函数，不读 Global、不 emit 信号、不分配节点，可以在任何线程/任何时机安全调用。
func get_description() -> String:
	return ""
