# battle_unit.gd —— 单个战斗单位：战斗期可变状态 + 自身表现。
# 状态：hp/mp/cooldowns/defending/alive 都在本脚本的普通变量里；UnitStats 是共享资源，只读不改。
# 表现：攻击位移、施法起手、受击闪烁、选中/目标高亮、血条刷新。
# 谁先出手、打谁、何时结束全由 Battle 驱动；本脚本没有 AI、不主动调用 Battle（单向依赖）。
# 生命周期坑：@onready 只在进树那一刻赋值，所以 Battle 必须先 add_child() 再 setup()；
#   _ready() 早于 setup()，那时 stats 还是 null，依赖 stats 的初始化只能放 setup()。
# 扩展点：伤害/暴击/格挡 → roll_damage()/roll_crit()/try_block()；技能数值 → skill_damage()/skill_crit()；
#   动作演出 → play_attack()/play_cast()/play_hit()；Buff/Debuff 尚未实现（建议加 status 字典 + tick_status()）。
extends Node2D
class_name BattleUnit

## 战斗单位：血量/蓝量状态 + 表现；战斗流程（谁出手、打谁、何时结束）由 Battle 驱动。
## 数据来源：UnitStats（name/icon/health/mana/damage/speed/block_chance/skills），只读。
## 扩展点：伤害公式 → roll_damage()/roll_crit()/try_block()；技能数值 → skill_damage()/skill_crit()。

# ── 对外信号 ──
# 本脚本只"汇报发生了什么"，从不自己决定流程怎么走——所有决策都在 Battle。

## 左键点到本单位（%ClickArea 转发）。谁接：Battle._on_unit_clicked()。
## 敌我双方都会发，由 Battle 用 state 判断是否响应；阵亡后 input_pickable 关闭，不再发。
signal clicked(unit: BattleUnit)

## 鼠标进入/离开。entered=true 进入。目前无消费者，预留给"敌方信息浮窗"。
signal hovered(unit: BattleUnit, entered: bool)

## 血量变化（_refresh_hp() 里发）。目前内部没连，留给外部的战斗日志/悬浮卡。
signal hp_changed(unit: BattleUnit)

## 蓝量变化（_refresh_mana() 里发）。start_cooldown() 也会借它刷新菜单的"冷却 N"。
signal mp_changed(unit: BattleUnit)

## 单位阵亡（_die() 里发，此时 alive=false、点选已关、淡出已启动）。
## 谁接：Battle._on_unit_died()，只刷新顺序条，不从回合队列移除。本信号只发一次。
signal died(unit: BattleUnit)

# ── 视觉常量（选中/目标/悬停/受击/防御/施法配色）──
# 写死不 @export：这是全局统一的战斗语言。颜色都带 alpha，铺在 %Selection 的半透明圈上。

## 当前行动者：暖黄 30%。
const SELECT_COLOR := Color(1.0, 0.86, 0.35, 0.30)
## 待选目标：红 35%，与行动者明显区分。
const TARGET_COLOR := Color(1.0, 0.35, 0.35, 0.35)
## 悬停弱高亮：白 20%，只暗示"可点"。
const HOVER_COLOR := Color(1.0, 1.0, 1.0, 0.20)
## 受击闪红。modulate 是**乘法**染色，(1.0,0.45,0.45) 会让红通道保持、绿蓝压暗。
const HIT_TINT := Color(1.0, 0.45, 0.45)
## 防御淡蓝；play_cast()/play_hit() 收尾也回到它，"防御中"的提示才能保留。
const DEFEND_TINT := Color(0.75, 0.85, 1.0)
## 施法过曝暖色：G/B 通道 >1.0 是刻意的自发光（modulate 允许超过 1）。
const CAST_TINT := Color(1.45, 1.2, 0.9)

# ── 轮廓配色 ──
# 与 %Selection 色块是两套：色块铺脚下，轮廓贴剪影描实色边（%Outline），都不带 alpha。

## 我方行动者：青色。
const OUTLINE_ALLY_COLOR := Color(0.35, 0.85, 1.0)
## 敌方行动者：橙红，与青色成对。
const OUTLINE_ENEMY_COLOR := Color(1.0, 0.38, 0.30)
## 键盘/悬停选中的目标：金色（配头顶箭头）。金=这一下打谁；青/橙红=现在轮到谁。
const OUTLINE_TARGET_COLOR := Color(1.0, 0.85, 0.35)

