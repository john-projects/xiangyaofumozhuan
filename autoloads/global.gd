## Global —— 全局状态与全局资源表（autoload 单例，project.godot 里以脚本形式注册）。
## 职责：公共 preload / 稀有度配色与样式 / 金币与背包、装备等运行时状态 / 资源扫描 / UI 工具函数。
## ⚠ 状态跨场景存活：开新档必须像 GameRoot.start_new_game() 那样逐项手动清空。
## ⚠ preload 在编译期绑定，路径改名或删除会直接报错。
extends Node

## 公共 preload 资源：脚本加载时绑定，运行期零查找；换美术只改 uid。
const FLOATING_TEXT_SCENE = preload("uid://btdihrlsugqm0")      # 飘字（FloatingText）。Battle.create_floating_text() 实例化它

## 稀有度样式（StyleBoxFlat），配 get_tier_style() 用；卡片侧 add_theme_stylebox_override("panel", ...)。
const COMMON_STYLE = preload("uid://c383vl8xrt17p")             # 普通（无描边）
const EPIC_STYLE = preload("uid://bvy27iuomo6rx")               # 史诗（紫）
const LEGENDARY_STYLE = preload("uid://v4id7ydojihc")           # 传说（红）
const RARE_STYLE = preload("uid://5vcw7m8i2ilu")                # 稀有（蓝）。注意本组顺序是 C/E/L/R，不是按枚举顺序排的，读的时候别被绕到

## 稀有度 → 描边颜色（0~1 浮点 RGB）。故意没有 COMMON：调用方一律用 .get(tier, 兜底色)。
const TIER_COLORS: Dictionary[UpgradeTier, Color] = {
	UpgradeTier.RARE: Color(0.0, 0.557, 0.741),        # 蓝（约 #008EBD）
	UpgradeTier.EPIC: Color(0.478, 0.251, 0.71),       # 紫（约 #7A40B5）
	UpgradeTier.LEGENDARY: Color(0.906, 0.212, 0.212), # 红（约 #E73636）
}

## 道具稀有度。数值必须与 .tres 里存的整数一致，只能在末尾追加成员。
enum UpgradeTier{
	COMMON,     # 0：普通。没有专属配色，get_tier_style() 返回 COMMON_STYLE
	RARE,       # 1：稀有（蓝）
	EPIC,       # 2：史诗（紫）
	LEGENDARY   # 3：传说（红）。它同时是 get_tier_style() 的 _ 兜底分支，所以非法值看起来会"像传说"
}

## 五个门派的固定规则（id → 名字 / 收哪些种族 / 介绍）。门派是规则不是内容，放常量里只改一处。
## races 存 UnitStats.Race 枚举值；GameRoot、拜师面板、StatsPanel 都读这里。
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
## 门派的展示顺序（也是建邺城 NPC 的排列顺序）。
const SECT_ORDER := ["taixu", "piaomiao", "zixiao", "wanyao", "xingluo"]

## 门派技能表：每派 2 被动 + 3 主动，拜入时全部学会 1 级，之后花经验 + 金币升级（上限 100）。
## 被动字段：stat（映射 UnitStats 的字段，*_pct / rate 均为百分比口径）/ per_level / desc。
## 主动字段：targets（按等级取"≤level 的最大档"，targets_all 表示全体）、damage / fixed_damage / hits、
##   seal / silence、heal / hot、buff（buff_per_level + buff_self / buff_all）。
## ⚠ 主动技能目前只有数据与说明，战斗里还不会自动释放。
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
## 门派技能最高等级（与玩家等级上限一致）。
const SECT_SKILL_MAX_LEVEL := 100

## ── 运行时状态（跨场景存活，新档需手动清空）──
var coins: int = 1000                                  # 金币（单位：枚，整数）。默认 500 与 GameRoot.starting_coins 一致；开新档时会被 start_new_game() 重置回那个值

