# ═══════════════════════════════════════════════════════════════════════════
# GameRoot —— 唯一主场景 main.tscn 的根脚本：屏幕调度 + 全局流程/状态中枢
# ═══════════════════════════════════════════════════════════════════════════
# 自身不画画面：屏幕挂 WorldRoot(Node2D) / UIRoot(CanvasLayer)，过渡黑幕在 TransitionLayer。
# 屏幕只 emit 请求信号，由本文件决定下一屏；流程状态（地图/队伍/通关/位置）也在这里。
# ⚠ 大量 await（不 await 则过场在后台继续）；换屏不换 SceneTree 场景，Global 跨屏存活。

extends Node
class_name GameRoot

## 游戏总入口。流程：主菜单 → 世界地图（走动/传送/战斗）→ 回合制战斗 → 结算回地图。
## 地图顺序见 main.tscn 的 maps（MapData.next_id 串联），不在本文件硬编码。

# ── 对外信号 ──
## 地图变了（进入第一张图 / travel_to 换图时 emit）。⚠ 目前无人 connect，预留扩展点。
signal map_changed(map_id: String)

## 队伍成员变化（招募/换人时 emit）。⚠ 无人 connect；地图面板靠 GameRoot 主动调 notify_party_changed() 刷新。
signal party_changed

# ── 屏幕场景常量（全部 preload，换屏只 instantiate）──
# ⚠ preload 是编译期绑定：路径改名/删除会直接报错，改文件名时同步改这里。
## 主菜单场景（TitleScreen）。
const TITLE_SCENE := preload("res://scenes/main/title_screen.tscn")
## 通用世界地图场景。某张地图若在 MapData.scene 里配了专用场景，则改用那个（见 show_map）。
const WORLD_MAP_SCENE := preload("res://scenes/world/world_map.tscn")
## 回合制战斗场景（Battle）。
const BATTLE_SCENE := preload("res://scenes/battle/battle.tscn")
## 默认队长；⚠ 用敌人资源当队长也安全：战斗走 start_battle(我方, 敌方) 显式传参，不读 UnitStats.type。
## 换人改这一行，或在 main.tscn 检查器填 default_leader 覆盖。
const DEFAULT_LEADER := preload("res://resources/units/players/行修.tres")

# ───────────── 调试专用：开局阵容 ─────────────
## true = 开局直接把 6 个角色全拉进团队、按表配好门派（燕如意只入团队不上阵）。
## 调试完改成 false 就恢复"只有队长一个人"的正常开局。
## ⚠ 正式版请连同 DEBUG_TEAM / DEBUG_BENCHED / _apply_debug_loadout() 一起删掉。
const DEBUG_LOADOUT := true

## 调试阵容：[显示名, 资源路径, 门派 id]。数组顺序 = 上阵顺序（第 1 个是队长）。
const DEBUG_TEAM := [
	["行修", "res://resources/units/players/行修.tres", "piaomiao"],
	["厉狂澜", "res://resources/units/players/厉狂澜.tres", "xingluo"],
	["夜魑", "res://resources/units/players/夜魑.tres", "wanyao"],
	["陆孤鸣", "res://resources/units/players/陆孤鸣.tres", "taixu"],
	["霓裳", "res://resources/units/players/霓裳.tres", "zixiao"],
	["燕如意", "res://resources/units/players/燕如意.tres", "taixu"],
]
## 只入团队、不上阵的那个人（上阵位只有 MAX_DEPLOYED 个，正好空一位出来）。
const DEBUG_BENCHED := "燕如意"


# ── 配置（main.tscn 检查器里填；改这些等于改关卡结构与难度曲线）──
## 地图顺序表：数组顺序 = 关卡顺序，map_difficulty() 靠下标算，调序会连带改难度/奖励。
@export var maps: Array[MapData] = []
@export var start_map_id := ""                 # 留空 = maps[0].id
@export var enemy_pool: Array[UnitStats] = []  # 某张图没配 enemy_pool 时用这个
@export var enemy_scale_per_map := 0.15        # 每前进一张图，敌人血量/伤害 +15%
@export var coin_reward_per_map := 40          # 通关奖励 = coin_reward_per_map * 地图序号
## 新档初始金币，默认 500（与 Global.coins 默认值一致）。
@export var starting_coins := 500

# ── 等级与经验（每个角色各自，满级 100）──
## 满级；到顶后经验不再增长（打赢只给金币）。
const MAX_LEVEL := 100
## 自动升级上限：1→9 级自动升；10 级起改为手动（经验攒着，面板点「升级」）。
## 手动的原因：门派技能要消耗角色自己的经验，自动升级会把经验吃光。
const AUTO_LEVEL_LIMIT := 10
## 经验累计上限（100 亿）。
const EXP_CAP := 10_000_000_000
## 经验曲线：need(L) = round(EXP_BASE + EXP_LINEAR×L + EXP_QUAD×L²)，L=1..99；三系数即全部旋钮。
## ⚠ 改完跑一次 _verify_level 曲线检查（单调递增与总量）。
const EXP_BASE := 60.0
const EXP_LINEAR := 20.0
const EXP_QUAD := 0.42
## 已废弃：升级改为发属性点（ATTR_*），代码里无人读取，仅作旧档对照。
const LEVEL_GROWTH_PER_LEVEL := 0.0
## 每场胜利经验 = exp_reward_per_map × 难度 + exp_per_enemy × 敌人数（默认 120/20）。
@export var exp_reward_per_map := 120
@export var exp_per_enemy := 20

# ── 基础属性（五项；升级自动 +1，另给自由点）──
## 键顺序 = UI 顺序 = 系数表顺序：con/mag/str/end/agi（体质/魔力/力量/耐力/敏捷）。
const ATTR_KEYS := ["con", "mag", "str", "end", "agi"]
## 五项基础属性的中文名（和 ATTR_KEYS 一一对应）。
const ATTR_NAMES := ["体质", "魔力", "力量", "耐力", "敏捷"]
## 每升 1 级：五项基础属性**各 +本值**（自动，不受操作影响）。
const ATTR_PER_LEVEL := 1
## 1 级时的默认基础属性点数（仅作为 UnitStats 里五个 attr_* 字段的默认值参考；
## 实际数值以每个单位 .tres 上的 attr_con/attr_mag/attr_str/attr_end/attr_agi 为准）。
const ATTR_BASE := 11
## 每升 1 级：额外获得这么多点**自由属性点**，玩家自己加到任意一项上。
const ATTR_FREE_PER_LEVEL := 5
## 门派技能的伤害倍率规则（战斗前按目标数烤进技能副本）。
## 单体 = 1.8；群体每个目标 = 1.8 × (1 − 0.12×(目标数−1))，与梦幻西游手游实测的衰减一致。
const SKILL_SINGLE_POWER := 1.8
const SKILL_AOE_DECAY := 0.12
## 群体衰减系数：n 个目标时每个目标的倍率（最低 0.3，防爆）。
static func SKILL_AOE_DECAY_STEP(n: int) -> float:
	return maxf(0.3, 1.0 - SKILL_AOE_DECAY * float(maxi(1, n) - 1))

## 种族 × 基础属性 → 派生属性的系数表（**所有数值的唯一来源**）。
## 用法：派生值 = Σ(每项基础属性点数 × 系数)，不再叠加 .tres 里的旧基础值。
## 数值严格按"属性点类型"表（法系两项已直接拆到法伤/法防，不再经过灵力）：
##   体质 → 气血 / 法伤 / 法防 / 速度        魔力 → 魔法 / 法伤 / 法防
##   力量 → 伤害 / 法伤 / 法防              耐力 → 防御 / 法伤 / 法防 / 速度
##   敏捷 → 速度 / 躲避
## 想调平衡只改这张表 —— 面板与战斗都读 derived_stats()。
const ATTR_TABLE := {
	UnitStats.Race.HUMAN: {
		"con": {"hp": 5.0, "spell_damage": 0.15, "spell_defense": 0.18, "speed": 0.1},
		"mag": {"mana": 3.0, "spell_damage": 0.35, "spell_defense": 0.42},
		"str": {"damage": 0.75, "spell_damage": 0.2, "spell_defense": 0.24},
		"end": {"defense": 1.5, "spell_damage": 0.1, "spell_defense": 0.12, "speed": 0.1},
		"agi": {"speed": 0.7, "dodge": 1.0},
	},
	UnitStats.Race.IMMORTAL: {
		"con": {"hp": 4.5, "spell_damage": 0.15, "spell_defense": 0.18, "speed": 0.1},
		"mag": {"mana": 3.5, "spell_damage": 0.35, "spell_defense": 0.42},
		"str": {"damage": 0.65, "spell_damage": 0.2, "spell_defense": 0.24},
		"end": {"defense": 1.6, "spell_damage": 0.1, "spell_defense": 0.12, "speed": 0.1},
		"agi": {"speed": 0.7, "dodge": 1.0},
	},
	UnitStats.Race.DEMON: {
		"con": {"hp": 6.0, "spell_damage": 0.15, "spell_defense": 0.18, "speed": 0.1},
		"mag": {"mana": 2.5, "spell_damage": 0.35, "spell_defense": 0.42},
		"str": {"damage": 0.85, "spell_damage": 0.2, "spell_defense": 0.24},
		"end": {"defense": 1.4, "spell_damage": 0.1, "spell_defense": 0.12, "speed": 0.1},
		"agi": {"speed": 0.7, "dodge": 1.0},
	},
}
## 表外补充：这几项在原表里没写，暂按"耐力/敏捷"继续供给，想删就把对应系数去掉。
const EXTRA_TABLE := {
	"block_value": {"end": 0.15},
	"crit_resist": {"end": 0.1},
	"crit_damage_resist": {"end": 0.15},
	"crit_rate": {"agi": 0.12},
	"seal_resist": {"agi": 0.08},
	"healing": {"mag": 0.35},
	"seal_hit": {"mag": 0.15},
	"crit_damage_bonus": {"str": 0.3},
}
## 开局队长；留空用 DEFAULT_LEADER。想临时试别的角色/敌人，填这里最省事。
@export var default_leader: UnitStats