# ── 数据源与运行时数值 ──

## 数据源（图标/血量/伤害/速度/格挡率/技能表）。正式流程由 setup() 注入。
## 重要：这是**共享资源**，一个 .tres 可能被多个单位引用，本脚本只读；
##       写 stats.health 会改到所有引用者（经典坑）。
@export var stats: UnitStats

## 是否我方。由 setup() 写入；用于贴图翻转、血条配色、Battle 的回合分发。
var is_player := false
## HP 上限；默认 1.0 只是占位，真值在 setup() 取 maxf(1.0, stats.health)。
var max_hp := 1.0
## 当前 HP（float，飘字时才 int() 取整）；降到 0 触发 _die()。
var hp := 1.0
## MP 上限；0.0 表示没配蓝 → 蓝条隐藏（见 _refresh_visuals）。
var max_mp := 0.0
## 当前 MP；消耗走 spend_mana()，不会低于 0。
var mp := 0.0
## 是否存活。_die() 置 false 后不会再变回 true（只有 setup() 会重置）。
var alive := true
## 是否防御。效果在 take_damage()：伤害 ×0.5（下限 1）。
## 生命周期：Battle._begin_turn() 在该单位**自己的回合开始时**调 set_defending(false)，
##   所以防御只持续到它下次行动前（不再是"防一次 = 永久半伤"）。
var defending := false

## skill_id -> 剩余冷却回合数（用 id 字符串做键：Resource 作键按引用比较，同技能不同实例会分家）。
## 值减到 <=0 时 tick_cooldowns() 直接删键，所以 has() 即代表"冷却中"。
var cooldowns: Dictionary[String, int] = {}
## 本场可用技能，由 Battle 注入（优先 UnitStats.skills，否则 default_skills）。
## 可能是 UnitStats.skills 那个数组本身（非拷贝），只读不改。
var available_skills: Array[SkillData] = []

# ── 高亮状态（私有，统一由 _update_selection() 消费）──
# 三个布尔分开存，取消一种高亮不会误清另一种；颜色优先级：目标 > 选中 > 悬停。
var _selected := false
var _targetable := false
var _hovered := false
## 键盘光标是否停在这里：_targetable=所有候选（红框），_focused=光标那一个（另加轮廓+头顶箭头）。
var _focused := false
## 箭头静止高度；_process 的上下浮动以它为基准，不浮动时也要精确回到这里。
var _arrow_base_y := 0.0
## sprite 初始缩放（场景里可能不是 1.0）；play_cast() 的涨大必须回到这个基准，否则会越放越大/小。
var _base_scale := Vector2.ONE

# ── 节点引用（%Xxx = unique_name_in_owner，改层级也不失效）──
# 这些 @onready 在 _ready() 之前赋值；_refresh_* 依赖它们，所以 setup() 必须在 add_child() 之后调。
@onready var sprite: Sprite2D = %Sprite
@onready var health_bar: HealthBar = %HealthBar
@onready var mana_bar: HealthBar = %ManaBar
@onready var name_label: Label = %NameLabel
@onready var selection: Polygon2D = %Selection
@onready var click_area: Area2D = %ClickArea
## 选中轮廓层：Sprite 的子节点（show_behind_parent），同贴图 + 描边 shader 往外扩一圈实色。
## 挂成 Sprite 子节点是为了自动继承本体位置/缩放——play_cast() 会 tween sprite.scale，兄弟节点会错位。
@onready var outline: Sprite2D = %Outline
## 头顶小箭头（Polygon2D 纯几何）。只在 set_focused(true) 时显示并上下浮动。
@onready var target_arrow: Polygon2D = %TargetArrow


# ── 生命周期与初始化 ──

## 生命周期入口（引擎调用，在 setup() 之前）：缓存初始缩放、连 ClickArea 三个信号、让血条/名字不吃鼠标。
## 不在这里读 stats：_ready() 时 stats 还是 null；本类父级是 Node2D，无需 super._ready()（子类则必须调）。
func _ready() -> void:
	_base_scale = sprite.scale
	_arrow_base_y = target_arrow.position.y
	# 箭头浮动是"每帧"的事，只对光标目标有意义；默认关，set_focused() 里再开。
	set_process(false)
	click_area.input_event.connect(_on_click_area_input_event)
	click_area.mouse_entered.connect(_on_mouse_entered)
	click_area.mouse_exited.connect(_on_mouse_exited)
	# Control 默认 mouse_filter=STOP 会吞事件，Area2D 就收不到 input_event，点单位会失灵。
	_ignore_mouse(health_bar)
	_ignore_mouse(mana_bar)
	_ignore_mouse(name_label)


