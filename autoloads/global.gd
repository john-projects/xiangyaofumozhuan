## ═══════════════════════════════════════════════════════════════════════════
## Global —— 全局状态 + 全局资源表（autoload 单例）
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   project.godot 的 [autoload] 第一行 `Global="*uid://bdjgulsh2dnnk"`（指向本脚本，不是场景），
##   所以它由引擎在启动时自动实例化，任何场景、任何脚本都能直接用 `Global.xxx` 访问。
##   它是全项目共享的"黑板"：金币、背包/装备、当前主角、公共资源 preload、稀有度样式。
##   竞技场时代的那批东西（选人结果 / 玩家节点 / 波次概率 / 抽卡）已随竞技场一起移除。
##
## 本文件的职责（正好是从上到下的顺序）：
##   1. 公共资源常量：飘字场景、按稀有度分的 StyleBoxFlat
##   2. 稀有度配色与枚举：UpgradeTier + TIER_COLORS
##   3. 运行时状态：coins / main_player_selected / equipped_weapons（背包）/ equipment（穿着）
##   4. 资源扫描：可招募队友、商人货架上的装备
##   5. 工具函数：概率判定、UI 键盘焦点导航、属性格式化
##
## 数据流（谁写谁读）：
##   · coins              写：GameRoot 开局重置 / 战斗奖励、买/卖装备；读：背包信息行
##   · equipped_weapons   写：GameRoot.buy_item / sell_item / equip_item / unequip_slot
##                        读：BagPanel（背包格子）、MerchantPanel（"持×n" 角标）
##   · equipment_by_character  写：GameRoot.equip_item / unequip_slot（每人一套）
##                        读：BagPanel 的 6 个装备栏（按当前展示的角色取）
##   · main_player_selected 写：GameRoot.start_game_with_defaults；读：WorldMap / BagPanel 的头像
##
## 坑（改之前务必看）：
##   · 这些字段**跨场景存活**：切屏不会重置。开新档必须像 GameRoot.start_new_game() 那样
##     逐项手动清（coins / equipped_weapons / equipment_by_character / main_player_selected）。
##   · 所有 *_SCENE 常量都是 preload（编译期绑定）：路径改名/删除会直接报错。
##
## 与其他 autoload 的关系：
##   SoundManager（autoloads/sound_manager.gd + 场景）负责音效；TooltipManager 负责悬停提示卡。
##   三者互相独立，都只是"全局可访问"，没有依赖顺序。
extends Node

## ── 公共资源表：场景 ────────────────────────────────────────────────────────
## preload 在脚本加载时就完成，运行期零查找开销；想换美术表现只改这里的 uid，调用方不用动。
const FLOATING_TEXT_SCENE = preload("uid://btdihrlsugqm0")      # 飘字（FloatingText）。Battle.create_floating_text() 实例化它

## ── 公共资源表：稀有度样式 ──────────────────────────────────────────────────
## StyleBoxFlat，配 get_tier_style() 使用，给卡片描边/底色分档。
## 卡片侧统一这样用：add_theme_stylebox_override("panel", Global.get_tier_style(tier))
const COMMON_STYLE = preload("uid://c383vl8xrt17p")             # 普通（无描边）
const EPIC_STYLE = preload("uid://bvy27iuomo6rx")               # 史诗（紫）
const LEGENDARY_STYLE = preload("uid://v4id7ydojihc")           # 传说（红）
const RARE_STYLE = preload("uid://5vcw7m8i2ilu")                # 稀有（蓝）。注意本组顺序是 C/E/L/R，不是按枚举顺序排的，读的时候别被绕到

## ── 稀有度配色 ──────────────────────────────────────────────────────────────
## 稀有度 → 描边颜色。使用者：BagPanel（背包格子）、MerchantPanel（货架格子）
## 按 item_tier 取色画格子描边；ItemBase 的悬停卡则走 get_tier_style()。
## 注意：
##   · 故意**没有** COMMON 项 —— 普通档在格子上走"默认灰白描边"那条兜底分支
##     （调用方都是 TIER_COLORS.get(tier, 兜底色)），直接 TIER_COLORS[COMMON] 会因为键不存在而报错；
##   · 颜色是 0~1 的浮点 RGB（不是 0~255），A(alpha) 省略即 1.0；
##   · UpgradeTier 枚举虽然声明在下面，但 GDScript 的顶层符号在解析阶段统一收集，
##     所以这里能直接引用 UpgradeTier.*；把两者的先后顺序调换也不会报错。
const TIER_COLORS: Dictionary[UpgradeTier, Color] = {
	UpgradeTier.RARE: Color(0.0, 0.557, 0.741),        # 蓝（约 #008EBD）
	UpgradeTier.EPIC: Color(0.478, 0.251, 0.71),       # 紫（约 #7A40B5）
	UpgradeTier.LEGENDARY: Color(0.906, 0.212, 0.212), # 红（约 #E73636）
}

