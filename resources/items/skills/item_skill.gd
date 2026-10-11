## ═══════════════════════════════════════════════════════════════════════════
## ItemSkill —— 技能道具（⚠ 遗留文件：当前工程里没有任何地方引用它）
## ═══════════════════════════════════════════════════════════════════════════
## 现状（先看这段再决定要不要改它）：
##   · 全工程搜 ItemSkill / SkillStats，只有 item_skill.gd 和 skill_stats.gd 这两个文件
##     自己互相引用；没有任何 .tres 资源、没有任何 .tscn 用到它
##     （resources/items/skills/melee 与 resources/items/skills/range/fireball 两个目录都是空的）。
##   · 现役的**回合制**技能系统走的是完全另一套数据结构：
##     resources/skills/skill_data.gd（class_name SkillData）+ scenes/battle/battle.gd 的
##     Battle._perform_skill()，单位会的技能挂在 UnitStats.skills 上。
##   · 结论：本文件形态上与 ItemWeapon 同源，推测是从更早一版实时战斗设计带过来的，
##     当前只是"留着没删"，并没有接线到任何流程里。
##
## 它原本打算做什么：
##   和 ItemWeapon 几乎是同一个模子 —— 只是把 WeaponStats 换成 SkillStats，
##   而且直接 extends Resource（**不是** ItemBase）。这一点很关键：
##   意味着它天生进不了商店（ShopPanel.shop_items 的类型是 Array[ItemBase]）。
##
## 如果要复活它，至少需要：
##   (1) 改成 extends ItemBase，并补上 item_name / item_icon / item_tier / item_cost 等字段；
##   (2) 做出 SkillStats 资源与 ItemSkill 资源；
##   (3) 写一个真正读取 stats.scene 的运行时逻辑（目前谁都不读）。
##   否则现在这些字段填了也不会有人用。
extends Resource
class_name ItemSkill

## 技能形态分类（仅作标记，无任何代码读取）：
##   MELEE = 0 → 设计意图是近身判定；
##   RANGE = 1 → 设计意图是发射投射物。
enum SkillType {
	MELEE,
	RANGE
}

@export var type: SkillType        # 形态标记；目前没有任何逻辑读取它
@export var scene: PackedScene     # 技能场景（原本应是实例化出来执行技能的那个节点）；当前无引用
@export var stats: SkillStats      # 数值资源，字段见同目录 skill_stats.gd；当前无引用
@export var upgrade_to: ItemSkill  # 升级后的下一档技能资源（对应 ItemWeapon.upgrade_to 的同一套思路）；当前无引用
 
## 生成富文本描述（伤害、冷却、射程、暴击率四项）。⚠ 当前没有任何 UI 会调用它，因为本类没被实例化成资源。
## 实现细节（和 ItemWeapon.get_description() 完全同构）：
##   · 返回值是**多行字符串字面量**：从函数体那行的 " 开始，一直连到 [/code]" 才结束；
##     中间几行在源码里顶格写，是因为它们的缩进会被原样写进字符串里，不要给它们补 tab；
##   · %% 转义成字面量 %；%s 依次吃 stats.damage / cooldown / max_range / 暴击率；
##   · crit_chance 内部是 0~1 小数，这里 ×100 当百分比显示（不四舍五入）。
## 参数：无。返回值：BBCode 字符串。
## 副作用：无。stats 为 null 时会直接报错。
func get_description() -> String:
	return "[code]Damage: [color=green]%s[/color]
Cooldown: [color=green]%s[/color]
Range: [color=green]%s[/color]
Critical: [color=green]%s%%[/color]
[/code]" % [stats.damage, stats.cooldown, stats.max_range, stats.crit_chance * 100]