## 把自身及所有 Control 子节点设成不接收鼠标事件（递归，因为血条内部还嵌着 ProgressBar/Label）。
## 用 MOUSE_FILTER_IGNORE 而非 PASS：完全穿透，连 hover 都不产生。只改场景实例属性，不污染 .tscn。
func _ignore_mouse(node: Node) -> void:
	if node is Control:
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in node.get_children():
		_ignore_mouse(child)


## 由 Battle 在 add_child() 之后调用：写入数值并刷新外观。参数 p_ 前缀避免与成员同名歧义。
## 副作用：覆写 stats/is_player/HP/MP/alive/defending，**清空 cooldowns**，再 _refresh_visuals()。
## HP 取 maxf(1.0, health) 防一开局判死；MP 取 maxf(0.0, mana) 允许没法力；这是唯一重置 alive 的地方。
func setup(p_stats: UnitStats, p_is_player: bool) -> void:
	stats = p_stats
	is_player = p_is_player
	max_hp = maxf(1.0, stats.health)
	hp = max_hp
	max_mp = maxf(0.0, stats.mana)
	mp = max_mp
	alive = true
	defending = false
	cooldowns.clear()
	statuses.clear()
	_refresh_visuals()


## 按 stats/is_player/当前 HP·MP 刷界面：贴图、名字、翻转、两条 bar 的染色与可见性。
## 敌人整体水平翻转（正对镜头，不用两套素材）；血条用 self_modulate 染色（只影响自己不影响子节点），
## 我方白、敌方偏红/偏蓝；max_mp==0 的单位整条蓝条隐藏。只在 setup() 调一次。
func _refresh_visuals() -> void:
	sprite.texture = stats.icon
	name_label.text = stats.name
	# 敌人翻转：flip_h 只影响绘制，不改坐标/碰撞，点击区域不受影响。
	sprite.flip_h = not is_player
	health_bar.self_modulate = Color(1, 1, 1) if is_player else Color(1, 0.72, 0.72)
	# 没蓝的单位不显示蓝条，省得所有敌人都挂着一条空槽。
	mana_bar.visible = max_mp > 0.0
	mana_bar.self_modulate = Color(1, 1, 1) if is_player else Color(0.85, 0.85, 1)
	_refresh_hp()
	_refresh_mana()


# ── 数值（伤害/暴击/格挡/速度的唯一口径）──
# 所有随机判定都走 Global.get_chance_success()，它会推进全局随机数序列——
# 也就是说"多打一次暴击判定"会间接影响之后掉落/抽卡的随机结果（不是 bug，但调平衡时会困惑）。

## 普攻伤害：返回 maxf(1.0, stats.damage)（1 点下限，防"打不动"死局）。纯函数，不碰随机数。
## 现状没有攻防差/随机浮动/等级修正；想做浮动就改成 stats.damage * randf_range(0.9, 1.1)。
func roll_damage() -> float:
	return maxf(1.0, stats.damage)


## 是否暴击。crit_bonus 为技能加成（普攻用默认 0.0）。副作用：**推进全局随机数序列**。
## 公式：10% + stats.crit_rate/100 + crit_bonus。注意 crit_rate 是百分数、这里按小数算（0.10 = 10%）。
func roll_crit(crit_bonus := 0.0) -> bool:
	return Global.get_chance_success(0.10 + stats.crit_rate / 100.0 + status_value("crit_rate") / 100.0 + crit_bonus)


## 是否格挡（格挡 = 本次完全免伤，只飘 Blocked!）。副作用：**推进全局随机数序列**。
## 公式：stats.block_chance / 100.0 —— block_chance 资源里按百分数填（15 = 15%），这里**必须除 100**。
## 坑：没填字段时默认 0.0 → 永不格挡（不是 100%）。
func try_block() -> bool:
	return Global.get_chance_success(stats.block_chance / 100.0)


## 本回合缓存的出手速度，由 Battle._next_round() 排序前调 roll_turn_speed() 写入。
## ⚠ 必须缓存：排序会反复调比较函数，若在里面调 turn_speed() 每次取新随机数，
##   "a>b"与"b>a"可能同时成立，引擎报 "bad comparison function" 且排序结果未定义。
var round_speed := 0.0