## ── 稀有度枚举 ──────────────────────────────────────────────────────────────
## 道具的稀有度。数值必须与 .tres 里存的整数一致（item_tier = 1 就等于 RARE），
## 所以**只能在末尾追加**成员；顺序同时也是 UI 上由低到高的展示顺序。
enum UpgradeTier{
	COMMON,     # 0：普通。没有专属配色，get_tier_style() 返回 COMMON_STYLE
	RARE,       # 1：稀有（蓝）
	EPIC,       # 2：史诗（紫）
	LEGENDARY   # 3：传说（红）。它同时是 get_tier_style() 的 _ 兜底分支，所以非法值看起来会"像传说"
}

## ── 门派表 ──────────────────────────────────────────────────────────────────
## 五个门派的**固定规则**（id → 名字 / 收哪些种族 / 一句介绍）。
## 为什么写成常量而不是 .tres：门派是"游戏规则"而不是"可编辑内容"，
##   只有 5 个、永远这 5 个，而且种族限制同时被 NPC 面板、GameRoot.join_sect()、UI 读 ——
##   放这里一份，改规则只改这一处（和 TIER_COLORS 同一个思路）。
## races 里存的是 UnitStats.Race 的枚举值，顺序即 UI 上的展示顺序。
## 谁读：GameRoot.join_sect()/can_join_sect()（能不能拜）、
##   WorldMap._build_sect_buttons()（拜师面板）、StatsPanel（显示门派名）。
const SECTS := {
	"taixu": {
		"name": "太虚剑宗",
		"races": [UnitStats.Race.HUMAN],
		"desc": "以剑入道，只收人族弟子。剑意凌厉，最重一口气。",
	},
	"piaomiao": {
		"name": "缥缈仙府",
		"races": [UnitStats.Race.HUMAN, UnitStats.Race.IMMORTAL],
		"desc": "云海之上的人仙双修之地，人族与仙族皆可入门。",
	},
	"zixiao": {
		"name": "紫霄神道教",
		"races": [UnitStats.Race.IMMORTAL],
		"desc": "仙族正统，执掌雷法，非仙族血脉不传。",
	},
	"wanyao": {
		"name": "万药谷",
		"races": [UnitStats.Race.IMMORTAL, UnitStats.Race.DEMON],
		"desc": "不问出身，只问药性；仙族与魔族在此共炼灵丹。",
	},
	"xingluo": {
		"name": "星罗教",
		"races": [UnitStats.Race.DEMON],
		"desc": "魔族秘教，以星象卜命，只纳魔族为徒。",
	},
}
## 五个门派的展示顺序（= 建邺城里 NPC 的排列顺序，也是以后做门派列表时的顺序）。
const SECT_ORDER := ["taixu", "piaomiao", "zixiao", "wanyao", "xingluo"]