# ── 场景容器引用（% = main.tscn 的 unique_name_in_owner 节点）──
## 世界类屏幕容器（受世界坐标与 y_sort 影响）。
@onready var world_root: Node2D = %WorldRoot
## UI 类屏幕容器（CanvasLayer）。TitleScreen 挂这里（不随相机移动）。
@onready var ui_root: CanvasLayer = %UIRoot
## 最上层黑幕；只调 modulate.a 做淡入淡出（1=全黑，0=透明）。
@onready var fade: ColorRect = %Fade

# ── 局内状态（活到下一次 start_new_game；换屏不会重置）──
## 当前地图 id；初值 = _first_map_id()（maps 为空时 ""）。
var current_map_id := ""
## 上阵上限 = Battle 站位数量（前三后二）；超出会被 _spawn_team() 丢弃，面板据此置灰。
## ⚠ 不是团队上限：大名单可以很多人，能上场的只有 MAX_DEPLOYED。
const MAX_DEPLOYED := 5

## 团队人数上限；0 = 不限（真正的限制在上阵 5 人）。
const MAX_TEAM_SIZE := 0

## 敌方人数上限 = Battle 站位数量；_make_enemy_team() 以上阵人数 ±1 生成后钳进 [1, 本值]。
const MAX_ENEMY_COUNT := 5

## 团队（大名单）：第 0 位是队长。在团队 ≠ 出战（出战看 deployed）。
## ⚠ 引用语义交给 WorldMap：只能 clear()/append()/remove_at() 就地改，不能整个重新赋值。
## ⚠ 重新赋值会让 WorldMap 手里的旧数组变孤儿，界面不再跟着变。
var party: Array[UnitStats] = []

## 上阵名单（≤ MAX_DEPLOYED）：必须是 party 子集；战斗前逐个 duplicate()，掉血不污染 .tres。
## ⚠ 同 party 是引用语义交给 WorldMap，也别整个重新赋值。
var deployed: Array[UnitStats] = []
## 已通关地图集合：map_id -> true。用于地图名后缀"（已通关）"与将来"必须先打赢才能走"。
var cleared_maps: Dictionary = {}
## 是否在战斗中（enter_battle 置 true / _on_battle_ended 置 false）。⚠ 目前无人读，预留。
var in_battle := false

## 上一次战斗的结算文案（胜/负 + 奖励）。写：_on_battle_ended()；读：传给地图显示 + 主菜单副标题。
var _last_result := ""
## 本场敌人数；结算时敌人队伍已释放，经验要按数量算，故进战斗时先存。
var _last_enemy_count := 0
## 每图离开时的归一化位置（map_id → Vector2）；show_map(restore_position=true) 时赋给 spawn_override。
var _map_positions: Dictionary = {}


## 生命周期：黑幕拉满 → 设初始地图 → await show_title()（之后流程由信号驱动）。
## maps 为空只 push_warning 不中断，好让玩家还能看到主菜单退出。
func _ready() -> void:
	fade.modulate.a = 1.0
	if maps.is_empty():
		push_warning("GameRoot: maps 是空的 —— 在 main.tscn 的 Maps 数组里填地图资源")
	else:
		current_map_id = _first_map_id()
	await show_title()


# ── 地图数据 ──

## 起始地图：start_map_id（须能在 maps 里查到）→ maps[0].id → ""。
func _first_map_id() -> String:
	if not start_map_id.is_empty() and get_map(start_map_id) != null:
		return start_map_id
	if maps.is_empty():
		return ""
	return maps[0].id


## 按 id 查地图；找不到返回 null。`map != null` 容忍 Maps 数组里的空槽。
func get_map(map_id: String) -> MapData:
	for map in maps:
		if map != null and map.id == map_id:
			return map
	return null


## 地图下标（0 起）；⚠ 找不到返回 0（当第一张图，避免难度/奖励算成负数）。
func map_index(map_id: String) -> int:
	for i in maps.size():
		if maps[i] != null and maps[i].id == map_id:
			return i
	return 0


## 当前难度档 = 下标 + 1。用途：金币奖励；敌人缩放只乘血量/伤害，数量另算。
func map_difficulty() -> int:
	return map_index(current_map_id) + 1


# ── 等级与经验（数值在文件顶部，成长在基础属性段，这里只放算法）──

## 升到下一级所需经验：round(EXP_BASE + EXP_LINEAR×L + EXP_QUAD×L²)；满级/越界返回 0。
static func exp_to_next(level: int) -> int:
	if level < 1 or level >= MAX_LEVEL:
		return 0
	return int(roundf(EXP_BASE + EXP_LINEAR * level + EXP_QUAD * level * level))


## 本场胜利经验 = exp_reward_per_map × 难度 + exp_per_enemy × 敌人数（难度保证后期更值，数量补以少打多）。
func exp_reward(enemy_count: int) -> int:
	return exp_reward_per_map * map_difficulty() + exp_per_enemy * maxi(0, enemy_count)


# ── 基础属性与派生属性 ──
# 基础属性 = (等级-1)×ATTR_PER_LEVEL 自动成长 + 自由点；派生 = .tres 基础值 + Σ(点数×种族系数)。

## 角色等级（无记录 = 1 级，钳在 1..MAX_LEVEL）。
static func level_of(character: UnitStats) -> int:
	if character == null:
		return 1
	return clampi(int(Global.level_by_character.get(character_key(character), 1)), 1, MAX_LEVEL)


## 角色当前等级内已攒经验（无记录 = 0）。
static func exp_of(character: UnitStats) -> int:
	if character == null:
		return 0
	return maxi(0, int(Global.exp_by_character.get(character_key(character), 0)))


## 五项基础属性总点数（1 级基础 + 自动成长 + 自由分配），顺序同 ATTR_KEYS。
## 自动成长按 (等级-1) 现算而不落库，永远与等级一致。
## 基础值来自 UnitStats 的五个 attr_* 字段（默认各 11），所以每个单位都能在 .tres 里单独配。
static func attribute_points(character: UnitStats) -> Array[int]:
	var out: Array[int] = [0, 0, 0, 0, 0]
	if character == null:
		return out
	var base := [
		character.attr_con, character.attr_mag, character.attr_str,
		character.attr_end, character.attr_agi,
	]
	var growth := maxi(0, level_of(character) - 1) * ATTR_PER_LEVEL
	var alloc := _attr_alloc(character)
	for i in ATTR_KEYS.size():
		out[i] = maxi(0, int(base[i])) + growth + int(alloc[i])
	return out


## 剩余自由属性点 = (等级-1)×ATTR_FREE_PER_LEVEL - Σ已分配（不小于 0）。
static func free_attribute_points(character: UnitStats) -> int:
	if character == null:
		return 0
	var total := maxi(0, level_of(character) - 1) * ATTR_FREE_PER_LEVEL
	var spent := 0
	for value in _attr_alloc(character):
		spent += int(value)
	return maxi(0, total - spent)


## 已分配自由点的副本（无记录全 0）；返回副本避免调用方绕过 allocate_attr 写脏。
static func _attr_alloc(character: UnitStats) -> Array[int]:
	var out: Array[int] = [0, 0, 0, 0, 0]
	if character == null:
		return out
	var raw = Global.attr_alloc_by_character.get(character_key(character))
	if raw == null:
		return out
	for i in mini(ATTR_KEYS.size(), (raw as Array).size()):
		out[i] = int(raw[i])
	return out


## 给某项加自由点；空串=成功，否则是可显示的原因。写 Global.attr_alloc_by_character。
static func allocate_attr(character: UnitStats, index: int, amount := 1) -> String:
	if character == null:
		return "没有选中角色。"
	if index < 0 or index >= ATTR_KEYS.size():
		return "没有这项基础属性。"
	if amount <= 0:
		return "加点数量必须大于 0。"
	if free_attribute_points(character) < amount:
		return "没有足够的自由属性点（还剩 %d 点）。" % free_attribute_points(character)
	var key := character_key(character)
	var alloc := _attr_alloc(character)
	alloc[index] += amount
	Global.attr_alloc_by_character[key] = alloc
	return ""


## 批量提交一组加减（面板「确认加点」走这里）；空串=成功，否则为拒绝原因。
## 校验：各项最终分配 ≥ 0，差值之和 ≤ 剩余自由点；支持先减后加且中途不出现负数/超额。
## 写 Global.attr_alloc_by_character（与 allocate_attr 共用同一存储）。
static func apply_attr_deltas(character: UnitStats, deltas: Array) -> String:
	if character == null:
		return "没有选中角色。"
	if deltas.size() != ATTR_KEYS.size():
		return "属性点数不对。"
	var alloc := _attr_alloc(character)
	var added := 0
	for i in deltas.size():
		var delta := int(deltas[i])
		if alloc[i] + delta < 0:
			return "%s 不能减到 0 以下。" % ATTR_NAMES[i]
		added += delta
	if added > free_attribute_points(character):
		return "没有足够的自由属性点（还剩 %d 点）。" % free_attribute_points(character)
	if added == 0:
		return ""
	for i in deltas.size():
		alloc[i] += int(deltas[i])
	Global.attr_alloc_by_character[character_key(character)] = alloc
	return ""


