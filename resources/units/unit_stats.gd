extends Resource
class_name UnitStats

## UnitStats —— 玩家与敌人的"属性表"（纯数据 Resource，一个角色一个 resources/units/*.tres）。
##
## ── 在系统里的位置 ──
##   全项目共用的数值源头。它不含任何逻辑、不发信号、不碰节点，只被别处**读**（也有两处**写**，见坑）。
##   持有者：GameRoot.party / GameRoot.enemy_pool、MapData.enemy_pool、SelectionPanel.players、
##           Spawner.enemy_collection、Unit.stats / BattleUnit.stats。
##   消费方：Unit（血量/速度/格挡）、Enemy（速度/掉落）、BattleUnit（蓝量/技能/暴击）、
##           Battle、Global（幸运抽卡、采集结算）、StatsContainer / HoverUnitCard（UI 展示）。
##
## ── 数据流向 ──
##   resources/units/*.tres（本 Resource）
##     → GameRoot（用 duplicate() 复制一份再按地图序号加成）→ Unit / BattleUnit 的 stats 字段
##       → HealthComponent.setup(stats) 取 health 当最大值
##       → Unit 每帧取 speed 位移、受击时取 block_chance 判格挡
##       → Battle 取 damage / mana / skills 结算
##     → 另一条路：Spawner.update_enemies_new_wave() 直接**就地**改 enemy_collection 里的 stats
##       → 因为 Resource 是引用语义，所有引用同一个 .tres 的敌人都会一起变强（这是刻意的，见下）
##
## ── 关于赋值风格的说明（本文件的写法不统一，但保持原样不动） ──
##   `health:= 1.0`（冒号紧贴等号）和 `mana := 20.0`（冒号后有空格）在 GDScript 里**完全等价**，
##   都是"声明并类型推断赋值"，不改变类型或行为。本文件是长期迭代留下的风格差异，不要顺手统一，
##   因为那属于无意义的整格式改动。

## 单位类型。决定这个 UnitStats 被系统当成"我方"还是"敌方"处理：
##   · 战斗里决定站位、可被谁选中、胜负判定；
##   · 敌人死亡时（Enemy._on_health_component_on_unit_died）会 emit Global.on_enemy_died 触发掉金币，
##     玩家死亡走的是另一条路（没有金币掉落）；
##   · 也能被 UI 用来挑图标/配色。
## 枚举整数值会被写进 .tres，所以不要调整成员顺序（否则所有已有资源类型会静默错位）。
enum UnitType {
	PLAYER,
	ENEMY
}

