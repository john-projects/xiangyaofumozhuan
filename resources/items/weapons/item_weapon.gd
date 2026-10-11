## ═══════════════════════════════════════════════════════════════════════════
## ItemWeapon —— 武器道具（近战 / 远程），ItemBase 的子类
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   这是"商店里卖的武器数据"和"场上真正挥砍/开火的那个 Weapon 节点"之间的桥梁。
##   本文件只是**数据**（Resource）；真正的行为在 scenes/weapons/weapon.gd
##   以及两个 behavior 脚本（melee/melee_behavior.gd、range/range_behavior.gd）里。
##
## 数据流（从哪来到哪去）：
##   resources/items/weapons/{melee,range}/<武器名>/item_<武器名>_<档位>.tres（全工程 45 处引用）
##     每个 item_xxx_<档>.tres 用 scene 字段指向一个 Weapon 场景（scenes/weapons/**/weapon_xxx.tscn），
##     用 stats 字段指向一份 WeaponStats 资源（同目录的 stats_xxx_<档位>.tres）。
##     → 出现在商店候选池 ShopPanel.shop_items，或选人界面的初始武器 SelectionPanel.start_weapons
##     → 买到手：ShopPanel._on_item_purchased() → Global.player.add_weapon(本对象)
##       + Global.equipped_weapons.append(本对象)
##       （Player.add_weapon 里做 scene.instantiate()，再调 Weapon.setup_weapon(data) 把本对象挂上去）
##     → 局内升级：在商店里点两张同名武器卡 → ShopPanel._on_combine_button_pressed()
##       → load(upgrade_to.resource_path) 取出下一档武器资源 → 替换掉场上两把旧武器
##
## 坑：
##   · upgrade_to 指向的是"另一个 ItemWeapon **资源**"，不是场景。ShopPanel 用
##     load(upgrade_to.resource_path) 按路径重新加载它，所以下一档必须真的存成独立 .tres 文件；
##     内存里 new 出来的 ItemWeapon 没有 resource_path，合成按钮会静默失败。
##   · type 字段目前**没有任何代码读取** —— 运行时是靠 weapon 场景根节点上挂的是
##     MeleeBehavior 还是 RangeBehavior 来分派的。它只是给编辑器和策划看的分类标签。
##   · 同一个 ItemWeapon 资源实例可能同时被多名角色/多把武器引用（Resource 是共享的），
##     所以不要往本类里加"每个实例独有"的运行时状态。
extends ItemBase
class_name ItemWeapon

## 武器形态分类（仅作标记，见上面"坑"第二条）：
##   MELEE = 0 → 对应的 Weapon 场景根节点挂 MeleeBehavior，靠 HitboxComponent 的矩形判定打人；
##   RANGE = 1 → 对应的 Weapon 场景根节点挂 RangeBehavior，靠 Projectile 子场景飞出去打人。
enum WeaponType {
	MELEE,
	RANGE
}

@export var type:WeaponType         # 形态标记。把它改成 RANGE 并不会让武器变远程，真正决定行为的是 scene 里挂的 behavior 脚本
@export var scene: PackedScene      # 武器场景（能 instantiate() 成 scenes/weapons/weapon.gd 的 Weapon）；Player.add_weapon() 实例化它
@export var stats: WeaponStats      # 数值资源。Weapon.setup_weapon() 读 max_range 设索敌半径，behavior 每帧读伤害/冷却/散布/后座
@export var upgrade_to: ItemWeapon  # 合成后的下一档资源（商店里两把同名武器合并即变成它）；留空 = 这把武器不能合成
 
## 生成商店卡 / 悬停提示卡上显示的富文本描述（伤害、冷却、射程、暴击率四项）。
## 实现细节（改的时候注意）：
##   · 返回值是**多行字符串字面量**：从第 15 行的 " 开始，一直连到第 19 行的 [/code]" 才结束。
##     中间三行的行首在源码里是顶格写的 —— 因为它们的缩进会被原样写进字符串里。
##     不要"顺手"给这几行补 tab 缩进，否则描述文本会莫名多出空白。
##   · %% 是 GDScript 的转义，输出一个 % 号；%s 依次吃 stats.damage / cooldown / max_range / 暴击率。
##   · crit_chance 内部是 0~1 的小数，这里 ×100 转成百分比显示（没有四舍五入）。
## 参数：无。
## 返回值：BBCode 字符串。
## 副作用：无。但 stats 为 null 时会直接报错 —— 每份 item_xxx_<档>.tres 都必须填 stats。
func get_description() -> String:
	return "[code]Damage: [color=green]%s[/color]
Cooldown: [color=green]%s[/color]
Range: [color=green]%s[/color]
Critical: [color=green]%s%%[/color]
[/code]" % [stats.damage, stats.cooldown, stats.max_range, stats.crit_chance * 100]