## 五大基础属性 → 派生属性（面板/战斗的唯一口径）。
## 规则：**完全由基础属性算出来**（Σ 点数 × 种族系数），不再读 .tres 里的旧基础值；
##   等级的影响通过"每级五项各 +1"体现，门派被动在 _apply_sect_passives 里叠加。
## ⚠ 纯函数：只读 Global 与 character，不写状态。
static func derived_stats(character: UnitStats) -> Dictionary:
	var out := {
		"hp": 0.0, "mana": 0.0, "damage": 0.0, "defense": 0.0,
		"speed": 0.0, "dodge": 0.0,
		"spell_damage": 0.0, "spell_defense": 0.0,
		"crit_rate": 0.0, "crit_damage_bonus": 0.0, "seal_hit": 0.0, "healing": 0.0,
		"crit_resist": 0.0, "crit_damage_resist": 0.0, "seal_resist": 0.0,
		"block_value": 0.0,
	}
	if character == null:
		return out
	var race: int = character.race
	var table: Dictionary = ATTR_TABLE.get(race, ATTR_TABLE[UnitStats.Race.HUMAN])
	var points := attribute_points(character)
	# ① 主表：体质/魔力/力量/耐力/敏捷 → 气血/魔法/伤害/防御/速度/躲避/法伤/法防
	for i in ATTR_KEYS.size():
		var coef: Dictionary = table.get(ATTR_KEYS[i], {})
		for key in coef:
			out[key] = float(out.get(key, 0.0)) + float(coef[key]) * points[i]
	# ② 表外补充项（暴击、治疗、格挡值等，原表未列）
	for key in EXTRA_TABLE:
		var by_attr: Dictionary = EXTRA_TABLE[key]
		for attr in by_attr:
			var idx := ATTR_KEYS.find(attr)
			if idx >= 0:
				out[key] = float(out.get(key, 0.0)) + float(by_attr[attr]) * points[idx]
	# ③ 装备加成：直接加到派生值上。武器攻击 1:1 同时加「伤害」和「法伤」（这个 1:1 只在这里做，
	#    equipment_bonus() 只负责累加，换个地方再乘一次就会翻倍）。
	var eq := equipment_bonus(character)
	out["hp"] = float(out["hp"]) + float(eq["health"])
	out["damage"] = float(out["damage"]) + float(eq["attack"])
	out["spell_damage"] = float(out["spell_damage"]) + float(eq["attack"])
	out["defense"] = float(out["defense"]) + float(eq["defense"])
	out["speed"] = float(out["speed"]) + float(eq["speed"])
	out["crit_rate"] = float(out["crit_rate"]) + float(eq["crit_chance"])
	# 气血至少 1，避免"属性全 0"时开局被判死
	out["hp"] = maxf(1.0, float(out["hp"]))
	return out


## 汇总某角色身上所有装备的加成（纯累加，不做任何换算）。
## 返回：{attack, defense, health, speed, crit_chance}，全 float；没穿装备时全 0。
## ⚠ 「武器攻击 1:1 同时加伤害与法伤」的口径写在 derived_stats() 里，本函数只累加原值，别在这里再乘。
## 只读 Global.equipment_by_character，纯函数、无副作用。
static func equipment_bonus(character: UnitStats) -> Dictionary:
	var out := {"attack": 0.0, "defense": 0.0, "health": 0.0, "speed": 0.0, "crit_chance": 0.0}
	if character == null:
		return out
	for item in equipment_of(character).values():
		var eq := item as ItemEquipment
		if eq == null:
			continue
		out["attack"] += float(eq.attack)
		out["defense"] += float(eq.defense)
		out["health"] += float(eq.health)
		out["speed"] += float(eq.speed)
		out["crit_chance"] += float(eq.crit_chance)
	return out


## 给某个角色加经验（唯一经验入口）；返回本次自动升的级数。
## 1→9 级自动连升、溢出留给下一级；10 级起只攒经验（AUTO_LEVEL_LIMIT）。
## **满级后经验照样攒**（最多 EXP_CAP = 100 亿）—— 升门派技能还要花它，所以不清零。
static func add_exp(character: UnitStats, amount: int) -> int:
	if character == null or amount <= 0:
		return 0
	var key := character_key(character)
	var level := level_of(character)
	var exp_total := mini(EXP_CAP, exp_of(character) + amount)
	var gained := 0
	while level < mini(AUTO_LEVEL_LIMIT, MAX_LEVEL):
		var need := exp_to_next(level)
		if exp_total < need:
			break
		exp_total -= need
		level += 1
		gained += 1
	Global.level_by_character[key] = level
	Global.exp_by_character[key] = exp_total
	return gained


## 手动升一级：扣掉本级所需经验、等级 +1（10 级起唯一升级方式）。
## 返回 {ok, why, level}；写 Global.exp/level_by_character（只动该角色）。
static func upgrade_level(character: UnitStats) -> Dictionary:
	var why := upgrade_level_why(character)
	var level := level_of(character)
	if not why.is_empty():
		return {"ok": false, "why": why, "level": level}
	var key := character_key(character)
	Global.exp_by_character[key] = exp_of(character) - exp_to_next(level)
	Global.level_by_character[key] = level + 1
	return {"ok": true, "why": "", "level": level + 1}


## 现在能不能手动升一级？返回空串 = 能，否则是可读原因（面板上直接显示/置灰按钮）。
static func upgrade_level_why(character: UnitStats) -> String:
	if character == null:
		return "没有角色"
	var level := level_of(character)
	if level >= MAX_LEVEL:
		return "已经满级"
	if exp_of(character) < exp_to_next(level):
		return "经验不足（需要 %d）" % exp_to_next(level)
	return ""


# ── 屏幕切换（带淡入淡出）──

## 清空两个容器的所有屏幕。
## ⚠ 先 remove_child 再 queue_free：否则到帧末前仍占布局/收输入；屏幕 owner 为 null，必须 child.queue_free()。
func _clear_screens() -> void:
	for parent in [world_root, ui_root]:
		for child in parent.get_children():
			parent.remove_child(child)
			child.queue_free()


## 换屏：fade_out → _clear_screens → add_child → fade_in（协程，全程演完才返回）。
## ⚠ 必须先等全黑再清屏，否则会闪跳；parent=null 约定挂 ui_root（默认参数不能用成员变量）。
func _swap(screen: Node, parent: Node = null) -> void:
	var target: Node = parent if parent != null else ui_root
	await fade_out()
	_clear_screens()
	target.add_child(screen)
	await fade_in()


## 淡出到全黑（协程，await tween.finished）。
## 先把 mouse_filter=STOP，防止黑屏途中点到即将清掉的旧界面。
func fade_out(duration := 0.3) -> void:
	fade.mouse_filter = Control.MOUSE_FILTER_STOP
	var tween := create_tween()
	tween.tween_property(fade, "modulate:a", 1.0, duration)
	await tween.finished


## 淡入到透明（协程）；⚠ mouse_filter=IGNORE 必须在 await 之后才设，等真的透明了再放行输入。
func fade_in(duration := 0.3) -> void:
	var tween := create_tween()
	tween.tween_property(fade, "modulate:a", 0.0, duration)
	await tween.finished
	fade.mouse_filter = Control.MOUSE_FILTER_IGNORE


# ── 流程各站 ──

## 显示主菜单；last_result 必须在 add_child 前写入（TitleScreen._ready 会读）。
## connect 新游戏/退出信号后 await _swap（默认挂 ui_root）。
func show_title() -> void:
	var screen := TITLE_SCENE.instantiate() as TitleScreen
	screen.last_result = _last_result
	screen.new_game_requested.connect(start_new_game)
	screen.quit_requested.connect(func() -> void: get_tree().quit())
	await _swap(screen)


## 新游戏：重置主要局内状态后用默认队长开局。⚠ Global 跨屏存活，新档必须逐项手动清。
## 清 party/deployed/cleared_maps/_map_positions/_last_result、current_map_id、Global.coins=starting_coins、
## 等级/经验/装备/门派/属性点/main_player_selected；最后 start_game_with_defaults()。
func start_new_game() -> void:
	party.clear()
	deployed.clear()
	cleared_maps.clear()
	_map_positions.clear()
	_last_result = ""
	current_map_id = _first_map_id()
	Global.coins = starting_coins
	Global.level_by_character.clear()
	Global.exp_by_character.clear()
	Global.equipped_weapons.clear()
	Global.equipment_by_character.clear()
	Global.sect_by_character.clear()
	Global.sect_skill_levels_by_character.clear()
	Global.attr_alloc_by_character.clear()
	Global.main_player_selected = null
	start_game_with_defaults()


## 用 default_leader（留空回落 DEFAULT_LEADER）直接开局：写 Global.main_player_selected 后交 _begin_new_run()。
func start_game_with_defaults() -> void:
	var leader := default_leader if default_leader != null else DEFAULT_LEADER
	if leader == null:
		push_warning("GameRoot: 没有配置默认队长（default_leader / DEFAULT_LEADER），无法直接开局")
		return
	Global.main_player_selected = leader
	_begin_new_run()