## ── 门派技能表 ──────────────────────────────────────────────────────────────
## 每个门派：2 个被动 + 3 个主动，**拜入门派时自动全部学会（1 级）**，之后随玩家等级一起成长
## （见 GameRoot.join_sect / _bump_sect_skill_levels；最高 100 级）。
##
## 字段约定：
##   被动：id / name / stat（加成哪种属性）/ per_level（每级加多少）/ desc
##         stat 取值（映射到 UnitStats，和战斗里真正读的字段一致）：
##           damage_pct（伤害乘算 %）、hp_pct（气血乘算 %）、crit_rate（暴击率 %）、
##           crit_damage_bonus（暴击伤害 %）、speed、defense、spell_damage（法伤）、
##           healing（治疗量）、seal_hit（封印命中率 %）
##   主动：id / name / desc + 效果参数：
##         · targets：**按等级的目标数表**，形如 [{"level":1,"count":2},{"level":30,"count":3}]
##           （取"当前等级 ≤ level"里最大的那一档；"all" 表示群体 = 用 targets_all）
##         · damage / fixed_damage：普通伤害 / 固定伤害
##         · hits：连击次数（不填 = 1）
##         · seal / silence：封印 / 封法术
##         · heal / hot：治疗 / 持续回血（hot_base_turns 基础回合，hot_turns_per_levels 每多少级 +1 回合）
##         · buff：施加的状态（crit_rate / spell_damage / crit_damage_bonus / damage_spell /
##           defense / seal_hit），buff_per_level 每级加成，buff_self 自己 / buff_all 全体队友
##         ⚠ 主动技能目前只做**数据与说明**，战斗里还不会自动释放（等技能栏/状态系统接好后再执行）。
const SECT_SKILLS := {
	"taixu": {
		"passives": [
			{"id": "taixu_jiandian", "name": "太虚剑典", "stat": "damage_pct", "per_level": 1.0,
				"desc": "太虚剑意淬体：每级提升 1% 伤害。"},
			{"id": "jianxin_tongming", "name": "剑心通明", "stat": "crit_rate", "per_level": 0.5,
				"desc": "剑心澄澈：每级提升 0.5% 暴击率。"},
		],
		"actives": [
			{"id": "sanchi_qingfeng", "name": "三尺清风", "damage": true,
				"desc": "攻击 2 个目标；技能达到 30 级后攻击 3 个目标。",
				"targets": [{"level": 1, "count": 2}, {"level": 30, "count": 3}]},
			{"id": "taixu_shenjian", "name": "太虚神剑", "damage": true, "hits": 3,
				"desc": "对单个目标连续攻击 3 次。",
				"targets": [{"level": 1, "count": 1}]},
			{"id": "renjian_heyi", "name": "人剑合一", "buff": "crit_rate", "buff_per_level": 1.0, "buff_self": true,
				"desc": "进入状态：一段时间内暴击率提升（随技能等级成长）。"},
		],
	},
	"piaomiao": {
		"passives": [
			{"id": "yunhai_xinfa", "name": "云海心法", "stat": "speed", "per_level": 0.5,
				"desc": "云海吐纳：每级提升 0.5 点速度。"},
			{"id": "piaomiao_fengxin", "name": "缥缈封心", "stat": "seal_hit", "per_level": 0.5,
				"desc": "封心锁念：每级提升 0.5% 封印命中率。"},
		],
		"actives": [
			{"id": "taixu_fengtian", "name": "太虚封天", "seal": true, "targets_all": true,
				"desc": "群体封印：封住全部敌人。"},
			{"id": "fengling_jue", "name": "封灵诀", "silence": true,
				"desc": "封住单个目标的法术，使其无法施法。",
				"targets": [{"level": 1, "count": 1}]},
			{"id": "piaomiao_jianzhi", "name": "缥缈剑指", "fixed_damage": true,
				"desc": "造成固定伤害，攻击 2 个目标；技能达到 30 级后攻击 3 个目标。",
				"targets": [{"level": 1, "count": 2}, {"level": 30, "count": 3}]},
		],
	},
	"zixiao": {
		"passives": [
			{"id": "zixiao_leiti", "name": "紫霄雷体", "stat": "spell_damage", "per_level": 1.5,
				"desc": "雷法淬炼：每级提升 1.5 点法伤。"},
			{"id": "tianlei_cuiti", "name": "天雷淬体", "stat": "defense", "per_level": 1.0,
				"desc": "雷劫炼体：每级提升 1 点防御。"},
		],
		"actives": [
			{"id": "wulei_zhengfa", "name": "五雷正法", "damage": true,
				"desc": "对单个目标降下雷法。",
				"targets": [{"level": 1, "count": 1}]},
			{"id": "leidong_jiutian", "name": "雷动九天", "damage": true,
				"desc": "攻击 3 个目标；技能达到 60 级后攻击 5 个目标。",
				"targets": [{"level": 1, "count": 3}, {"level": 60, "count": 5}]},
			{"id": "zixiao_ningshen", "name": "紫霄凝神", "buff": "spell_damage", "buff_per_level": 1.0, "buff_self": true,
				"desc": "进入状态：一段时间内法伤提升（随技能等级成长）。"},
		],
	},
	"wanyao": {
		"passives": [
			{"id": "baicao_xinjing", "name": "百草心经", "stat": "healing", "per_level": 1.0,
				"desc": "百草入药：每级提升 1 点治疗量。"},
			{"id": "yaowang_tipo", "name": "药王体魄", "stat": "hp_pct", "per_level": 0.8,
				"desc": "药王淬体：每级提升 0.8% 气血上限。"},
		],
		"actives": [
			{"id": "huichun_jue", "name": "回春诀", "heal": true, "hot": true,
				"hot_base_turns": 2, "hot_turns_per_levels": 20,
				"desc": "为队友回复气血，并附加持续回血状态（Lv.1 持续 2 回合，每 20 级 +1 回合）；目标数 1 级 2 个、25 级 3 个、50 级 4 个、75 级 5 个。",
				"targets": [{"level": 1, "count": 2}, {"level": 25, "count": 3},
						{"level": 50, "count": 4}, {"level": 75, "count": 5}]},
			{"id": "yaowu_miman", "name": "药雾弥漫", "fixed_damage": true,
				"desc": "造成固定伤害，攻击 2 个目标；30 级 3 个、60 级 4 个。",
				"targets": [{"level": 1, "count": 2}, {"level": 30, "count": 3}, {"level": 60, "count": 4}]},
			{"id": "wanling_zhufu", "name": "万灵祝福", "buff": "damage_spell", "buff_per_level": 1.0, "buff_all": true,
				"desc": "为全体队友附加状态：提升伤害与法伤（随技能等级成长）。"},
		],
	},
	"xingluo": {
		"passives": [
			{"id": "xingxiang_mogong", "name": "星象魔功", "stat": "damage_pct", "per_level": 1.0,
				"desc": "星象入魔：每级提升 1% 伤害。"},
			{"id": "souhun_zhou", "name": "摄魂咒", "stat": "crit_damage_bonus", "per_level": 0.5,
				"desc": "摄魂夺魄：每级提升 0.5% 暴击伤害。"},
		],
		"actives": [
			{"id": "xingluo_mozhua", "name": "星罗魔爪", "damage": true, "hits": 2,
				"desc": "对单个目标连续攻击 2 次。",
				"targets": [{"level": 1, "count": 1}]},
			{"id": "qunxing_yunluo", "name": "群星陨落", "damage": true,
				"desc": "攻击 3 个目标；技能达到 30 级后攻击 4 个目标。",
				"targets": [{"level": 1, "count": 3}, {"level": 30, "count": 4}]},
			{"id": "xingluo_shaji", "name": "星罗杀机", "buff": "crit_damage_bonus", "buff_per_level": 1.0, "buff_self": true,
				"desc": "进入状态：一段时间内暴击伤害提升（随技能等级成长）。"},
		],
	},
}
## 门派技能最高等级（和玩家等级上限一致）。
const SECT_SKILL_MAX_LEVEL := 100