## 本次出手速度 = stats.speed + randf_range(-4.0, 4.0)（乱敏 ±4）。副作用：**推进随机数序列**。
## speed 默认 300（与像素/秒复用同字段），这里只当大小比较用；不做扰动则同速单位顺序永远固定。
func turn_speed() -> float:
	return float(stats.speed) + randf_range(-4.0, 4.0)


## 每回合开始 roll 一次并缓存，返回 roll 出的值（方便调试打印）。副作用：写 round_speed、推进随机数。
func roll_turn_speed() -> float:
	round_speed = turn_speed()
	return round_speed


## 扣血（战斗里唯一的伤害入口，普攻和技能最后都走这里）。
## 减伤：defending 时 ×0.5、下限 1.0（防御不能完全免伤）。
## 副作用：改 hp、_refresh_hp()；归零调 _die()。已死单位直接 return（防鞭尸/重复 _die()）。
func take_damage(amount: float) -> void:
	if not alive:
		return
	var final := amount
	if defending:
		final = maxf(1.0, final * 0.5)
	hp = maxf(0.0, hp - final)
	_refresh_hp()
	if hp <= 0.0:
		_die()


## 回血（治疗技能未实现，目前无人调用）。用 minf(max_hp, ...) 夹上限；死人不能靠回血复活。
## 注意传负数会变成扣血且不触发 _die()，别这么用。
func heal(amount: float) -> void:
	if not alive:
		return
	hp = minf(max_hp, hp + amount)
	_refresh_hp()


## 刷新血条并广播 hp_changed。update_bar 第二个参数是**原始数值**（血条内部 str()），不是比例。
## 不会除零：max_hp 在 setup() 里保证 >= 1。
func _refresh_hp() -> void:
	health_bar.update_bar(hp / max_hp, hp)
	hp_changed.emit(self)


## 刷新蓝条并广播 mp_changed。max_mp==0 时不更新（避免 0/0 的 NaN 写进 ProgressBar），
## 但 **mp_changed 任何情况都发**——指令菜单靠它刷新"蓝不够/冷却 N"。
func _refresh_mana() -> void:
	if max_mp > 0.0:
		mana_bar.update_bar(mp / max_mp, mp)
	mp_changed.emit(self)


## 死亡处理（hp 归零时由 take_damage() 调，不再校验 alive）。一次性、不可逆：alive/defending=false、
## 取消选中与高亮、关点选、名字变暗、淡出 0.45s 后隐藏、emit died（最后发，接收方看到的是最终状态）。
## 重要：**不 queue_free()**——Battle 的列表/顺序条/跨 await 引用还指着它，统一由 _clear_units() 释放。
func _die() -> void:
	alive = false
	defending = false
	set_selected(false)
	set_targetable(false)
	set_focused(false)
	click_area.input_pickable = false
	name_label.modulate = Color(1, 1, 1, 0.35)
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, 0.45)
	tween.tween_callback(func() -> void: visible = false)
	died.emit(self)


# ── 技能：蓝量 / 冷却 / 数值 ──
# 本脚本管"蓝够不够、在不在冷却、数值怎么算"；何时扣蓝/进冷却/打谁由 Battle 决定。
# 冷却用**回合数**而非引擎 Timer：回合制逻辑时间与真实时间无关，暂停/加速/切场景都不受影响。

## 是否有技能表（不看蓝量与冷却）。CommandMenu 用它决定"法术"按钮 disabled。
## 语义边界：有技能 ≠ 现在放得出来，能不能放看 can_use_skill()。
func has_skills() -> bool:
	return not available_skills.is_empty()


## 现在能不能放：活着 + 蓝够（**严格小于**才不够，刚好等于可以）+ 不在冷却 + **没被封法术**。
func can_use_skill(skill: SkillData) -> bool:
	if skill == null or not alive:
		return false
	if has_status("silence"):
		return false
	if mp < skill.mana_cost:
		return false
	if cooldown_left(skill) > 0:
		return false
	return true


## 剩余冷却回合数；0 表示可用（不存在的键、skill 为 null 都返回 0）。
## 用 skill.id 做键：Resource 作键按引用比较，同技能不同实例会被当不同技能。
func cooldown_left(skill: SkillData) -> int:
	if skill == null or not cooldowns.has(skill.id):
		return 0
	return cooldowns[skill.id]