## 组队并进入第一张图（start_game_with_defaults 是唯一入口；选人界面已移除）。
## party/deployed 都只放队长（引用语义，用 clear()+append()，不重新赋值）；并清空装备/门派/属性点/等级经验。
## 无队长时警告 return；emit map_changed；调 show_map()（未 await）。
func _begin_new_run() -> void:
	if Global.main_player_selected == null:
		push_warning("GameRoot: 还没选角色")
		return
	# 用 clear()+append() 而非重新赋值：数组按引用交给 WorldMap（见 party 字段）。
	party.clear()
	party.append(Global.main_player_selected)
	# 队长默认上阵，否则一个人都进不了战斗。
	deployed.clear()
	deployed.append(Global.main_player_selected)
	Global.equipped_weapons.clear()
	Global.equipment_by_character.clear()
	Global.sect_by_character.clear()
	Global.sect_skill_levels_by_character.clear()
	Global.attr_alloc_by_character.clear()
	# 等级/经验也是局内进度，重开从 1 级练。
	Global.level_by_character.clear()
	Global.exp_by_character.clear()
	# 调试阵容：把 team / deployed / 门派全部铺好（见文件顶部 DEBUG_LOADOUT）。
	if DEBUG_LOADOUT:
		_apply_debug_loadout()
	map_changed.emit(current_map_id)
	show_map()


## 调试专用：按 DEBUG_TEAM 铺好团队、上阵名单与门派。
## 门派走 join_sect()（和正常拜师同一条路，种族限制照常校验、技能等级自动填 1 级），
## 失败只 push_warning 不中断 —— 调试时阵容照常能进游戏。
## 上阵人数按 MAX_DEPLOYED 截断；DEBUG_BENCHED 那个人只进 party 不进 deployed。
func _apply_debug_loadout() -> void:
	party.clear()
	deployed.clear()
	for row in DEBUG_TEAM:
		var stats := load(String(row[1])) as UnitStats
		if stats == null:
			push_warning("调试阵容：加载失败 %s" % row[1])
			continue
		party.append(stats)
		if String(row[0]) != DEBUG_BENCHED and deployed.size() < MAX_DEPLOYED:
			deployed.append(stats)
		var why := join_sect(stats, String(row[2]))
		if not why.is_empty():
			push_warning("调试阵容：%s 拜入 %s 失败 —— %s" % [row[0], row[2], why])
	# 队长 = 上阵第一个人（世界地图上的主控角色）
	if not deployed.is_empty():
		Global.main_player_selected = deployed[0]


## 显示世界地图（换图/战斗归来/开局都走这里）：实例化场景、注入状态、连信号，再 await _swap(world, world_root)。
## spawn_override/deployed/setup 都必须在 add_child 之前（_ready 会立刻读）；信号也先连，避免漏事件。
## 地图找不到时警告并回主菜单；专用场景根节点必须挂 WorldMap 脚本，否则 instantiate 后为 null。
func show_map(result_text := "", from_map_id := "", restore_position := false) -> void:
	var map := get_map(current_map_id)
	if map == null:
		push_warning("GameRoot: 找不到地图 %s" % current_map_id)
		await show_title()
		return

	# 这张图配了专用场景就用它（继承自 world_map.tscn），否则用通用的
	var packed: PackedScene = map.scene if map.scene != null else WORLD_MAP_SCENE
	var world := packed.instantiate() as WorldMap
	if restore_position and _map_positions.has(map.id):
		world.spawn_override = _map_positions[map.id]     # 打完战斗回到原地
	world.deployed = deployed      # 上阵名单（引用语义；队伍管理面板要按它显示"上阵/下阵"）
	world.setup(map, party, result_text, cleared_maps.has(map.id), _map_names(), from_map_id)
	world.battle_requested.connect(enter_battle)
	world.travel_requested.connect(travel_to)
	world.back_to_title_requested.connect(show_title)
	world.recruit_requested.connect(_on_recruit_requested)
	world.party_deploy_requested.connect(_on_party_deploy_requested)
	world.party_undeploy_requested.connect(_on_party_undeploy_requested)
	world.item_buy_requested.connect(_on_item_buy_requested)
	world.item_sell_requested.connect(_on_item_sell_requested)
	# 装备栏：点背包里的装备 = 穿；点已穿的栏位 = 脱（都在 GameRoot 改数据，见 equip_item）
	world.equip_requested.connect(_on_equip_requested)
	world.unequip_requested.connect(_on_unequip_requested)
	# 门派：拜师面板里点某个队员 = 让他拜入这个 NPC 的门派（种族/已有门派由 can_join_sect 判）
	world.sect_join_requested.connect(_on_join_sect_requested)
	world.party_remove_requested.connect(_on_party_remove_requested)
	world.party_lead_requested.connect(_on_party_lead_requested)
	await _swap(world, world_root)


## 传送到另一张图：⚠ 先 _remember_position()（在改 current_map_id 之前），再改 id、emit map_changed、show_map(from_id)。
## show_map 未 await：执行到第一个 await 就返回，过场在后台继续，之后不能假设已换好图。
func travel_to(next_id: String) -> void:
	var next := get_map(next_id)
	if next == null:
		push_warning("GameRoot: 没有这张地图 -> %s" % next_id)
		return
	# TODO: 想"必须先打赢才能走"就在这里判断 cleared_maps.has(current_map_id)
	_remember_position()
	var from_id := current_map_id
	current_map_id = next.id
	map_changed.emit(current_map_id)
	show_map("抵达 %s" % next.display_name, from_id)


## 构造 {地图id: display_name}，供 WorldMap 把目的地 id 翻成中文。
func _map_names() -> Dictionary:
	var names := {}
	for map in maps:
		if map != null:
			names[map.id] = map.display_name
	return names


## 取 world_root 下当前的世界地图（按类型找，避免保存野引用）；没有返回 null。
func _current_world_map() -> WorldMap:
	for child in world_root.get_children():
		if child is WorldMap:
			return child
	return null


## 记住本图离开时的归一化位置；不在世界地图时跳过，保留上次位置（正好用于回地图）。
func _remember_position() -> void:
	var world := _current_world_map()
	if world != null:
		_map_positions[current_map_id] = world.player_normalized()


## 进入战斗：记位置 → **拍一张当前地图当背景** → 生成敌人 → 实例化 Battle，await _swap 后 start_battle（不 await 战斗本身）。
## ⚠ auto_start_demo=false 和 connect 都必须在 add_child 之前；start_battle 必须在淡入之后，否则黑屏中开打。
## 上阵为空或敌人池为空时警告返回；_last_enemy_count 在这里记下。
func enter_battle() -> void:
	if deployed.is_empty():
		push_warning("GameRoot: 没有上阵的队员（去队伍管理里上阵，或先招募队友）")
		show_map()
		return
	_remember_position()                    # 打完回来还站在这儿
	var enemies := _make_enemy_team()
	if enemies.is_empty():
		push_warning("GameRoot: 敌人池是空的 —— 给地图资源或 GameRoot.enemy_pool 填敌人")
		return
	_last_enemy_count = enemies.size()      # 结算时按"打了几个"给经验（见 exp_reward）

	# 战斗背景 = 当前地图的截图（隐藏 NPC/玩家/UI 后拍，Battle 里再压一层暗色蒙层）。
	# 必须在 _swap 淡出之前拍：那时地图还是可见的、fade 还是透明的。
	var backdrop := await _capture_battle_backdrop()

	var battle := BATTLE_SCENE.instantiate() as Battle
	battle.auto_start_demo = false          # ★ 必须在 add_child 之前
	battle.battle_ended.connect(_on_battle_ended)
	battle.set_backdrop(backdrop)           # 也必须早于 add_child（_ready 里就要用）
	in_battle = true
	await _swap(battle, world_root)
	battle.start_battle(_make_player_team(), enemies)


## 战斗背景截图的宽度上限（像素）。背景不需要高清：缩到这个宽度再由 TextureRect 拉伸，
## 一来省显存/上传（1680×960 ≈ 6.4MB → 720×411 ≈ 1.2MB），二来放大后天然柔化、不抢镜。
const PHOTO_MAX_WIDTH := 720


## 让当前地图拍一张"没有 NPC/玩家/UI"的截图；没有地图时返回 null（战斗退回绿底）。
func _capture_battle_backdrop() -> Texture2D:
	var world := _current_world_map()
	if world == null:
		return null
	var img: Image = await world.capture_map_photo()
	if img == null or img.is_empty():
		return null
	if img.get_width() > PHOTO_MAX_WIDTH:
		var h := int(roundf(float(img.get_height()) * PHOTO_MAX_WIDTH / float(img.get_width())))
		img.resize(PHOTO_MAX_WIDTH, maxi(1, h), Image.INTERPOLATE_BILINEAR)
	return ImageTexture.create_from_image(img)


# ── 战斗结算 ──

## 战斗结束：胜利记 cleared_maps（唯一写入点）、加金币、按上阵成员发经验；失败只写文案；随后回地图原地。
## 不直接清 Battle：show_map→_swap 先 fade_out，_clear_screens 发生在信号返回后，避免在自身回调里 free 自己。
## ⚠ Battle 侧对 battle_ended 只发一次，这里不会重复发奖。
func _on_battle_ended(player_won: bool) -> void:
	in_battle = false
	var map := get_map(current_map_id)
	var map_name := map.display_name if map != null else current_map_id

	if player_won:
		cleared_maps[map.id if map != null else current_map_id] = true
		var reward := coin_reward_per_map * map_difficulty()
		Global.coins += reward
		# 经验：和金币同一条公式思路（难度越高越多），另加"按敌人数量"的份（见 exp_reward）
		var exp_gain := exp_reward(_last_enemy_count)
		# 只发给**这一场上阵**的人：每个队员各自独立升级（等级/经验按角色存，板凳不涨）
		var lines: Array[String] = ["%s：战斗胜利！" % map_name]
		var gained_lines: Array[String] = []
		for member in deployed:
			if member == null:
				continue
			var gained := add_exp(member, exp_gain)
			if gained > 0:
				gained_lines.append("%s 升到 Lv.%d（获得 %d 点自由属性）" % [
						member.name, level_of(member), gained * ATTR_FREE_PER_LEVEL])
		if exp_gain <= 0:
			lines.append("获得 %d 金币" % reward)
		else:
			lines.append("获得 %d 金币 · 上阵每人经验 +%d" % [reward, exp_gain])
		lines.append_array(gained_lines)
		_last_result = "\n".join(lines)
	else:
		_last_result = "%s：战斗失败…（可以再挑战一次）" % map_name
	show_map(_last_result, "", true)         # 回到地图上原来的位置