## ── 运行时状态（跨场景存活，切场景/重开一局时不会自动清空）──────────────────
var coins: int = 500                                  # 金币（单位：枚，整数）。默认 500 与 GameRoot.starting_coins 一致；开新档时会被 start_new_game() 重置回那个值

## 玩家等级（1 ~ GameRoot.MAX_LEVEL=100）。**全队共享**：打赢一场全队一起涨经验、一起升级
## （不是每个角色各练各的 —— 战斗里上场的是整支队伍，按人分经验会出现"板凳永远 1 级"）。
## 谁写：只有 GameRoot.add_player_exp()（战斗结算里调）和 start_new_game()（重置回 1）。
## 谁读：GameRoot.attribute_points() / free_attribute_points()（等级决定自动成长与自由点数）、
##   StatsPanel（显示等级与经验）。
var player_level: int = 1
## **当前等级里**已攒的经验（不是累计总经验；升级时会把 need 扣掉，多出来的留到下一级）。
## 满级（player_level == 100）时固定为 0 —— 经验不再增长，打赢只给金币。
var player_exp: int = 0

var main_player_selected: UnitStats                   # 当前主角的角色数据（GameRoot.start_game_with_defaults 写入）。只是 Resource，没有实例化成节点

## **背包里**的道具列表（不是场上的节点）。买入 / 卖出 / 穿戴都在增删它。
## 名字沿用竞技场时代的叫法（那时它等于"玩家身上的武器"），现在它就是背包内容：
##   · **全队共用一个背包**；穿到某个角色身上的东西**不在**这里（见下面的 equipment_by_character）；
##   · 元素类型是 **ItemBase** —— 头盔/项链/武器（ItemEquipment）都放得下。
var equipped_weapons: Array[ItemBase]

## **每个角色各自**穿在身上的装备：角色键 → { 栏位类型(ItemBase.EquipType) → 那件道具 }。
## 角色键由 GameRoot.character_key() 生成（UnitStats.resource_path，没有路径时用 name）——
## 用"路径"而不是对象引用，是为了 .tres 被重新加载/复制后仍能对上同一套装备。
## 和 equipped_weapons 互补：穿上 = 从背包取出放进这里；脱下 = 放回背包。
## 空栏位就是**没有这个 key**；一个角色什么都没穿时，外层字典里也没有他的键。
## 谁写：GameRoot.equip_item(character, ...) / unequip_slot(character, ...) —— 唯一写入点；
## 谁读：BagPanel 画那 6 个装备栏（按它当前展示的角色取）。
## ⚠ 角色离队时装备**留在他名下**（不自动回背包）：重新招募同一个人会看到他原来的装备。
var equipment_by_character: Dictionary = {}

## 每个角色拜入的**门派 id**（`Global.SECTS` 的键）。角色键和装备一样用
## GameRoot.character_key()（UnitStats.resource_path）。
## 空 = 无门派（**默认状态**）；一个角色同时只能属于一个门派（想改投得先清除，目前没做）。
## 谁写：GameRoot.join_sect()（唯一写入点）；start_new_game() 会整体 clear()。
## 谁读：GameRoot.sect_of()、WorldMap 的拜师面板（"已有门派"那行）、StatsPanel（种族 · 门派）。
var sect_by_character: Dictionary = {}

## 每个角色的**门派技能等级**：角色键 → int（0 或没有这个键 = 还没学；拜入时设为 1）。
## 为什么只存一个整数：一个门派的 5 个技能是**同时学会、一起升级**的（被动/主动没有各自的等级），
##   所以"技能等级"就是"这个角色在本门的熟练度"。最高 Global.SECT_SKILL_MAX_LEVEL。
## 谁写：GameRoot.join_sect()（设 1）、GameRoot._bump_sect_skill_levels()（玩家升级时 +1）、
##   start_new_game()（清空）。
var sect_skill_level_by_character: Dictionary = {}