## 每个角色各自的等级（键 = GameRoot.character_key()，缺键 = 1 级）。经验按人发，板凳不涨。
## 唯一写入点：GameRoot.add_exp() 与 start_new_game()。
var level_by_character: Dictionary = {}
## 每个角色当前等级内已攒的经验（缺键 = 0）；升级扣 need，满级后固定 0。
var exp_by_character: Dictionary = {}

var main_player_selected: UnitStats                   # 当前主角的角色数据（GameRoot.start_game_with_defaults 写入）。只是 Resource，没有实例化成节点

## 背包内容（全队共用，ItemBase 数组）。穿在身上的不在这里；卖出 / 穿戴由 GameRoot 增删。
var equipped_weapons: Array[ItemBase]

## 每个角色各自的装备：角色键 → { ItemBase.EquipType: ItemBase }。用 resource_path 作键，重载后仍能对上。
## 唯一写入点：GameRoot.equip_item / unequip_slot；BagPanel 按当前展示角色读。
## ⚠ 角色离队时装备留在他名下，重新招募会带回来；空栏位就是没有这个 key。
var equipment_by_character: Dictionary = {}

## 每个角色拜入的门派 id（SECTS 的键，空 = 无门派）。写入点：GameRoot.join_sect()；新档 clear()。
var sect_by_character: Dictionary = {}

## 每个角色的门派技能等级：角色键 → { 技能 id: 等级 }（缺 id = 未学，拜入时 5 个各设 1）。
## 写入点：GameRoot.join_sect() / upgrade_sect_skill()；上限 SECT_SKILL_MAX_LEVEL。
var sect_skill_levels_by_character: Dictionary = {}

## 每个角色手动分配的五项属性点（Array[int]，顺序同 GameRoot.ATTR_KEYS）；自动成长按等级现算。
var attr_alloc_by_character: Dictionary = {}

## 以 chance（0~1，不是百分数）返回是否成功；>=1 必成，0 必败。
## 副作用：推进全局 RNG 状态，会影响后续随机序列（不是 bug）。
func get_chance_success(chance: float) -> bool:
	var random := randf_range(0, 1.0)
	if random < chance:
		return true
	return false

# ── 可招募队友（队伍系统）──

## 可招募队友目录：每个 UnitStats 资源都是一个可加入的角色。MapNPC.recruit_pool 留空时扫这里。
const RECRUIT_DIR := "res://resources/units/players/"

## 上次扫描的缓存（运行期资源不变，反复读盘没意义）。
var _recruit_cache: Array[UnitStats] = []


## 扫描 RECRUIT_DIR，按 resource_path 排序返回（顺序稳定，UI 不乱跳）。refresh = 忽略缓存。
## 坑：.tres/.res 都收（导出后可能变 .res）；非 UnitStats 静默跳过；要万无一失就显式填 recruit_pool。
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


## 装备根目录（equipment/<类型>/item_*.tres）。MapNPC.sell_pool 留空时扫这里，新 .tres 自动上架。
const EQUIPMENT_DIR := "res://resources/items/equipment/"

## 装备扫描缓存（理由同 _recruit_cache）。
var _equipment_cache: Array[ItemBase] = []


## 递归扫描 EQUIPMENT_DIR，按"栏位 → 价格 → 名字"排序返回。refresh = 忽略缓存。
## 排序是为了货架顺序稳定（买完不会整排挪位），且按栏位分组与背包 6 个装备栏对应。
## 只收 item_ 前缀，同目录的其他资源不会被当商品。
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


## 递归收集 dir_path（末尾要带斜杠）下的 ItemEquipment。子目录打不开时静默返回。
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


# ── 门派（SECTS 表的小工具）──

## 这个 id 是否是合法门派。
func is_sect(sect_id: String) -> bool:
	return SECTS.has(sect_id)


## 门派中文名；id 不存在时原样返回，便于日志排查。
func sect_name(sect_id: String) -> String:
	if not SECTS.has(sect_id):
		return sect_id
	return String(SECTS[sect_id]["name"])


## 门派介绍。⚠ 拜师面板已不显示它，留给门派图鉴 / 任务文本。
func sect_desc(sect_id: String) -> String:
	if not SECTS.has(sect_id):
		return ""
	return String(SECTS[sect_id]["desc"])