# ── 队伍生成 ──

# ── 团队（party）与上阵名单（deployed）：增删/规则判定入口（开局初始化除外）──
# party=大名单（不限队长位）；deployed=真正上场（≤5，必须是 party 子集）。
# **队长 = 上阵名单的第 0 位**（见 leader()）：上阵/下阵/「设为队长」都能改变队长。
# 两者都是 Array[UnitStats] 引用、按引用交给 WorldMap；⚠ 只能就地增删，别整个重新赋值。

## 队长 = 上阵名单的第 0 位；没人上阵时退回团队第 0 位，再没有就退回开局主角。
## 地图上操控的角色、背包/属性面板默认展示的人，都跟着它走。
func leader() -> UnitStats:
	return leader_of(party, deployed)


## 静态版：外部脚本拿不到 GameRoot 的实例字段（`class_name GameRoot` 与 autoload 同名，
## `GameRoot.leader()` 会被当成"类"调用而报错），所以把两个数组显式传进来查。
static func leader_of(p_party: Array[UnitStats], p_deployed: Array[UnitStats]) -> UnitStats:
	if not p_deployed.is_empty() and p_deployed[0] != null:
		return p_deployed[0]
	if not p_party.is_empty() and p_party[0] != null:
		return p_party[0]
	return Global.main_player_selected


## 把某个**已上阵**的成员设为队长（挪到 deployed 第 0 位）。
## 返回值：true = 真的换了位置；false = 不在上阵名单或本来就是第一位。
func set_leader(stats: UnitStats) -> bool:
	if stats == null or not is_deployed(deployed, stats):
		return false
	var index := -1
	for i in deployed.size():
		if deployed[i] != null and (deployed[i] == stats or deployed[i].name == stats.name):
			index = i
			break
	if index <= 0:
		return false
	deployed.remove_at(index)
	deployed.insert(0, stats)
	party_changed.emit()
	return true


## 非 null 成员数（允许空位，不能只用 size()）。静态函数让面板共用同一套规则。
static func party_count(p_party: Array[UnitStats]) -> int:
	var n := 0
	for stats in p_party:
		if stats != null:
			n += 1
	return n


## 角色是否已在名单里：引用 → resource_path → name 逐级比对（兜底同名/重载资源）。
static func party_has(p_party: Array[UnitStats], stats: UnitStats) -> bool:
	if stats == null:
		return false
	for member in p_party:
		if member == null:
			continue
		if member == stats:
			return true
		if not member.resource_path.is_empty() and member.resource_path == stats.resource_path:
			return true
		if member.name == stats.name:
			return true
	return false


## 能否加入团队：去重 + 人数上限（max_size=-1 用 MAX_TEAM_SIZE，0=不限）；⚠ 不看上阵人数。
static func party_can_join(p_party: Array[UnitStats], stats: UnitStats, max_size := -1) -> bool:
	if stats == null:
		return false
	var limit := max_size if max_size >= 0 else MAX_TEAM_SIZE
	if limit > 0 and party_count(p_party) >= limit:
		return false
	return not party_has(p_party, stats)


## 上阵人数（与 party_count 同义，单独命名避免和团队人数看混）。
static func deployed_count(p_deployed: Array[UnitStats]) -> int:
	return party_count(p_deployed)


## 这个人现在是不是在上阵名单里。
static func is_deployed(p_deployed: Array[UnitStats], stats: UnitStats) -> bool:
	return party_has(p_deployed, stats)


## 这个人现在能不能上阵：没在上阵名单里，且上阵位没满。
static func deploy_can_add(p_deployed: Array[UnitStats], stats: UnitStats) -> bool:
	if stats == null:
		return false
	if party_count(p_deployed) >= MAX_DEPLOYED:
		return false
	return not party_has(p_deployed, stats)


## 能否下阵：在上阵名单里且下阵后仍 ≥1 人（空阵容进不了战斗，面板据此置灰）。
static func deploy_can_remove(p_deployed: Array[UnitStats], stats: UnitStats) -> bool:
	if stats == null or not party_has(p_deployed, stats):
		return false
	return party_count(p_deployed) > 1


## 成员名列表（跳过空位）；用 PackedStringArray 以便直接 String.join()。
static func party_names_of(p_party: Array[UnitStats]) -> PackedStringArray:
	var names := PackedStringArray()
	for stats in p_party:
		if stats != null:
			names.append(stats.name)
	return names


## 招进团队：就地 append；有空的上阵位就顺手让他上阵；emit party_changed。true=成功。
## 不负责刷界面（调用方通知 WorldMap）；上阵位满则只进名册。
func add_party_member(stats: UnitStats) -> bool:
	if not party_can_join(party, stats):
		return false
	party.append(stats)
	if deploy_can_add(deployed, stats):
		deployed.append(stats)
	party_changed.emit()
	return true


## 移出团队：任何人都能移（包括队长 —— 队长只是"上阵第一位"，人走了下一位自动顶上）；
## 同时从 deployed 摘掉并 emit party_changed。团队最后一人不允许移出，否则地图上没人可操控。
func remove_party_member(stats: UnitStats) -> bool:
	if stats == null:
		return false
	if party_count(party) <= 1:
		push_warning("GameRoot: 团队至少留 1 人")
		return false
	for i in party.size():
		var member := party[i]
		if member == null:
			continue
		if member == stats or member.name == stats.name:
			party.remove_at(i)
			_undeploy_silently(member)
			party_changed.emit()
			return true
	return false


## 上阵：需在团队且未上阵、上阵位未满；不自动踢人（换谁下由玩家决定）。
func deploy_member(stats: UnitStats) -> bool:
	if not party_has(party, stats):
		return false
	if not deploy_can_add(deployed, stats):
		return false
	deployed.append(stats)
	party_changed.emit()
	return true


## 让某个队员**下阵**。返回值：true = 成功；false = 没成（不在上阵名单 / 只剩他一个）。
## 副作用：从 deployed 里摘掉 + emit party_changed。
func undeploy_member(stats: UnitStats) -> bool:
	if not deploy_can_remove(deployed, stats):
		return false
	_undeploy_silently(stats)
	party_changed.emit()
	return true


## 无条件从 deployed 摘掉（不校验、不发信号）：移出团队时用，不能被"至少留 1 人"规则挡住。
func _undeploy_silently(stats: UnitStats) -> void:
	if stats == null:
		return
	for i in deployed.size():
		var member := deployed[i]
		if member != null and (member == stats or member.name == stats.name):
			deployed.remove_at(i)
			return


## 招募回调：成功则 add_party_member() 并回写"加入了团队"；失败只回写原因（不改状态）。
## world 可能为 null（理论上此时没有招募面板），访问前都判空。
func _on_recruit_requested(stats: UnitStats) -> void:
	var world := _current_world_map()
	if not party_can_join(party, stats):
		var why := "团队已经满了（上限 %d 人）。" % MAX_TEAM_SIZE
		if stats != null and party_has(party, stats):
			why = "%s 已经在团队里了。" % stats.name
		if world != null:
			world.notify_party_changed(why)
		return
	add_party_member(stats)
	var tail := "（已上阵）" if is_deployed(deployed, stats) else "（先进名册，上阵位已满）"
	if world != null:
		world.notify_party_changed("%s 加入了团队！%s" % [stats.name, tail])


## 上阵回调：成功改 deployed 并刷新提示；失败只把原因写回面板。
func _on_party_deploy_requested(stats: UnitStats) -> void:
	var world := _current_world_map()
	if not deploy_member(stats):
		var why := "上阵位已经满了（%d 人），先让一个下阵。" % MAX_DEPLOYED
		if stats != null and not party_has(party, stats):
			why = "%s 不在团队里。" % stats.name
		elif stats != null and is_deployed(deployed, stats):
			why = "%s 已经在上阵名单里了。" % stats.name
		if world != null:
			world.notify_party_changed(why)
		return
	if world != null:
		world.notify_party_changed("%s 已上阵。" % stats.name)


## 下阵回调：成功改 deployed 并刷新提示；失败只写原因（至少要留 1 人）。
func _on_party_undeploy_requested(stats: UnitStats) -> void:
	var world := _current_world_map()
	if not undeploy_member(stats):
		var why := "至少要留 1 人上阵。"
		if stats != null and not is_deployed(deployed, stats):
			why = "%s 本来就没在上阵名单里。" % stats.name
		if world != null:
			world.notify_party_changed(why)
		return
	if world != null:
		world.notify_party_changed("%s 已下阵。" % stats.name)


## 移出团队回调：成功则移出并刷新；失败只写原因（不在团队 / 团队只剩他一人）。
func _on_party_remove_requested(stats: UnitStats) -> void:
	var world := _current_world_map()
	if not remove_party_member(stats):
		var why := "这个成员不在团队里。"
		if party_count(party) <= 1:
			why = "团队至少留 1 人。"
		if world != null:
			world.notify_party_changed(why)
		return
	if world != null:
		world.notify_party_changed("%s 已离开团队。" % stats.name)