## 每个角色**花在五项基础属性上的自由点数**：角色键 → Array[int]（长度 5，顺序同
## GameRoot.ATTR_KEYS：体质 / 魔力 / 力量 / 耐力 / 敏捷）。
## 自动成长不住在这里 —— 那是"每升 1 级每项 +1"，由 GameRoot.attribute_total() 按等级现算；
## 这里只存玩家**手动分配**的那部分，所以"没记录 = 一点都没加过"。
## 谁写：GameRoot.allocate_attr()（唯一写入点）；start_new_game() 会整体 clear()。
var attr_alloc_by_character: Dictionary = {}

## 概率判定工具：以 chance 的概率返回 true。
## 参数 chance：0~1 的概率（不是百分数！调用方自己先除 100，例如 BattleUnit 里传 stats.block_chance / 100）。
##   传 1.0 或更大 = 必定成功；传 0.0 = 必定失败（判定用的是严格小于 random < chance）。
## 返回值：bool。
## 副作用：**推进了全局随机数生成器的状态**。
##   这点值得记住：本函数调用一次就会改变接下来所有随机数的序列，调平衡时会让人困惑（不是 bug）。
## 为什么不用 randf() < chance 一行了事：
##   保留成函数是为了让判定口径统一（暴击、格挡全走这里），也方便在这里加日志/保底。
func get_chance_success(chance: float) -> bool:
	var random := randf_range(0, 1.0)
	if random < chance:
		return true
	return false

# ───────────────────────────────────────────────────────────────────────────
#  ── 可招募队友（队伍系统）──
# ───────────────────────────────────────────────────────────────────────────

## 可招募队友的默认目录：里面每个 UnitStats（.tres / .res）都是一个能加入队伍的角色。
## MapNPC.recruit_pool 留空时，WorldMap 会调下面的 get_recruitable_players() 扫这个目录。
## 当前内容就是那 5 个可选角色（stats_player_*.tres）。
const RECRUIT_DIR := "res://resources/units/players/"

## 上一次扫描的缓存。角色的 .tres 在运行期不会变，反复开招募面板没必要反复读盘。
var _recruit_cache: Array[UnitStats] = []


## 扫描 RECRUIT_DIR，返回里面所有 UnitStats，按资源路径排序（顺序稳定，UI 不会每次乱跳）。
## 参数 refresh：true = 忽略缓存重新扫（改完目录想立刻看到效果时用）。
## 返回值：Array[UnitStats]；目录打不开时返回缓存（可能是空数组）并 push_warning。
## 副作用：写 _recruit_cache；只读磁盘，不改任何资源、不发信号。
## 坑：
##   · 两种扩展名都收 —— 打包导出后文本资源可能变成 .res，只认 .tres 会扫不到；
##   · 目录里混进非 UnitStats 的资源会被静默跳过（不报错，因为目录是给人放的）；
##   · 这条路是"方便"，不是"绝对可靠"：显式填 MapNPC.recruit_pool 才是导出万无一失的做法。
func get_recruitable_players(refresh := false) -> Array[UnitStats]:
	if not refresh and not _recruit_cache.is_empty():
		return _recruit_cache
	var dir := DirAccess.open(RECRUIT_DIR)
	if dir == null:
		push_warning("Global: 打不开可招募队友目录 %s" % RECRUIT_DIR)
		return _recruit_cache
	var found: Array[UnitStats] = []
	for file_name in dir.get_files():
		if not (file_name.ends_with(".tres") or file_name.ends_with(".res")):
			continue
		var res := ResourceLoader.load(RECRUIT_DIR + file_name)
		if res is UnitStats:
			found.append(res)
	found.sort_custom(func(a: UnitStats, b: UnitStats) -> bool:
		return a.resource_path < b.resource_path)
	_recruit_cache = found
	return _recruit_cache


## 地图线**装备**的根目录。商人 NPC（MapNPC.sell_pool 留空时）会调 get_all_equipment() 扫它。
## 结构是 equipment/<类型>/item_<类型>_<序号>.tres（头盔/武器/腰带/项链/衣服/鞋子，共 26 件），
## 图标在 assets/sprites/equipment/<类型>/。以后往这里丢新的 .tres 就自动上架。
const EQUIPMENT_DIR := "res://resources/items/equipment/"

## 装备扫描的缓存（理由同 _recruit_cache）。
var _equipment_cache: Array[ItemBase] = []