## 门派收哪些种族（UnitStats.Race 枚举值，按 UI 展示顺序）。
func sect_races(sect_id: String) -> Array:
	if not SECTS.has(sect_id):
		return []
	return SECTS[sect_id]["races"]


## 该门派是否收某个种族（race 是枚举值，不是中文名）。
func sect_accepts(sect_id: String, race: int) -> bool:
	return sect_races(sect_id).has(race)


## 种族限制文本，如"人族、仙族"。拜师按钮与 join_sect() 的拒绝理由共用。
func sect_races_text(sect_id: String) -> String:
	var parts: Array[String] = []
	for race_value in sect_races(sect_id):
		parts.append(UnitStats.race_display_name(int(race_value)))
	return "、".join(parts)


## ── 门派技能（SECT_SKILLS 的小工具）──

## 门派的技能表（passives / actives），没有则返回空字典。
func sect_skill_table(sect_id: String) -> Dictionary:
	if not SECT_SKILLS.has(sect_id):
		return {}
	return SECT_SKILLS[sect_id]


## 门派的被动技能数组（{id,name,stat,per_level,desc}）。
func sect_passives(sect_id: String) -> Array:
	return sect_skill_table(sect_id).get("passives", [])


## 门派的主动技能数组（{id,name,desc,...效果参数}）。
func sect_actives(sect_id: String) -> Array:
	return sect_skill_table(sect_id).get("actives", [])


## 全部技能的显示名（被动在前、主动在后）。
func sect_skill_names(sect_id: String) -> Array[String]:
	var out: Array[String] = []
	for skill in sect_passives(sect_id):
		out.append(String(skill["name"]))
	for skill in sect_actives(sect_id):
		out.append(String(skill["name"]))
	return out


## 主动技能在 level 级的目标数：取 targets 里"≤level 的最大档"；targets_all 返回 -1（显示"全体"）。
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


# ── 门派技能的 SkillData 资源（resources/skills/sect_skills/）──
# 约定：每个**主动**技能一份 .tres，路径 = resources/skills/sect_skills/<门派>/skill_<技能 id>.tres；
# 被动技能不需要资源（只是属性加成，见 GameRoot._apply_sect_passives）。
# 等级相关的东西（目标数阈值、每级加成、当前等级）仍在 SECT_SKILLS 表 + GameRoot.sect_skill_level()，
# 战斗开始时会把这些"烤"进技能的副本（见 GameRoot._make_player_team）。

var _sect_skill_cache: Dictionary = {}


## 技能 id 属于哪个门派（扫 SECT_SKILLS；找不到返回 ""）。
func sect_of_skill(skill_id: String) -> String:
	for sect_id in SECT_ORDER:
		for skill in sect_actives(sect_id):
			if String(skill["id"]) == skill_id:
				return sect_id
	return ""


## 门派技能的 .tres 路径（约定见上；技能不存在时返回 ""）。
func sect_skill_scene_path(skill_id: String) -> String:
	var sect_id := sect_of_skill(skill_id)
	if sect_id.is_empty():
		return ""
	return "res://resources/skills/sect_skills/%s/skill_%s.tres" % [sect_id, skill_id]


## 加载门派技能的 SkillData（带缓存；找不到返回 null，调用方自行兜底）。
func sect_skill_resource(skill_id: String) -> SkillData:
	if _sect_skill_cache.has(skill_id):
		return _sect_skill_cache[skill_id] as SkillData
	var path := sect_skill_scene_path(skill_id)
	if path.is_empty() or not ResourceLoader.exists(path):
		_sect_skill_cache[skill_id] = null
		return null
	var skill := load(path) as SkillData
	_sect_skill_cache[skill_id] = skill
	return skill


## 清空门派技能资源缓存（换了 .tres 想立刻生效时调；正常游戏流程用不到）。
func clear_sect_skill_cache() -> void:
	_sect_skill_cache.clear()


# ── UI 文本工具 ──