## 「设为队长」回调：把选中的已上阵成员挪到上阵名单第一位（队长 = 第一位）。
## 成功后重新走一遍地图（队长换了，地图上操控的立绘/跟随都要重建）。
func _on_party_lead_requested(stats: UnitStats) -> void:
	var world := _current_world_map()
	if not set_leader(stats):
		if world != null:
			world.notify_party_changed("他不在上阵名单里，不能设为队长。")
		return
	if world != null:
		world.notify_party_changed("%s 已成为队长。" % stats.name)


# ── 背包（Global.equipped_weapons）与装备栏（Global.equipment_by_character）──
# 只记数据、不造节点；买/卖/穿/脱都走这里的统一判定，界面只读结果。
# 背包与装备栏互补：穿上=从背包取出放进角色栏位，脱下=反向，所以卖出前必须先脱。

## 背包格数（BagPanel 一行 8 格、一屏 7 行共 56 格，其余滚动）；满 120 件买不进。
const BAG_SLOTS := 120


## 背包内同名道具数量（引用 → resource_path → item_name，与 party_has 一致）。
static func item_owned_count(p_equipped: Array[ItemBase], item: ItemBase) -> int:
	if item == null:
		return 0
	var n := 0
	for owned in p_equipped:
		if owned == null:
			continue
		if owned == item:
			n += 1
		elif not owned.resource_path.is_empty() and owned.resource_path == item.resource_path:
			n += 1
		elif owned.item_name == item.item_name:
			n += 1
	return n


## 能否购买：空串=能，否则为原因。静态函数让面板与购买共用同一份判定。
static func item_can_buy(item: ItemBase, coins: int, p_equipped: Array[ItemBase]) -> String:
	if item == null:
		return "这件东西不存在。"
	if item.item_cost > 0 and coins < item.item_cost:
		return "金币不够（需要 %d，现在 %d）。" % [item.item_cost, coins]
	if p_equipped.size() >= BAG_SLOTS:
		return "背包满了（%d 格都占着），先卖出或合成。" % BAG_SLOTS
	return ""


## 购买：扣 Global.coins 并入 Global.equipped_weapons（背包写入点之一）；不发信号，界面由调用方刷新。
func buy_item(item: ItemBase) -> bool:
	if not item_can_buy(item, Global.coins, Global.equipped_weapons).is_empty():
		return false
	Global.coins -= item.item_cost
	Global.equipped_weapons.append(item)
	return true


## 购买回调：成功则入包并让商店/背包按新状态重建；失败只写原因。
func _on_item_buy_requested(item: ItemBase) -> void:
	var world := _current_world_map()
	var why := item_can_buy(item, Global.coins, Global.equipped_weapons)
	if not why.is_empty():
		if world != null:
			world.notify_shop_changed(why)
		return
	buy_item(item)
	if world != null:
		world.notify_shop_changed("买下了 %s（-%d 金币）。" % [item.item_name, item.item_cost])


# ── 卖出 ──
## 返还比例 0.75（截断取整，21 金币卖 15）；留 25% 折旧，防止低买高卖刷钱。
const SELL_REFUND_RATIO := 0.75


## 卖价 = int(item_cost × 0.75)；空道具/非卖品（cost≤0）返回 0。
static func item_sell_price(item: ItemBase) -> int:
	if item == null or item.item_cost <= 0:
		return 0
	return int(item.item_cost * SELL_REFUND_RATIO)


## 能否卖出：空串=能；规则为背包里有且卖价>0。面板与执行共用此判定。
static func item_can_sell(item: ItemBase, p_equipped: Array[ItemBase]) -> String:
	if item == null:
		return "这件东西不存在。"
	if item_owned_count(p_equipped, item) <= 0:
		return "背包里没有「%s」。" % item.item_name
	if item_sell_price(item) <= 0:
		return "「%s」卖不出价钱（非卖品）。" % item.item_name
	return ""


## 卖出：从背包移除一件并把卖价加进 Global.coins（与 buy_item 同是背包写入点）。
## item_can_sell 按 path/name 判"有没有"，所以这里也要按同一套规则找出**真正在背包里的那一件**再删，
## 不能直接 erase(传入的引用)（等价不同实例会"加钱但没扣件"）。
func sell_item(item: ItemBase) -> bool:
	if not item_can_sell(item, Global.equipped_weapons).is_empty():
		return false
	var index := _find_owned_index(Global.equipped_weapons, item)
	if index < 0:
		return false
	Global.equipped_weapons.remove_at(index)
	Global.coins += item_sell_price(item)
	return true


## 在数组里找 item 对应的那一件的下标（同一套匹配规则：引用 → resource_path → item_name）。
## 返回 -1 = 没找到。
static func _find_owned_index(p_equipped: Array[ItemBase], item: ItemBase) -> int:
	if item == null:
		return -1
	for i in p_equipped.size():
		var owned := p_equipped[i]
		if owned == null:
			continue
		if owned == item:
			return i
		if not owned.resource_path.is_empty() and owned.resource_path == item.resource_path:
			return i
		if owned.item_name == item.item_name:
			return i
	return -1


## 卖出回调：成功后加钱出包并刷新商店/背包；失败只写原因。
func _on_item_sell_requested(item: ItemBase) -> void:
	var world := _current_world_map()
	var why := item_can_sell(item, Global.equipped_weapons)
	if not why.is_empty():
		if world != null:
			world.notify_shop_changed(why)
		return
	var price := item_sell_price(item)
	sell_item(item)
	if world != null:
		world.notify_shop_changed("卖掉了 %s（+%d 金币）。" % [item.item_name, price])


# ── 装备栏（每角色 6 格：头盔/武器/腰带/项链/衣服/鞋子）──
# Global.equipment_by_character = {角色键 → {EquipType → ItemBase}}，每个团队成员一套。
# 穿上=从背包取出放进栏位（旧装备回背包）；能否穿由 item_can_equip() 统一判定。


## 角色键：优先 resource_path（重载/同名不同 .tres 都能区分）→ name → instance_id 兜底；空角色 ""。
static func character_key(character: UnitStats) -> String:
	if character == null:
		return ""
	if not character.resource_path.is_empty():
		return character.resource_path
	if not character.name.is_empty():
		return character.name
	return "instance_%d" % character.get_instance_id()


## 角色整套装备（EquipType → ItemBase）；没有则空字典。⚠ 返回存储本体，只读，改请走 equip/unequip。
static func equipment_of(character: UnitStats) -> Dictionary:
	var key := character_key(character)
	if key.is_empty():
		return {}
	return Global.equipment_by_character.get(key, {})


## 某栏位当前装备；空栏返回 null。
static func equipment_in(character: UnitStats, slot_type: int) -> ItemBase:
	return equipment_of(character).get(slot_type)


## 能否给该角色穿这件：空串=能；规则为有角色、物品可装备、且在背包里。
static func item_can_equip(character: UnitStats, item: ItemBase) -> String:
	if character == null:
		return "现在没有选中角色。"
	if item == null:
		return "这件东西不存在。"
	if item.get_equip_type() == ItemBase.EquipType.NONE:
		return "「%s」不能装备。" % item.item_name
	if not Global.equipped_weapons.has(item):
		return "背包里没有「%s」。" % item.item_name
	return ""


## 穿上：移出背包 item、旧装备放回背包，再写入角色栏位（交换语义，背包满也不会失败）。
## 返回空串=成功，否则为原因；写 Global.equipped_weapons / equipment_by_character。
static func equip_item(character: UnitStats, item: ItemBase) -> String:
	var why := item_can_equip(character, item)
	if not why.is_empty():
		return why
	var slot_type: int = item.get_equip_type()
	var key := character_key(character)
	var slots: Dictionary = Global.equipment_by_character.get(key, {})
	var old: ItemBase = slots.get(slot_type)
	Global.equipped_weapons.erase(item)
	if old != null:
		Global.equipped_weapons.append(old)
	slots[slot_type] = item
	Global.equipment_by_character[key] = slots      # 新角色第一次穿时要把这张表写回外层字典
	return ""


## 脱下：从栏位删掉并放回背包；整套空了就删角色键。空串=成功；背包满时不脱。
static func unequip_slot(character: UnitStats, slot_type: int) -> String:
	if character == null:
		return "现在没有选中角色。"
	var key := character_key(character)
	var slots: Dictionary = Global.equipment_by_character.get(key, {})
	var item: ItemBase = slots.get(slot_type)
	if item == null:
		return "%s的%s栏现在是空的。" % [character.name, ItemBase.equip_type_name(slot_type)]
	if Global.equipped_weapons.size() >= BAG_SLOTS:
		return "背包满了（%d 格都占着），先腾出一格再脱。" % BAG_SLOTS
	slots.erase(slot_type)
	if slots.is_empty():
		Global.equipment_by_character.erase(key)     # 一点东西都没穿了就别留着空表
	else:
		Global.equipment_by_character[key] = slots
	Global.equipped_weapons.append(item)
	return ""


## 背包点装备：给当前展示角色穿上并刷新背包；失败只写原因。
func _on_equip_requested(character: UnitStats, item: ItemBase) -> void:
	var world := _current_world_map()
	var why := equip_item(character, item)
	var message := why
	if message.is_empty():
		message = "给%s穿上了「%s」（%s栏）。" % [character.name, item.item_name,
				ItemBase.equip_type_name(item.get_equip_type())]
	if world != null:
		world.notify_bag_changed(message)