## 扫描 EQUIPMENT_DIR（**递归**），返回里面所有装备，按"栏位 → 价格 → 名字"排序。
## 参数 refresh：true = 忽略缓存重新扫（刚加了新装备想立刻看到时用）。
## 返回值：Array[ItemBase]（元素实际是 ItemEquipment）；目录打不开时返回缓存并 push_warning。
## 副作用：写 _equipment_cache；只读磁盘，不改资源、不发信号。
## 谁在用：MapNPC.sell_pool 留空时，WorldMap._rebuild_merchant() 拿它当货架。
## 为什么要排序：货架是固定 6 列方格，顺序稳定玩家才不会"买完一件整排挪位"；
##   按栏位分组（头盔…鞋子）也正好和背包角色区那 6 个装备栏一一对应，看得懂。
## 坑：只收 **item_** 前缀 —— 同目录以后若混进别的资源（数值表、贴图配置）不会被当商品。
func get_all_equipment(refresh := false) -> Array[ItemBase]:
	if not refresh and not _equipment_cache.is_empty():
		return _equipment_cache
	var found: Array[ItemBase] = []
	_collect_equipment(EQUIPMENT_DIR, found)
	found.sort_custom(func(a: ItemBase, b: ItemBase) -> bool:
		if a.get_equip_type() != b.get_equip_type():
			return a.get_equip_type() < b.get_equip_type()
		if a.item_cost != b.item_cost:
			return a.item_cost < b.item_cost
		return a.item_name < b.item_name)
	if found.is_empty():
		push_warning("Global: %s 里没扫到任何装备（目录结构应为 <类型>/item_*.tres）" % EQUIPMENT_DIR)
	_equipment_cache = found
	return _equipment_cache