## 属性数值转 UI 文本：**一律显示整数**（四舍五入），内部计算仍然用 float。
## 例：43.375 → "43"，1.5 → "2"，0.4 → "1"（非 0 的值不会显示成 0，否则"暴击 +0%"看着像没生效）。
## ⚠ 故意不写 static：调用点都走 autoload 实例，static 被实例调用会刷 static_called_on_instance。
func format_stat(value) -> String:
	var f := float(value)
	var n := int(roundf(f))
	if n == 0 and not is_zero_approx(f):
		n = 1 if f > 0.0 else -1
	return str(n)


# ── UI 键盘焦点工具（主菜单 / 世界地图共用）──
## ↑↓/Enter/空格 交给 Godot 的 ui_*；W/S/E 是工程自定义动作，由各屏幕 _unhandled_input 调这里补上。
## E 不能靠 Input 模拟 ui_accept，这里直接 emit 按钮的 pressed（效果与点一下相同）。
## ⚠ 这几个函数故意不写 static，理由同 format_stat。

## 控件现在能否被键盘选中：可见、未禁用、focus_mode != NONE（null 返回 false）。
func can_focus(control: Control) -> bool:
	if control == null or not control.visible:
		return false
	if control is Button and (control as Button).disabled:
		return false
	return control.focus_mode != Control.FOCUS_NONE


## 递归收集容器里所有可按的 Button（树的顺序 = 视觉顺序）。只认 Button，避免容器自己成为焦点停靠点。
func collect_focusable(root: Node) -> Array[Control]:
	var out: Array[Control] = []
	for child in root.get_children():
		if child is Button and can_focus(child as Control):
			out.append(child as Control)
		out.append_array(collect_focusable(child))
	return out


## 在焦点环里前后循环（step ±1）。当前焦点不在环里时从第一个开始，保证 W/S 总能接手。
func step_focus(context: Node, ring: Array[Control], step: int) -> void:
	if ring.is_empty():
		return
	var current := context.get_viewport().gui_get_focus_owner()
	var index := ring.find(current)
	index = 0 if index < 0 else wrapi(index + step, 0, ring.size())
	ring[index].grab_focus()


## 按下当前焦点按钮（给 E 键用）。返回是否真的按到了（没焦点或置灰 = false）。
func activate_focused(context: Node) -> bool:
	var current := context.get_viewport().gui_get_focus_owner()
	if current is Button and not (current as Button).disabled:
		(current as Button).pressed.emit()
		return true
	return false


## 是否是交互事件（E 或 Enter）：优先 InputMap 的 interact 动作，没配则回落到硬编码按键。
func is_interact_event(event: InputEvent) -> bool:
	if InputMap.has_action(&"interact") and event.is_action_pressed(&"interact"):
		return true
	return event is InputEventKey and event.pressed and not event.echo \
		and (event.keycode == KEY_E or event.keycode == KEY_ENTER)


## 方格布局用 W A S D 移动焦点（背包格子、商人货架共用）。返回是否消费了事件。
## 用 find_valid_focus_neighbor 按几何位置找邻居，而不是环里 ±columns：空格 / 买不起的货不进环，
## 线性偏移会错位；几何查找还会自动跳过不可聚焦控件。
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
	# 变量别叫 owner：那是 Node.owner 的同名属性，编辑器会报 shadowing 警告
	var focus_owner := viewport.gui_get_focus_owner()
	# 焦点还不在方格上时（例如刚打开面板）先不动，交给 _set_focus_ring() 的初始聚焦
	if focus_owner != null:
		var neighbor := focus_owner.find_valid_focus_neighbor(side)
		if neighbor != null:
			neighbor.grab_focus()
	viewport.set_input_as_handled()
	return true


## 稀有度 → 卡片样式（StyleBoxFlat），给 add_theme_stylebox_override("panel", ...) 用。
## ⚠ 返回的是共享 const 本体，不是副本：只能读，改属性会污染全局所有同稀有度卡片。
## 兜底：没匹配上的值（含非法整数）返回传说样式。
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