## 扣蓝：mp = maxf(0.0, mp - amount)，然后 _refresh_mana()（刷蓝条 + emit mp_changed）。
## 调用方先用 can_use_skill 校验，正常不会"蓝不够还硬扣"。
func spend_mana(amount: float) -> void:
	mp = maxf(0.0, mp - amount)
	_refresh_mana()


## 让技能进冷却：cooldowns[id] = maxi(剩余, skill.cooldown)（取大值）。
## 取 max 而不是直接赋值：防止同一回合内把别人加的长冷却改短；重复施放同一技能也不会叠加。
## 副作用：**额外 emit mp_changed**——蓝没变但冷却变了，借这个信号让菜单刷新"冷却 N"文字。
func start_cooldown(skill: SkillData) -> void:
	if skill == null:
		return
	var left := cooldown_left(skill)
	cooldowns[skill.id] = maxi(left, skill.cooldown)
	mp_changed.emit(self)          # 顺便刷新技能菜单的显示


## 每回合开始调一次：所有冷却 -1，减到 <=0 的键**删除**。
## 为什么要两趟（先记 expired 再 erase）：Godot 字典不允许边遍历 keys() 边 erase。
## is_empty() 提前返回只是小优化（大多数单位大多数时候没有冷却）。
func tick_cooldowns() -> void:
	if cooldowns.is_empty():
		return
	var expired: Array[String] = []
	# 显式写 `for key: String in cooldowns.keys()` 是为了让 key 有明确类型（keys() 返回弱类型 Array）。
	for key: String in cooldowns.keys():
		cooldowns[key] = cooldowns[key] - 1
		if cooldowns[key] <= 0:
			expired.append(key)
	for key in expired:
		cooldowns.erase(key)


## 技能伤害 = maxf(1.0, skill.power × stats.damage)（固定伤害则取 flat_damage），再叠状态加成：
## `damage_pct` / `damage_spell` 按百分比放大，`spell_damage` 按点数加。纯函数，不碰随机数。
func skill_damage(skill: SkillData) -> float:
	if skill == null:
		return roll_damage()
	# 固定伤害（缥缈剑指 / 药雾弥漫）：吃固定值，不随攻击力成长。
	var base := skill.flat_damage if skill.fixed_damage else skill.power * stats.damage
	base = maxf(1.0, base)
	base *= 1.0 + (status_value("damage_pct") + status_value("damage_spell")) / 100.0
	base += status_value("spell_damage")
	return base


## 暴击倍率：基础 ×1.5，再加 `crit_damage_bonus` 状态（百分数，15 = +15%）。
func crit_multiplier() -> float:
	return 1.5 + status_value("crit_damage_bonus") / 100.0


# ── 状态（buff / 封印 / 封法术 / 持续回血）──
# 每条：{stat: String, value: float, turns: int, per_turn: float}
#   · 数值加成：damage_pct / damage_spell（百分比）、spell_damage（点数）、crit_rate（百分点）、
#     crit_damage_bonus（百分点）；
#   · 控制：seal（被封印，下次行动跳过并消耗）、silence（不能放技能）；
#   · 持续回血：hot（per_turn 是每回合回复量）。
var statuses: Array[Dictionary] = []


## 加一条状态（同种会合并：数值/每回合回复相加，回合取更长的那个）。
func add_status(stat: String, value: float, turns: int, per_turn := 0.0) -> void:
	if stat.is_empty() or turns <= 0:
		return
	for s in statuses:
		if s["stat"] == stat:
			s["value"] = float(s["value"]) + value
			s["per_turn"] = float(s["per_turn"]) + per_turn
			s["turns"] = maxi(int(s["turns"]), turns)
			return
	statuses.append({"stat": stat, "value": value, "turns": turns, "per_turn": per_turn})


## 某种状态的数值合计（没有就 0）。只读，不碰回合数。
func status_value(stat: String) -> float:
	var total := 0.0
	for s in statuses:
		if s["stat"] == stat:
			total += float(s["value"])
	return total


## 是否有某种状态。
func has_status(stat: String) -> bool:
	for s in statuses:
		if s["stat"] == stat:
			return true
	return false


## 清空全部状态（setup() 重置时用）。
func clear_statuses() -> void:
	statuses.clear()