## get_all_equipment() 的递归实现：把一个目录（及其子目录）里的 ItemEquipment 收进 out。
## 参数 dir_path：形如 "res://resources/items/equipment/helmet/"（**末尾要带斜杠**）。
## 参数 out：收集用的数组（原地追加）。
## 返回值：无。副作用：只读磁盘。
## 注意：子目录打不开时静默返回（和 _collect_weapons 同一套约定）。
func _collect_equipment(dir_path: String, out: Array[ItemBase]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for file_name in dir.get_files():
		if not (file_name.ends_with(".tres") or file_name.ends_with(".res")):
			continue
		if not file_name.begins_with("item_"):
			continue
		var res := ResourceLoader.load(dir_path + file_name)
		if res is ItemEquipment:
			out.append(res)
	for sub_dir in dir.get_directories():
		_collect_equipment(dir_path + sub_dir + "/", out)


# ───────────────────────────────────────────────────────────────────────────
#  ── 门派（SECTS 表的小工具）──
# ───────────────────────────────────────────────────────────────────────────

## 这个 id 是不是合法门派（SECTS 表里有它）。
func is_sect(sect_id: String) -> bool:
	return SECTS.has(sect_id)


## 门派中文名；id 不存在时原样返回（方便在日志里看出是哪个错 id）。
func sect_name(sect_id: String) -> String:
	if not SECTS.has(sect_id):
		return sect_id
	return String(SECTS[sect_id]["name"])


## 门派的一句介绍（拜师面板的说明行用）。
func sect_desc(sect_id: String) -> String:
	if not SECTS.has(sect_id):
		return ""
	return String(SECTS[sect_id]["desc"])


## 这个门派收哪些种族（UnitStats.Race 枚举值的数组，**按 UI 展示顺序**）。
func sect_races(sect_id: String) -> Array:
	if not SECTS.has(sect_id):
		return []
	return SECTS[sect_id]["races"]


## 这个门派收不收某个种族。
## 参数 sect_id：门派 id；race：UnitStats.Race 的枚举值（不是中文名）。
func sect_accepts(sect_id: String, race: int) -> bool:
	return sect_races(sect_id).has(race)


## 门派的种族限制文本：单一种族是"人族"，两个种族是"人族、仙族"。
## 谁用：拜师面板按钮上的"只收人族"、GameRoot.join_sect() 的拒绝理由。
func sect_races_text(sect_id: String) -> String:
	var parts: Array[String] = []
	for race_value in sect_races(sect_id):
		parts.append(UnitStats.race_display_name(int(race_value)))
	return "、".join(parts)


## ── 门派技能（SECT_SKILLS 表的小工具）────────────────────────────────────

## 这个门派的技能表（passives / actives 两个数组）；没有就返回空字典。
func sect_skill_table(sect_id: String) -> Dictionary:
	if not SECT_SKILLS.has(sect_id):
		return {}
	return SECT_SKILLS[sect_id]


## 这个门派的**被动技能**数组（每项是 {id,name,stat,per_level,desc}）。
func sect_passives(sect_id: String) -> Array:
	return sect_skill_table(sect_id).get("passives", [])


## 这个门派的**主动技能**数组（每项是 {id,name,desc,...效果参数}）。
func sect_actives(sect_id: String) -> Array:
	return sect_skill_table(sect_id).get("actives", [])


## 这个门派全部技能的显示名（被动在前、主动在后），给 UI 拼一行文字用。
func sect_skill_names(sect_id: String) -> Array[String]:
	var out: Array[String] = []
	for skill in sect_passives(sect_id):
		out.append(String(skill["name"]))
	for skill in sect_actives(sect_id):
		out.append(String(skill["name"]))
	return out


## 主动技能在某个技能等级下的**目标数**。
## 参数 skill：主动技能字典（见 SECT_SKILLS）；level：技能等级。
## 返回值：目标数；`targets_all = true`（群体技能）时返回 -1（UI 上显示"全体"）。
## 规则：从 targets 表里取所有"等级 ≤ level"的档位中**数量最大**的那个 —— 所以表写乱序也不怕。
func sect_skill_targets(skill: Dictionary, level: int) -> int:
	if bool(skill.get("targets_all", false)):
		return -1
	var best := 1
	for entry in skill.get("targets", []):
		if level >= int(entry.get("level", 1)):
			best = maxi(best, int(entry.get("count", 1)))
	return best


## 目标数的显示文本（"全体" / "3 个"）。
func sect_skill_targets_text(skill: Dictionary, level: int) -> String:
	var count := sect_skill_targets(skill, level)
	if count < 0:
		return "全体"
	return "%d 个" % count


# ───────────────────────────────────────────────────────────────────────────
#  ── UI 文本工具 ──
# ───────────────────────────────────────────────────────────────────────────

## 把属性数值转成界面上显示的短字符串：整数不带小数点（25 而不是 25.0），真小数保留原样（12.5）。
## 存在的原因：UnitStats 里有些字段是 float（例如 health = 15.0），直接 str() 会在 UI 上
##   出现 "15.0" 这种噪音；而让每处 UI 各写一遍格式化，迟早会出现两处不一致。
## 谁在用：WorldMap 的招募按钮/悬停提示、PartyPanel 的成员属性行。
## ⚠ 故意**不写 static**：调用点都是通过 autoload 单例写的（`Global.format_stat(...)`），
##   而"static 函数被实例调用"会触发 GDScript 的 static_called_on_instance
##   （编辑器错误面板里一刷就是几十条）。写成普通成员函数就没这个噪音，调用点一个都不用改。
func format_stat(value) -> String:
	var f := float(value)
	return str(int(f)) if is_equal_approx(f, roundf(f)) else str(f)


# ───────────────────────────────────────────────────────────────────────────
#  ── UI 键盘焦点工具（主菜单 / 世界地图共用）──
# ───────────────────────────────────────────────────────────────────────────
#  为什么放在 Global 里：这几段逻辑本来只在世界地图里（_collect_focusable / _step_focus /
#  _activate_focused / _is_interact_event）。主菜单也要键盘操作之后，它们就成了"两处要维护
#  同一套规则"的东西 —— 抽到这里一份，两边都调，行为不会分叉
#  （最容易分叉的正是"置灰按钮不进焦点环"这条）。
#
#  三处 UI 共同遵守的键盘约定：
#    · ↑↓ / Enter / 空格 —— 交给 Godot 内置的 ui_* 动作 + GUI 焦点系统，不用写代码；
#    · W S / E —— 工程自己的动作（move_up/move_down 与交互键），GUI 不认，
#      由各屏幕的 _unhandled_input 调下面的工具函数补上；
#    · E 之所以不能靠 Input 模拟 ui_accept：ui_accept 是 Enter/空格，GUI 会自己按；
#      E 不在其中，所以这里直接把按钮的 pressed 信号发出去（效果与点一下完全一样）。
#
#  ⚠ 下面这几个函数**故意不写 static**（和 format_stat 同一个理由）：调用点统一通过
#    autoload 单例调用（`Global.step_focus(...)`），而 static 函数被实例调用会被 GDScript
#    报 static_called_on_instance —— 编辑器错误面板里一次能刷出 20 多条。
#    想改成 static 就必须把所有调用点改成"类名调用"，而本脚本没有 class_name（它就是 Global 本身），
#    所以保持普通成员函数是这里唯一干净的做法。同理别把它们挪进"static 工具类"。

## 这个控件现在能不能被键盘选中：可见、没被禁用、且自己允许获得焦点。
## 参数 control：任意 Control（可以为 null，返回 false）。
func can_focus(control: Control) -> bool:
	if control == null or not control.visible:
		return false
	if control is Button and (control as Button).disabled:
		return false
	return control.focus_mode != Control.FOCUS_NONE


## 收集一个容器里所有"可点"的按钮（按树的顺序 = 视觉顺序；会递归进子容器）。
## 参数 root：容器节点（例如队伍面板的行容器、主菜单的 Center）。
## 只认 Button 是有意的：Label / 各种容器默认不该成为键盘停留点；万一某个容器
##   把 focus_mode 设成了 ALL（主题里有可能），也不该混进环里让 W/S 白停一格。
func collect_focusable(root: Node) -> Array[Control]:
	var out: Array[Control] = []
	for child in root.get_children():
		if child is Button and can_focus(child as Control):
			out.append(child as Control)
		out.append_array(collect_focusable(child))
	return out


## 在焦点环里前后循环移动焦点。
## 参数 context：树里的任意节点（只用它拿 viewport → 问"当前焦点是谁"）。
## 参数 ring：按视觉顺序排列的可聚焦控件（调用方维护，通常由 collect_focusable 得到）。
## 参数 step：+1 = 下一个，-1 = 上一个。
## 细节：当前焦点不在环里（例如玩家刚用鼠标点了别处、或环刚被重建）时从环的第一个开始 ——
##   这样 W/S 永远能"接手"焦点，不会出现"按了没反应"。
func step_focus(context: Node, ring: Array[Control], step: int) -> void:
	if ring.is_empty():
		return
	var current := context.get_viewport().gui_get_focus_owner()
	var index := ring.find(current)
	index = 0 if index < 0 else wrapi(index + step, 0, ring.size())
	ring[index].grab_focus()


## 按下"当前焦点上的那个按钮"（给 E 键用）。
## 参数 context：树里的任意节点（用它拿 viewport）。
## 返回值：true = 确实按下去了；false = 当前没有聚焦的按钮（或它是置灰的）。
func activate_focused(context: Node) -> bool:
	var current := context.get_viewport().gui_get_focus_owner()
	if current is Button and not (current as Button).disabled:
		(current as Button).pressed.emit()
		return true
	return false


## 这个事件是不是"想确认/交互"（E 或 Enter）。
## 参数 event：待判定的输入事件。
## 返回值：true = 是交互事件。
## 两套并存的原因：InputMap.has_action 先判项目里有没有配 interact 动作，
##   没配时返回 false 且不报错，于是自然回落到硬编码的 E / Enter —— 配了动作用动作，
##   没配也能用（&"interact" 是 StringName 字面量，InputMap 的键就是 StringName）。
## 注意：Enter 同时也是内置 ui_accept，会被 GUI 焦点系统先消费掉；所以实际落到调用方手里的
##   主要是 E —— 这也正是"Enter 不会触发两次"的原因。
func is_interact_event(event: InputEvent) -> bool:
	if InputMap.has_action(&"interact") and event.is_action_pressed(&"interact"):
		return true
	return event is InputEventKey and event.pressed and not event.echo \
		and (event.keycode == KEY_E or event.keycode == KEY_ENTER)


## 方格布局里用 W A S D 移动焦点（背包格子、商人货架共用）。
## 参数 event：待判定的输入事件。
## 参数 context：拿 viewport 用的节点（传哪个都行，一般就是面板自己 self）。
## 返回值：true = 这是移动键（已处理完，调用方不用再管）；false = 不是移动键，别理它。
## 副作用：可能改焦点，并把事件标记为已处理（set_input_as_handled）。
## 实现要点：**借 Godot 自己的"按几何位置找邻居"**（Control.find_valid_focus_neighbor），
##   而不是在焦点环里 ±columns 跳。原因是方格中间可能夹着不可聚焦的格子
##   （背包的空格、商人买不起的货），环里少了几格之后"±6"就不再等于"下一行同一列"了；
##   几何查找则永远按屏幕上的实际位置走，还会自动跳过不可聚焦的控件。
## 为什么抽到这里：背包和商人货架都是 6 列方格，各写一遍迟早写歪一处；
##   而且**只有面板自己知道该怎么走**，所以 WorldMap 那边对这两个浮层不能替它们处理 WASD
##   （那边是线性 ±1 的 _overlay_nav，在方格上会变成"斜着走"）。
func grid_nav(event: InputEvent, context: Node) -> bool:
	var side := -1
	if event.is_action_pressed("move_up"):
		side = SIDE_TOP
	elif event.is_action_pressed("move_down"):
		side = SIDE_BOTTOM
	elif event.is_action_pressed("move_left"):
		side = SIDE_LEFT
	elif event.is_action_pressed("move_right"):
		side = SIDE_RIGHT
	if side < 0:
		return false
	var viewport := context.get_viewport()
	var owner := viewport.gui_get_focus_owner()
	# 焦点还不在方格上时（例如刚打开面板）先不动，交给 _set_focus_ring() 的初始聚焦
	if owner != null:
		var neighbor := owner.find_valid_focus_neighbor(side)
		if neighbor != null:
			neighbor.grab_focus()
	viewport.set_input_as_handled()
	return true


## 稀有度 → 卡片样式（StyleBoxFlat），给卡片的主题覆盖用。
## 调用方（HoverItemCard / HoverUnitCard）这样用：
##   add_theme_stylebox_override("panel", Global.get_tier_style(道具的 item_tier))
## 参数 tier：UpgradeTier 枚举值（通常直接来自 ItemBase.item_tier）。
## 返回值：对应稀有度的 StyleBoxFlat 常量。
## 副作用：无。但要注意返回的是**共享的 const 资源本体**，不是副本 ——
##   调用方只能读它（挂到主题覆盖上）；谁要是改了它的 border_width 之类属性，
##   会一次性污染全局所有同稀有度的卡片。
## 兜底：match 带 `_` 分支，任何没匹配上的值（含非法整数）都会拿到传说样式，而不是报错。
func get_tier_style(tier: UpgradeTier) -> StyleBoxFlat:
	match tier:
		UpgradeTier.COMMON:
			return COMMON_STYLE
		UpgradeTier.RARE:
			return RARE_STYLE
		UpgradeTier.EPIC:
			return EPIC_STYLE
		_:
			return LEGENDARY_STYLE