## 点已穿栏位：脱下放回背包，界面按新状态重建。
func _on_unequip_requested(character: UnitStats, slot_type: int) -> void:
	var world := _current_world_map()
	var item: ItemBase = equipment_in(character, slot_type)
	var who: String = character.name if character != null else ""
	var why := unequip_slot(character, slot_type)
	var message := why
	if message.is_empty():
		message = "从%s身上脱下了「%s」，已放回背包。" % [who, item.item_name if item != null else ""]
	if world != null:
		world.notify_bag_changed(message)


# ── 门派（拜师）──
# 规则只有一份：Global.SECTS 的种族限制 + can_join_sect()；面板不重复判定。

## 当前门派 id（""=无门派）。
static func sect_of(character: UnitStats) -> String:
	if character == null:
		return ""
	return String(Global.sect_by_character.get(character_key(character), ""))


## 能否拜入：空串=能，否则为原因。判定顺序：空角色 → 门派不存在 → 已有门派 → 种族不符。
static func can_join_sect(character: UnitStats, sect_id: String) -> String:
	if character == null:
		return "没有选中角色。"
	if not Global.is_sect(sect_id):
		return "没有这个门派。"
	var current := sect_of(character)
	if not current.is_empty():
		return "%s已经拜入%s了，不能改投他派。" % [character.name, Global.sect_name(current)]
	if not Global.sect_accepts(sect_id, character.race):
		return "%s是%s，%s只收%s。" % [character.name, character.race_name(),
				Global.sect_name(sect_id), Global.sect_races_text(sect_id)]
	return ""


## 拜师：写 Global.sect_by_character 并自动学会本门全部技能（各 1 级）；空串=成功。
## ⚠ 这里是门派状态与初始技能等级的唯一写入点；之后升级走 upgrade_sect_skill()。
static func join_sect(character: UnitStats, sect_id: String) -> String:
	var why := can_join_sect(character, sect_id)
	if not why.is_empty():
		return why
	var key := character_key(character)
	Global.sect_by_character[key] = sect_id
	# 拜入门派 = 立刻学会本门 2 被动 + 3 主动（每个都是 1 级）
	var levels := {}
	for skill in Global.sect_passives(sect_id):
		levels[String(skill["id"])] = 1
	for skill in Global.sect_actives(sect_id):
		levels[String(skill["id"])] = 1
	Global.sect_skill_levels_by_character[key] = levels
	return ""


## 某门派技能等级（0=没学/没门派）；skill_id 为空时返回最低等级。
static func sect_skill_level(character: UnitStats, skill_id := "") -> int:
	if character == null:
		return 0
	var table: Dictionary = Global.sect_skill_levels_by_character.get(character_key(character), {})
	if skill_id.is_empty():
		# 不指定技能 → 返回"最低的那个"（给"这个人门派技能多少级"这类笼统文案用）
		var lowest := Global.SECT_SKILL_MAX_LEVEL
		if table.is_empty():
			return 0
		for value in table.values():
			lowest = mini(lowest, int(value))
		return lowest
	return int(table.get(skill_id, 0))


## 本门全部技能等级表的副本（无门派返回空字典）。
static func sect_skill_levels(character: UnitStats) -> Dictionary:
	if character == null:
		return {}
	return (Global.sect_skill_levels_by_character.get(character_key(character), {}) as Dictionary).duplicate()


## ── 门派技能升级：耗经验 + 金币，1→100；费用 = round(BASE + LINEAR×L + QUAD×L²)，六个系数即全部旋钮 ──
## 单技能练满约 30,600 经验 + 8,600 金币，5 个全满约 15 万/4.3 万，属长期目标。
const SKILL_EXP_BASE := 10.0
const SKILL_EXP_LINEAR := 4.0
const SKILL_EXP_QUAD := 0.03
const SKILL_COIN_BASE := 4.0
const SKILL_COIN_LINEAR := 1.0
const SKILL_COIN_QUAD := 0.01


## 升到下一级的花费 {exp, coins}；已满级返回 {0,0}。
static func sect_skill_upgrade_cost(level: int) -> Dictionary:
	if level >= Global.SECT_SKILL_MAX_LEVEL:
		return {"exp": 0, "coins": 0}
	var exp_cost := int(roundf(SKILL_EXP_BASE + SKILL_EXP_LINEAR * level + SKILL_EXP_QUAD * level * level))
	var coins := int(roundf(SKILL_COIN_BASE + SKILL_COIN_LINEAR * level + SKILL_COIN_QUAD * level * level))
	return {"exp": exp_cost, "coins": coins}


## 能否升级：空串=能，否则为可读原因。
static func sect_skill_upgrade_why(character: UnitStats, skill_id: String) -> String:
	if character == null:
		return "没有角色"
	if sect_of(character).is_empty():
		return "还没有门派"
	if sect_skill_level(character, skill_id) <= 0:
		return "还没学会这个技能"
	if sect_skill_level(character, skill_id) >= Global.SECT_SKILL_MAX_LEVEL:
		return "已经满级"
	var cost := sect_skill_upgrade_cost(sect_skill_level(character, skill_id))
	if exp_of(character) < int(cost["exp"]):
		return "经验不足（需要 %d）" % int(cost["exp"])
	if Global.coins < int(cost["coins"]):
		return "金币不足（需要 %d）" % int(cost["coins"])
	return ""


## 门派技能升级唯一入口：连升 times 次，每次扣经验+金币；返回 {ok,count,why,level}。
## times <= 0 视为无效调用（不升级，why 写明原因）；中途因经验/金币不足停下时**保留原因**。
## 写 Global.exp/coins/技能等级表。
static func upgrade_sect_skill(character: UnitStats, skill_id: String, times := 1) -> Dictionary:
	var result := {"ok": false, "count": 0, "why": "", "level": 0}
	if times <= 0:
		result["why"] = "次数必须 ≥ 1"
		result["level"] = sect_skill_level(character, skill_id)
		return result
	var why := sect_skill_upgrade_why(character, skill_id)
	if not why.is_empty():
		result["why"] = why
		result["level"] = sect_skill_level(character, skill_id)
		return result
	var key := character_key(character)
	var table: Dictionary = Global.sect_skill_levels_by_character.get(key, {})
	var level := int(table.get(skill_id, 1))
	var done := 0
	for i in times:
		if level >= Global.SECT_SKILL_MAX_LEVEL:
			result["why"] = "已经满级"
			break
		var cost := sect_skill_upgrade_cost(level)
		if exp_of(character) < int(cost["exp"]):
			result["why"] = "经验不足（需要 %d）" % int(cost["exp"])
			break
		if Global.coins < int(cost["coins"]):
			result["why"] = "金币不足（需要 %d）" % int(cost["coins"])
			break
		Global.exp_by_character[key] = exp_of(character) - int(cost["exp"])
		Global.coins -= int(cost["coins"])
		level += 1
		done += 1
	table[skill_id] = level
	Global.sect_skill_levels_by_character[key] = table
	result["ok"] = done > 0
	result["count"] = done
	result["level"] = level
	return result


## 门派技能一行摘要（未拜师返回提示文字）。
static func sect_skill_summary(character: UnitStats) -> String:
	var sect_id := sect_of(character)
	if sect_id.is_empty():
		return "门派技能：拜入门派后自动学习"
	var parts: Array[String] = []
	for skill in Global.sect_passives(sect_id) + Global.sect_actives(sect_id):
		parts.append("%s Lv.%d" % [skill["name"], sect_skill_level(character, String(skill["id"]))])
	return "门派技能：%s" % " · ".join(parts)


## 门派技能的完整说明（悬停提示用）：每个技能一行，主动技能带上"当前目标数"。
static func sect_skill_details(character: UnitStats) -> String:
	var sect_id := sect_of(character)
	if sect_id.is_empty():
		return "还没有门派 —— 去桃花村找五位掌门拜师。"
	var lines: Array[String] = []
	for skill in Global.sect_passives(sect_id):
		var level := sect_skill_level(character, String(skill["id"]))
		lines.append("【被动】%s Lv.%d\n%s" % [skill["name"], level, skill["desc"]])
	for skill in Global.sect_actives(sect_id):
		var level := sect_skill_level(character, String(skill["id"]))
		var extra := ""
		if skill.has("targets") or bool(skill.get("targets_all", false)):
			extra = "（当前目标：%s）" % Global.sect_skill_targets_text(skill, level)
		lines.append("【主动】%s Lv.%d%s\n%s" % [skill["name"], level, extra, skill["desc"]])
	return "\n\n".join(lines)


## 拜师回调：成功则写门派/技能并回多行文案（首行拜入，其后每技能一行）；失败只回原因。
func _on_join_sect_requested(character: UnitStats, sect_id: String) -> void:
	var world := _current_world_map()
	var why := join_sect(character, sect_id)
	var message := why
	if message.is_empty():
		var lines: Array[String] = ["%s拜入%s！" % [character.name, Global.sect_name(sect_id)]]
		for skill in Global.sect_passives(sect_id) + Global.sect_actives(sect_id):
			lines.append("学会 %s（Lv.%d）" % [skill["name"], sect_skill_level(character, String(skill["id"]))])
		message = "\n".join(lines)
	if world != null:
		world.notify_sect_changed(message)