## 显示名。也是 Global 里选人字典的**键**（注释里写明"键必须等于对应 UnitStats.name 的值"），
## 所以改名会连带影响 get_selected_player() 的查找 —— 它和 id 一样属于"看着像文本其实是键"的字段。
@export var name: String
## 单位类型（PLAYER / ENEMY）。默认是枚举第 0 项 PLAYER，
## ⚠ 所以新建一个敌人 .tres 时忘了改这里，它会以"我方"身份进战斗，表现会非常费解。
@export var type: UnitType
## 头像/立绘。用于选人卡片、悬浮卡、战斗头像。留空不报错，只是没图。
@export var icon: Texture2D
## 最大生命值（单位：血点；初始值 1.0，通常玩家几十、敌人个位数）。
## 默认 1.0 是"最小值兜底"：即使某个 .tres 忘了填，单位也不会瞬间暴毙或除零。
## ⚠ 它是**模板值**：运行时真正在跑的是 HealthComponent.max_health（在 setup() 时从这里拷过去的），
##   而且如下两条路径会在战斗之间改这个模板字段本身。
@export var health:= 1.0
## 每过一波，health **就地 +该值**（单位：血点/波）。
## 由 Spawner.update_enemies_new_wave() 在波次结束时对 enemy_collection 逐条累加，
## ⚠ 因为改的是共享 Resource，引用同一个 .tres 的所有敌人会同时变强，且这种成长**不会在重开一局时重置**。
## 默认 1.0 是"线性成长"的基线，填 0 就是每波不变。
@export var health_increase_per_wave:= 1.0
## 攻击伤害（单位：血点；**不是倍率**）。最终打出去的伤害 = 本值（技能则再乘 SkillData.power）。
## 默认 1.0 是最小兜底值。
@export var damage:= 1.0
## 每过一波，damage **就地 +该值**（单位：血点/波）。和 health_increase_per_wave 同一套机制、同样的共享引用坑。
@export var damage_increase_per_wave:= 1.0
## 移动速度（单位：像素/秒），在 Unit 的 _process 里写成 position += 方向 * speed * delta。
## 默认 300：按 60fps 算每秒移动 300px，比玩家的基准（约 300 上下）留了调快调慢的余地。
@export var speed:= 300
## 幸运值，**百分数语义**（10 = +10%，不是 0.1）。
## 用途：Global 抽卡时算 luck_factor = 1 + luck/100 去放大稀有/史诗/传说概率；
## 也直接显示在属性面板上。默认 1.0 = 几乎等于没加成（刻意留成 0 附近，方便对照测试）。
@export var luck:= 1.0
## 格挡成功率，**百分数语义**（0~100+，配合 Global.get_chance_success(stats.block_chance / 100) 使用）。
## 调用处（Unit._on_hurtbox_component_on_damaged）自己先 /100 变成 0~1 再问概率 —— 所以这里填 5 表示 5%。
## 默认 0.0 = 永不格挡（不做格挡的单位不用管这个字段）。
## ⚠ 代码不做上限钳制，道具/升级理论上能把它堆到 100 以上（那就必定格挡了）。
@export var block_chance:= 0.0
## 死亡掉落的金币数量（单位：枚，整数）。Arena.spawn_coins() 会读它设 Coins.value。
## 默认 1：保证任何敌人至少掉 1 枚，不会出现"打完一波没钱"的死局。
@export var gold_drop:= 1
## 每跳回血（单位：血点/次，可以是小数）。由 Player 的 HP 回复 Timer 周期性调用
## health_component.heal(hp_regen)，并用 Global.on_create_heal_text 弹 "+N" 飘字。
## 默认 0.0 = 不回复（只有专门配了回复的玩家/道具才需要动它）。
@export var hp_regen := 0.0
## 吸血，**百分数语义**（单位是百分数：5 表示 5%）；也会显示在属性面板上。
## ⚠ 与 WeaponStats.life_steal 单位不同：武器那边是 0~1 的小数，WeaponBehavior.apply_life_steal()
##   会先把本字段 /100 再和武器的值相加，所以两处都填 5 的话实际差 100 倍。
## 默认 0.0 = 无吸血。
@export var life_steal := 0.0
## 采集效率（单位：金币/波，可以是小数）。Global.get_harvesting_coins() 在波次结算时
## 取 int(player.stats.harvesting) 加到金币上 —— ⚠ 是**截断**不是四舍五入，所以 1.9 也只发 1 枚。
## 默认 0.0 = 不采集收入。
@export var harvesting := 0.0

## 蓝量：技能消耗（没填的 .tres 用这个默认值，不会报错）
## 默认 20.0 是配合 SkillData.mana_cost 的默认 6.0 定的 —— 一场大约够放 3 次技能。
## 它是战斗内的"模板值"，运行时余额由 BattleUnit 自己维护。
@export var mana := 20.0
## 这个单位会的技能；留空的话，我方单位会用 Battle.default_skills（方便先跑通再逐个配）
## 元素类型是 SkillData；同样注意 Array[T] 只能写在冒号后（`= Array[SkillData]` 会解析报错）。
## ⚠ 敌人目前不读这个字段（敌人技能由 Battle 的敌人侧逻辑决定），所以给敌人配技能点了也没用。
@export var skills: Array[SkillData] = []