## 回合开始：取消防御 → **判断是否被封印** → 结算持续回血 → 所有状态 -1 回合、到期的移除。
## 返回值：true = 这个单位被封印了，本次行动应该跳过（封印状态已被消耗）。
func begin_turn() -> bool:
	set_defending(false)
	var sealed := has_status("seal")
	# 持续回血（hot）：先把这一回合的回血结算掉，再递减回合。
	if alive:
		for s in statuses:
			var per := float(s["per_turn"])
			if per > 0.0:
				heal(per)
	var kept: Array[Dictionary] = []
	for s in statuses:
		s["turns"] = int(s["turns"]) - 1
		if int(s["turns"]) > 0:
			kept.append(s)
	statuses = kept
	return sealed


## 技能是否暴击：roll_crit(skill.crit_bonus)，skill 为 null 时加成按 0。副作用：推进随机数序列。
func skill_crit(skill: SkillData) -> bool:
	return roll_crit(skill.crit_bonus if skill != null else 0.0)


# ── 选中 / 目标高亮 ──
# 只做"标记 + 重算颜色"，不动任何战斗数值。

## 设置"当前行动者"高亮：写 _selected，重算色块与轮廓（我方青/敌方橙红）。不改战斗数据。
## 谁用：Battle._begin_turn() 点亮、_finish_turn()/_finish_battle() 熄灭。
func set_selected(value: bool) -> void:
	_selected = value
	_update_selection()
	_refresh_outline()


## 设置"可被选为目标"红圈。只管视觉，不影响点击能不能被接收——
## 真正决定"点了有没有用"的是 Battle 的 state 与 _targets.has(unit)。
func set_targetable(value: bool) -> void:
	_targetable = value
	_update_selection()


## 把键盘目标光标放到本单位：显示轮廓 + 头顶箭头并开启每帧浮动。死人一律不显示（尸体不顶箭头）。
## 副作用：写 _focused、开关 %Outline/%TargetArrow 的 visible 与 _process、同步轮廓的贴图/翻转。
func set_focused(value: bool) -> void:
	_focused = value
	var show_it := value and alive
	target_arrow.visible = show_it
	set_process(show_it)
	if not show_it:
		target_arrow.position.y = _arrow_base_y
	_refresh_outline()


## 底层接口：直接开关轮廓并指定颜色（不参与优先级判断）。显示时同步本体的贴图与翻转。
## 写的是自己那份 ShaderMaterial（场景里 resource_local_to_scene=true，每个单位一份，不会串色）。
func set_outline(active: bool, color: Color) -> void:
	var show_it := active and alive
	if show_it:
		outline.texture = sprite.texture
		outline.flip_h = sprite.flip_h
		var mat := outline.material as ShaderMaterial
		if mat != null:
			mat.set_shader_parameter("outline_color", color)
	outline.visible = show_it


## 轮廓的唯一真相出口：优先级 键盘光标（金+箭头）> 行动者（青/橙红）> 不显示。
## 不叠加：轮廓只有一圈，两种状态同时成立时"打谁"比"谁在行动"更重要。
func _refresh_outline() -> void:
	if _focused and alive:
		set_outline(true, OUTLINE_TARGET_COLOR)
	elif _selected and alive:
		set_outline(true, OUTLINE_ALLY_COLOR if is_player else OUTLINE_ENEMY_COLOR)
	else:
		set_outline(false, Color.WHITE)


## 每帧让头顶箭头正弦浮动（只在 set_focused(true) 期间运行）。用 _process 而非 Tween：
## Tween 要管换目标时的 kill 与重复创建，开关 _process 更简单也不易出错。
func _process(_delta: float) -> void:
	target_arrow.position.y = _arrow_base_y + sin(float(Time.get_ticks_msec()) / 260.0) * 7.0


## 按三个标记重算 %Selection 的可见性与颜色（唯一"高亮真相"出口）。
## 优先级：_targetable 红 > _selected 暖黄 > 悬停白；可见性 alive and (...)——死了永不显示（双保险）。
func _update_selection() -> void:
	selection.visible = alive and (_selected or _targetable or _hovered)
	if _targetable:
		selection.color = TARGET_COLOR
	elif _selected:
		selection.color = SELECT_COLOR
	else:
		selection.color = HOVER_COLOR


## 设置/取消防御姿态：true 时 Sprite 渐变淡蓝，false 时回纯白；到期由 Battle._begin_turn() 取消。
## 坑：这里的 modulate tween 与 play_hit()/play_cast() 收尾互相覆盖，故 play_* 收尾写 `DEFEND_TINT if defending else WHITE`。
func set_defending(value: bool) -> void:
	defending = value
	if value:
		var tween := create_tween()
		tween.tween_property(sprite, "modulate", DEFEND_TINT, 0.15)
	else:
		sprite.modulate = Color.WHITE