## 把 deployed 转成可随便改的我方队伍交给 Battle（返回新数组）。
## ⚠ 用 deployed 而非 party；逐个 duplicate() 避免战斗改坏 .tres，派生属性覆盖到副本上。
## ⚠ duplicate() 默认浅拷贝：数组字段（如 skills）与原件共享，别就地 append。
func _make_player_team() -> Array[UnitStats]:
	var out: Array[UnitStats] = []
	for stats in deployed:
		if stats == null:
			continue
		# duplicate：战斗改的是副本，不污染 .tres（以后做"战斗结束回写血量"也方便）
		var copy := stats.duplicate() as UnitStats
		# 等级+基础属性 → 派生属性覆盖到副本；防御/躲避/法伤及二级属性只带进去（战斗暂未用）。
		# 不再乘旧的"每级 ×1.5%"倍率，成长全由属性点承担。
		var d := derived_stats(stats)
		copy.health = maxf(1.0, float(d["hp"]))
		copy.damage = maxf(1.0, float(d["damage"]))
		copy.mana = maxf(1.0, float(d["mana"]))
		copy.speed = maxf(1.0, float(d["speed"]))
		copy.defense = float(d["defense"])
		copy.dodge = float(d["dodge"])
		copy.spell_damage = float(d["spell_damage"])
		copy.spell_defense = float(d["spell_defense"])
		copy.crit_rate = float(d["crit_rate"])
		copy.crit_damage_bonus = float(d["crit_damage_bonus"])
		copy.seal_hit = float(d["seal_hit"])
		copy.healing = float(d["healing"])
		copy.crit_resist = float(d["crit_resist"])
		copy.crit_damage_resist = float(d["crit_damage_resist"])
		copy.seal_resist = float(d["seal_resist"])
		copy.block_value = float(d["block_value"])
		# 门派被动（太虚剑典 +伤害、剑心通明 +暴击 …）按门派技能等级叠上去
		_apply_sect_passives(copy, stats)
		# 门派**主动**技能：按角色当前等级烤一份副本塞进战斗副本的 skills（材料在 resources/skills/sect_skills/）
		_attach_sect_skills(copy, stats)
		out.append(copy)
	return out


## 把角色本门的 3 个主动技能塞进战斗副本。
## 参数 copy：战斗副本；source：原始 UnitStats（查门派与技能等级）。
## 副作用：给 copy.skills **赋一个新数组** —— duplicate() 出来的 skills 和原资源共享同一个 Array，
##   就地 append 会污染 .tres，所以必须 `copy.skills = 新数组`。
## 等级处理：目标数这类"按等级变"的参数在这里烤进**技能副本**（`SkillData.duplicate()`），
##   .tres 本身永远只存 1 级基线；没学会（等级 0）或资源缺失的技能直接跳过。
static func _attach_sect_skills(copy: UnitStats, source: UnitStats) -> void:
	var sect_id := sect_of(source)
	if sect_id.is_empty():
		return
	var merged: Array[SkillData] = []
	merged.assign(copy.skills)
	for entry in Global.sect_actives(sect_id):
		var baked := _bake_sect_skill(entry, sect_skill_level(source, String(entry["id"])))
		if baked != null:
			merged.append(baked)
	copy.skills = merged


## 按技能等级烤一份门派主动技能副本（.tres 只存 1 级基线）。
## 参数 entry：Global.sect_actives() 的一项；level：1 起，0 = 没学会。
## 返回 null 表示不挂（等级 0 / 资源缺失），调用方直接跳过。
## ⚠ 目标数阈值（30/60 级）、AoE 衰减、buff 成长都在这里算死，别在别处再乘一遍。
static func _bake_sect_skill(entry: Dictionary, level: int) -> SkillData:
	if level <= 0:
		return null
	var resource := Global.sect_skill_resource(String(entry["id"]))
	if resource == null:
		return null
	var baked := resource.duplicate() as SkillData
	# 目标数阈值（30/60/25/50/75 级那些）在 Global 表里；-1 = "全体"（由 target_mode=ENEMY_ALL 表达）
	var targets := Global.sect_skill_targets(entry, level)
	baked.max_targets = targets if targets > 0 else 1
	var n := baked.max_targets
	# 伤害倍率：单体 1.8；群体按"每多一个目标 -12% 单体倍率"衰减（梦幻西游手游实测）。
	# 连击技能：总倍率拆到每一击；配了 hit_power 曲线的（太虚神剑）原样保留。
	if baked.hits > 1 and not baked.hit_power.is_empty():
		pass
	elif baked.fixed_damage:
		baked.flat_damage = (baked.flat_damage + baked.flat_per_level * float(level - 1)) \
				* SKILL_AOE_DECAY_STEP(n)
	elif baked.power > 0.0:
		var total := SKILL_SINGLE_POWER * SKILL_AOE_DECAY_STEP(n)
		baked.power = total / float(maxi(1, baked.hits))
	# 状态（buff）数值也按等级烤：buff_value 是 1 级基线，buff_per_level 是每级增量
	if not baked.buff_stat.is_empty():
		baked.buff_value = baked.buff_value + baked.buff_per_level * float(level - 1)
	return baked


## 给一只敌怪挂某个门派的主动技能（只用战斗副本，**不写 Global**）。
## 为什么不复用 _attach_sect_skills：那套要读 Global.sect_by_character + 技能等级表，
## 怪物两个都不在；而且怪物是 DEMON 族，按 Global.SECTS 的种族限制根本入不了门 ——
## 这里刻意忽略种族，当作"魔修学了别派残招"的设定。
static func attach_enemy_sect_skills(copy: UnitStats, sect_id: String, level: int) -> void:
	if copy == null or sect_id.is_empty():
		return
	var merged: Array[SkillData] = []
	merged.assign(copy.skills)
	for entry in Global.sect_actives(sect_id):
		var baked := _bake_sect_skill(entry, level)
		if baked != null:
			merged.append(baked)
	copy.skills = merged


## 把门派被动按各自等级叠到战斗副本（damage/health/crit_rate/speed/defense/spell_damage/healing/seal_hit）。
static func _apply_sect_passives(copy: UnitStats, source: UnitStats) -> void:
	var sect_id := sect_of(source)
	if sect_id.is_empty():
		return
	for skill in Global.sect_passives(sect_id):
		var level := sect_skill_level(source, String(skill["id"]))
		if level <= 0:
			continue
		var amount := float(skill.get("per_level", 0.0)) * level
		match String(skill.get("stat", "")):
			"damage_pct":
				copy.damage *= 1.0 + amount / 100.0
			"hp_pct":
				copy.health *= 1.0 + amount / 100.0
			"crit_rate":
				copy.crit_rate += amount
			"crit_damage_bonus":
				copy.crit_damage_bonus += amount
			"speed":
				copy.speed += amount
			"defense":
				copy.defense += amount
			"spell_damage":
				copy.spell_damage += amount
			"healing":
				copy.healing += amount
			"seal_hit":
				copy.seal_hit += amount


## 按当前地图难度生成敌方队伍；池子为空返回空数组（调用方中止）。
## 池：MapData.enemy_pool 非空则用，否则 enemy_pool；数量 = clampi(上阵人数 ±1, 1, 5)。
## ⚠ scale 用原始 base 值乘（不累乘，避免循环抽到同一只时复利）；maxf(1.0,…) 兜底防 0/负血。
func _make_enemy_team() -> Array[UnitStats]:
	var out: Array[UnitStats] = []
	var map := get_map(current_map_id)
	var pool: Array[UnitStats] = map.enemy_pool if map != null and not map.enemy_pool.is_empty() else enemy_pool
	if pool.is_empty():
		return out

	var difficulty := map_difficulty()
	# 数量 = 上阵人数 或 上阵人数 +1（以前是 ±1，会出现敌人比玩家人少的情况）。
	# 上限 MAX_ENEMY_COUNT = 5：敌方战场只有 5 个站位，5 人队时就是 5 打 5。
	var count := clampi(deployed_count(deployed) + randi_range(0, 1), 1, MAX_ENEMY_COUNT)
	var scale: float = 1.0 + (difficulty - 1) * enemy_scale_per_map
	for i in count:
		var base: UnitStats = pool[i % pool.size()]
		if base == null:
			continue
		var scaled := base.duplicate() as UnitStats
		# 敌人也走同一套"基础属性 → 派生值"：.tres 里配 attributes，这里算成实际数值。
		# 地图难度缩放作用在派生结果上（难度越高，敌人整体越强）。
		var d := derived_stats(scaled)
		scaled.health = maxf(1.0, float(d["hp"]) * scale)
		scaled.damage = maxf(1.0, float(d["damage"]) * scale)
		scaled.mana = float(d["mana"])
		scaled.defense = float(d["defense"])
		scaled.speed = maxf(1.0, float(d["speed"]))
		scaled.dodge = float(d["dodge"])
		scaled.spell_damage = float(d["spell_damage"])
		scaled.spell_defense = float(d["spell_defense"])
		scaled.crit_rate = float(d["crit_rate"])
		scaled.crit_damage_bonus = float(d["crit_damage_bonus"])
		scaled.seal_hit = float(d["seal_hit"])
		scaled.healing = float(d["healing"])
		scaled.crit_resist = float(d["crit_resist"])
		scaled.crit_damage_resist = float(d["crit_damage_resist"])
		scaled.seal_resist = float(d["seal_resist"])
		scaled.block_value = float(d["block_value"])
		# 随机入一个门派：怪物也会门派招式（战斗里靠 Battle._enemy_act 放）。
		# 等级跟着地图难度走：1 级图给 1 级技能（单体），高难度图能拿到群体那几档。
		var sect_ids := Global.SECTS.keys()
		if not sect_ids.is_empty():
			var sect_id := String(sect_ids[randi() % sect_ids.size()])
			var skill_level := clampi(1 + int(round((difficulty - 1.0) * 3.0)), 1, 6)
			attach_enemy_sect_skills(scaled, sect_id, skill_level)
		out.append(scaled)
	return out