## 本回合的"取消防御 + 状态结算"在文件上半部分的 begin_turn() 里（和 statuses 放一起）。


# ── 表现（演出）—— 都可以换成 AnimationPlayer ──
# 所有 play_* 都是协程，返回时机就是"演出播完"，Battle 靠 await 它们保证节奏顺序。

## 普攻位移：朝目标方向冲 80px 再退回（总时长 0.12+0.04+0.16=0.32s）。不 emit 信号、不改血量。
## 方向用 global_position 相减、位移加到局部 position：仅在本单位与父节点无旋转/缩放时等价
## （本项目舞台是纯平移，安全）。坑：目标在演出中被释放则直接 return，调用方会当成演出已结束。
func play_attack(target: BattleUnit) -> void:
	if not is_instance_valid(target):
		return
	var from := position
	var dir := (target.global_position - global_position).normalized()
	var to := from + dir * 80.0
	var tween := create_tween()
	tween.tween_property(self, "position", to, 0.12)
	# tween_interval：在序列里插一段"什么都不做"的等待，让"撞上去"有顿挫感，也不与受击闪烁糊在一起。
	tween.tween_interval(0.04)
	tween.tween_property(self, "position", from, 0.16)
	await tween.finished


## 施法起手：微微涨大 + 染色（无素材时也有反馈），总时长约 0.14+0.16=0.3s。
## 先设回 WHITE 清掉上次残留的受击红/防御蓝；放大到 _base_scale*1.14 再回落；
## parallel() 让缩放与染色同时进行；收尾色 DEFEND_TINT if defending else WHITE（防御中施法保持淡蓝）。
func play_cast() -> void:
	sprite.modulate = Color.WHITE
	var tween := create_tween()
	tween.tween_property(sprite, "scale", _base_scale * 1.14, 0.14)
	tween.parallel().tween_property(sprite, "modulate", CAST_TINT, 0.14)
	tween.tween_property(sprite, "scale", _base_scale, 0.16)
	tween.parallel().tween_property(sprite, "modulate", DEFEND_TINT if defending else Color.WHITE, 0.16)
	await tween.finished


## 受击闪烁：0.05s 染红 + 0.15s 恢复，共 0.2s。不做任何数值结算（伤害在调用方已扣完）。
## 恢复色同样是 DEFEND_TINT if defending else WHITE，否则被打一下防御的视觉提示就没了。
## 注意 modulate 是乘法染色，本身是暗色贴图的单位闪红会不明显。
func play_hit() -> void:
	var tween := create_tween()
	tween.tween_property(sprite, "modulate", HIT_TINT, 0.05)
	tween.tween_property(sprite, "modulate", DEFEND_TINT if defending else Color.WHITE, 0.15)
	await tween.finished


# ── 点击 / 悬停 ──
# 三个回调都来自 %ClickArea；能收到鼠标事件的前提：Battle 开了 physics_object_picking，
# 且盖在单位上的 Control 都被设成 MOUSE_FILTER_IGNORE（见 _ignore_mouse）。

## %ClickArea 的 input_event 回调：把左键按下翻译成 clicked 信号。
## 过滤：活着 + 是 InputEventMouseButton + 左键 + pressed（不看抬起，否则一次点击发两次）。
## 不改状态、不 set_input_as_handled()，所以点击会继续传播。
func _on_click_area_input_event(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if not alive:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		clicked.emit(self)


## 鼠标移入：点亮悬停高亮 + 广播 hovered(true)；若是可选目标则把全局指针换成手型。
## 注意 _update_selection() 优先级 目标 > 选中 > 悬停，悬停到红圈上不会变回白圈。
func _on_mouse_entered() -> void:
	_hovered = true
	_update_selection()
	hovered.emit(self, true)
	if _targetable:
		Input.set_default_cursor_shape(Input.CURSOR_POINTING_HAND)


## 鼠标移出：取消悬停 + 广播 hovered(false) + 把全局默认指针还原成箭头。
## 坑：还原是无条件的（没判断当初是不是自己改成手型）；目前只有本类改指针，所以安全。
func _on_mouse_exited() -> void:
	_hovered = false
	_update_selection()
	hovered.emit(self, false)
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)
