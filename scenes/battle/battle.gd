# battle.gd —— 回合制战斗场景的总调度：排流程、连信号、拼表现。
# 进：Battle.start_battle(我方 UnitStats[], 敌方 UnitStats[])；F6 直接运行时用 DEMO_* 自造一场。
# 出：battle_ended(player_won)，经验/掉落/回地图由外部接。
# 本脚本不算伤害、不画血条；战斗期可变状态存在 BattleUnit，绝不回写共享 UnitStats。
# 流程：IDLE→INTRO→(每回合) TURN_START→[COMMAND→TARGET_SELECT]→EXECUTE→TURN_END→…→FINISHED。
# 坑：大量 await，await 后必须重判 actor/target/is_instance_valid；回合推进靠手递手，
#     任何提前 return 的分支都要走 _finish_turn() 或 _check_battle_end()，否则战斗卡死。
extends Node2D
class_name Battle

## 回合制战斗场景（梦幻西游式骨架）：状态机驱动，出手顺序每回合按 round_speed 重排。
## 直接 F6 可用 DEMO_* 起示例战斗；正式入口是 start_battle()，结束接 battle_ended。
## 扩展点：技能 .tres + _perform_skill()；伤害/暴击/格挡在 BattleUnit；敌方 AI 在 _enemy_act()。

# ── 对外信号 ──
# Battle 只发信号，不反向引用外部节点，这样 battle.tscn 可以独立 F6 运行。

## 某单位回合开始（state 已是 TURN_START，actor 已确定且存活）。预留给外部 Buff/特效/语音。
signal turn_started(unit: BattleUnit)

## 轮到我方且指令菜单已打开（state=COMMAND）。教学/自动战斗可在此替玩家做决定。
signal command_requested(unit: BattleUnit)

## 战斗出结果时发一次（此前 state=FINISHED、菜单已关、高亮已清）。
## player_won=true 我方还有人；false 我方全灭或主动逃跑。外部据此结算。
signal battle_ended(player_won: bool)

# ── 场景预加载 ──
# 用 preload：路径编译期校验，且资源常驻，避免战斗中首次攻击/施法卡 IO。

## 战斗单位场景。_spawn_team() 每次实例化一个。
const BATTLE_UNIT_SCENE := preload("res://scenes/battle/battle_unit.tscn")
## 技能飞行体场景。每次施法每个目标一个，命中爆炸后自毁。
const SKILL_PROJECTILE_SCENE := preload("res://scenes/effects/projectile/skill_projectile.tscn")
## 默认命中爆炸（程序化四层）；群体技能给每个敌人补的小爆炸也用它。
const DEFAULT_BURST_EFFECT_SCENE := preload("res://scenes/effects/burst_effect.tscn")
## 群体技能里每人补的小爆炸相对 skill.burst_scale 的比例。
const AOE_TARGET_BURST_RATIO := 0.55
## 敌方每回合放门派技能的概率（其余回合普攻）。
## 别调太高：怪物全员每回合甩技能，会显得玩家"人多也没优势"。
const ENEMY_SKILL_CHANCE := 0.7

# ── 演示队伍（只用于直接 F6 运行本场景）──
# const 装不了 Resource，只存路径，由 _load_demo() 现场 load()。
const DEMO_PLAYERS := [
	"res://resources/units/players/燕如意.tres",
	"res://resources/units/players/行修.tres",
	"res://resources/units/players/厉狂澜.tres",
	"res://resources/units/players/霓裳.tres",
	"res://resources/units/players/陆孤鸣.tres"

]
# 敌方演示队伍：与 DEMO_PLAYERS 一一对应，站 Stage/EnemySlots 的 Marker2D。
const DEMO_ENEMIES := [
	"res://resources/units/enemies/虾精.tres",
	"res://resources/units/enemies/蟹怪.tres",
	"res://resources/units/enemies/草丛毒蜂.tres",
	"res://resources/units/enemies/偷桃毛猴.tres",
	"res://resources/units/enemies/顽石精怪.tres",
]

# ── 战斗状态机 ──
# 回调第一句用 state 做准入，丢弃 await 期间涌入的过期输入。
# IDLE 未开战 / INTRO 开场停顿 / TURN_START 回合开始 / COMMAND 等我方指令 /
# TARGET_SELECT 等选目标 / EXECUTE 演出结算中 / TURN_END 收尾 / FINISHED 已分胜负。
enum State { IDLE, INTRO, TURN_START, COMMAND, TARGET_SELECT, EXECUTE, TURN_END, FINISHED }

# ── 队伍 / 流程（编辑器里可直接配）──
# 带类型参数的数组只能写在冒号后（var x: Array[T]），等号右边写会解析报错。

## 我方队伍（检查器里拖 .tres）。默认空 = 开战时交给 start_battle()。
## auto_start_demo 且非空时优先于 DEMO_*；站位上限看 Stage/PlayerSlots 的 Marker2D（当前 5）。
@export var player_team: Array[UnitStats] = []
## 敌方队伍，语义同上（Stage/EnemySlots，当前 5）。
@export var enemy_team: Array[UnitStats] = []
## 我方 UnitStats 没配 skills 时的兜底技能，只对 is_player 生效。
@export var default_skills: Array[SkillData] = []
## 直接运行本场景（F6）时自动开演示战斗；接正式地图流程后应置 false。
@export var auto_start_demo := true      # 直接运行本场景时自动开打（编辑器里设的队伍优先）
## 每个动作之间的停顿（秒），只影响演出节奏，不影响数值（伤害在停顿前已算完）。经验范围 0.1~0.8。
@export var action_delay := 0.35         # 每个动作之间的停顿（秒）
## 群体技能逐个目标结算的间隔（秒），只在 _cast_aoe() 用；比 action_delay 小得多才有"同时被炸"的观感。
@export var aoe_step_delay := 0.06       # 群体技能里每个目标结算的间隔（秒）

# ── 视觉：飘字配色 ──
# 只用于 create_floating_text() 的 modulate，与 SkillData.tint（飞行体/爆炸染色）无关。
@export_group("飘字颜色")
## 普通伤害：近纯白略偏暖，避免纯白在亮背景上"发死"。
@export var normal_color := Color(1.0, 0.28, 0.24)
## 暴击伤害：金黄，与普通白形成强对比。
@export var critical_color := Color(1.0, 0.38, 0.30)
## 格挡/防御提示：橙红，表示"这一下被卸掉了、不疼"。
@export var block_color := Color(1.0, 0.55, 0.35)
## 治疗数字：绿色（治疗技能未实现，先备着）。
@export var heal_color := Color(0.40, 0.90, 0.55)

# ── 节点引用 ──
# @onready 在 _ready() 体之前赋值：_init/成员初始化里访问是 null；节点 free 后跨 await 用前要 is_instance_valid()。
# %Name 走 unique_name_in_owner，挪位改名不失效；$Path 会失效。

## 我方站位容器，子节点是 Marker2D（改站位只挪 Marker，不用改代码）。
@onready var player_slots: Node2D = %PlayerSlots
## 敌方站位容器，语义同上。
@onready var enemy_slots: Node2D = %EnemySlots
## 所有 BattleUnit 的父节点；挂在 2D 舞台层才能被 Camera2D 抖动带着晃。
@onready var units_root: Node2D = %Units
## 一次性特效父节点（飘字、飞行体），是 Stage 最后一个子节点，绘制永远盖住单位。
@onready var fx_root: Node2D = %Fx
## 舞台镜头；_shake_camera() 临时改 position 再复位（抖的是镜头，不是节点坐标）。
@onready var camera: Camera2D = $Camera2D
## 左侧出手顺序条，只调 update_order()/set_current()/clear_current()。
@onready var turn_order: TurnOrder = $UI/TurnOrder
## 指令菜单；_ready() 里连它的两个信号，绝不反向让它引用 Battle。
@onready var command_menu: CommandMenu = $UI/CommandMenu
## 信息栏（伤害播报、状态提示），空字符串表示不显示。
@onready var info_label: Label = $UI/InfoLabel
## 施放提示条的三段（名字 / "施放" / 技能名），各自单独上色。
@onready var cast_name: Label = %CastName
@onready var cast_verb: Label = $UI/CastBar/CastVerb
@onready var cast_skill: Label = %CastSkill
@onready var cast_bar: HBoxContainer = $UI/CastBar
## 地图截图当背景：Backdrop 是独立 CanvasLayer（layer = -1，画在所有单位和 UI 下面），
## Photo 铺满屏幕（cover 裁剪），Dim 是压暗蒙层；没截图时整个 Backdrop 隐藏，用场景自带绿底。
@onready var backdrop: CanvasLayer = %Backdrop
@onready var photo_rect: TextureRect = %Photo
@onready var dim_rect: ColorRect = %Dim
## 场景自带绿底（没截图时用；有截图时隐藏）。
@onready var background: Sprite2D = $Background
## 由 GameRoot.enter_battle() 在 add_child 之前塞进来的地图截图。
var _backdrop_photo: Texture2D = null


## 设置战斗背景照片（地图截图）；null = 用场景自带的绿底。
func set_backdrop(texture: Texture2D) -> void:
	_backdrop_photo = texture


## 把截图铺上去并压暗；没截图就藏掉整层、露出绿底。
func _apply_backdrop() -> void:
	var has_photo := _backdrop_photo != null
	if backdrop != null:
		backdrop.visible = has_photo
	if background != null:
		background.visible = not has_photo
	if has_photo:
		photo_rect.texture = _backdrop_photo

# ── 运行时状态（全部由流程函数维护，外部不要直接改）──

## 当前状态机状态，取值见 enum State；几乎所有回调第一句都拿它做准入判断。
var state := State.IDLE
## 当前出手单位。_finish_turn() 会清空、_begin_turn() 会换人，await 后再读很可能已不是原来那个。
var actor: BattleUnit
## 本回合出手队列，_next_round() 填好；中途死掉的会在 _begin_turn() 里被检测并跳过。
var turn_queue: Array[BattleUnit] = []
## turn_queue 游标，_finish_turn() 里 +1；超过队列长度说明本回合走完。
var turn_index := 0
## 回合计数，从 1 开始；显示完"第 N 回合"后自增。
var round_count := 0

# 双方成员：保存本场生成过的全部单位，含已阵亡（死后只是 alive=false + 淡出，节点还在）。
# 需要"活人"的地方必须过一遍 _alive() 过滤，不要直接用这两个数组。
var _players: Array[BattleUnit] = []
var _enemies: Array[BattleUnit] = []
## 当前高亮、等待玩家点选的候选目标（只会是敌人）；_begin_target_select() 填，_highlight_targets() 清。
var _targets: Array[BattleUnit] = []
## 键盘目标光标在 _targets 里的下标；鼠标点击/悬停会同步它，两套操作共用同一个"当前目标"。
var _target_index := 0
var _pending_skill: SkillData = null      # 已经选了技能、正在等玩家点目标


# ── 生命周期 ──

## 生命周期入口（引擎调用一次）：打开物理点选、连菜单信号、按 auto_start_demo 开战。
## 注意 start_battle() 内有 await，_ready() 不会等战斗跑完就返回；本类父级是 Node2D，无需 super._ready()。
func _ready() -> void:
	# Area2D 的 input_event 需要物理点选，否则"点敌人选目标"会彻底失灵。
	get_viewport().physics_object_picking = true
	_apply_backdrop()
	# 菜单只负责显示 + 发信号，具体做什么由 Battle 决定。
	command_menu.command_selected.connect(_on_command_selected)
	command_menu.skill_selected.connect(_on_skill_selected)

	if auto_start_demo:
		# 优先级：检查器里配置的队伍 > DEMO_* 示例路径。
		var players := player_team if not player_team.is_empty() else _load_demo(DEMO_PLAYERS)
		var enemies := enemy_team if not enemy_team.is_empty() else _load_demo(DEMO_ENEMIES)
		start_battle(players, enemies)


## 把资源路径解析成 UnitStats 数组（只服务演示流程）。
## 返回：成功解析的列表，失败的跳过并 push_warning；用 load() 所以路径写错只在运行时报，编辑器查不出。
func _load_demo(paths: Array) -> Array[UnitStats]:
	var out: Array[UnitStats] = []
	for path in paths:
		var res := load(path)
		if res is UnitStats:
			out.append(res)
		else:
			push_warning("Battle: 载入失败或类型不对 -> %s" % path)
	return out


# ── 开战 ──

## 开战：清场 → 生成双方单位 → 播 0.6s 开场停顿 → 进第一回合（协程，调用方不 await 也能工作）。
## 副作用很重：queue_free 旧单位、关菜单、清顺序条、重建 _players/_enemies、改写 state/round_count。
## 任一方为空：push_warning 后回到 IDLE 直接 return，**不发** battle_ended（外部接不到失败通知）。
func start_battle(players: Array[UnitStats], enemies: Array[UnitStats]) -> void:
	# 先清干净上一场的残留（重开战斗、编辑器里连点两次都会走到这里）。
	_clear_units()
	command_menu.close()
	turn_order.update_order([])
	state = State.INTRO
	round_count = 1

	# 参数名与成员变量靠下划线区分（players/enemies vs _players/_enemies），别弄混。
	_players = _spawn_team(players, player_slots, true)
	_enemies = _spawn_team(enemies, enemy_slots, false)

	if _players.is_empty() or _enemies.is_empty():
		# 空数组、全 null、或一个站位 Marker2D 都没有 → 放弃开战。
		push_warning("Battle: 有一方队伍是空的，检查 player_team / enemy_team 或传进来的参数")
		state = State.IDLE
		return

	info_label.text = ""
	# 乱敏**整场只掷一次**：在开战这一刻给每个单位定下 band，之后每回合都按这个值排序。
	# 早期是每回合重掷（±4），而全员速度都在 9~11 —— 波动比速度差还大，
	# 于是会出现"上回合最后一个出手、下回合第一个出手"= 看起来连续行动两次。
	for unit in _all_units():
		unit.roll_turn_speed()
	turn_order.update_order(_alive(_all_units()))
	# 开场停顿；计时器由 SceneTree 持有并自行回收，只等 timeout 即可。
	await get_tree().create_timer(0.6).timeout
	_next_round()


## 按站位把一队 UnitStats 实例化成 BattleUnit。
## 返回：成功生成的单位数组（顺序对应 stats_list 前 N 个）；站位不够时多出来的人不生成并 push_warning。
## 坑：必须 add_child() 之后才能 setup()——setup() 会摸 sprite/血条/名字这些 @onready，没进树时是 null。
func _spawn_team(stats_list: Array[UnitStats], slots_root: Node2D, is_player: bool) -> Array[BattleUnit]:
	var result: Array[BattleUnit] = []
	var slots := slots_root.get_children()
	# 人数与站位数取小，避免越界访问 slots[i]。
	var count: int = mini(stats_list.size(), slots.size())
	if stats_list.size() > slots.size():
		push_warning("Battle: %s 的站位不够（%d 个队伍 / %d 个 Marker2D）" % [slots_root.name, stats_list.size(), slots.size()])

	for i in count:
		# 队伍数组允许留空位（null），"3 人队"也能站到第 1/3/4 号位。
		if stats_list[i] == null:
			continue
		var unit := BATTLE_UNIT_SCENE.instantiate() as BattleUnit
		units_root.add_child(unit)
		unit.setup(stats_list[i], is_player)          # 必须在 add_child 之后
		# 技能表由 Battle 注入，BattleUnit 不认识 default_skills。
		unit.available_skills = _skills_for(unit, is_player)
		# 用 global_position：站位 Marker 相对 Stage，单位挂在 Stage/Units 下，父节点不同。
		unit.global_position = (slots[i] as Node2D).global_position
		unit.clicked.connect(_on_unit_clicked)
		# 悬停用来同步键盘光标。
		unit.hovered.connect(_on_unit_hovered)
		unit.died.connect(_on_unit_died)
		result.append(unit)
	return result


## 清空场上所有单位，并复位双方列表、目标列表、当前出手者、待选技能。
## 坑：queue_free 是延迟到帧末释放，所以函数返回后节点仍短暂存在；这里必须用 unit.queue_free()
##   而不是 owner.queue_free()——运行时 add_child 进来的节点 owner 是 null。
func _clear_units() -> void:
	for unit in _all_units():
		# 防御性检查：节点可能已被别处释放。
		if is_instance_valid(unit):
			unit.queue_free()
	_players.clear()
	_enemies.clear()
	_targets.clear()
	actor = null
	_pending_skill = null


# ── 回合流程 ──

## 开新回合：判胜负 → 刷冷却 → 按速度重排 → 刷 UI → 进第一个人的回合（协程，末尾 await 0.3s）。
## 副作用：改写 turn_queue/turn_index/round_count/info_label，对全体存活单位调 tick_cooldowns()。
## 坑：没有重入保护；两个 _next_round 叠在一起会让回合双倍推进。
func _next_round() -> void:
	if _check_battle_end():
		return
	# 只把"这一刻还活着"的单位放进出手队列。
	turn_queue = _alive(_all_units())
	# 每回合开始只刷冷却；出手速度在 start_battle() 里已经掷定，这里**不再重掷**（顺序整场固定）。
	for unit in turn_queue:
		unit.tick_cooldowns()                        # 每回合开始时刷新技能冷却
	# 比较函数只读缓存的 round_speed：若在里面调 turn_speed()，每次比较都取新随机数，
	# 比较结果自相矛盾，引擎会报 "bad comparison function" 且排序结果未定义。
	turn_queue.sort_custom(func(a: BattleUnit, b: BattleUnit) -> bool:
		return a.round_speed > b.round_speed)
	turn_index = 0
	turn_order.update_order(turn_queue)
	_set_round(round_count)
	round_count += 1
	await get_tree().create_timer(0.3).timeout
	_begin_turn()


## 出手顺序条要显示的是**轮转队列**：当前出手者排最前，已经出过手的都排到队尾
## （即"出完手回到队末尾"）。这里只做纯旋转，不动 turn_queue 本身的排序和游标。
## 阵亡/已释放的单位直接从条上剔除（死了就不该再排位）。
func _turn_display() -> Array:
	if turn_queue.is_empty():
		return []
	var n := turn_queue.size()
	var i := clampi(turn_index, 0, n - 1)
	var out: Array = []
	for k in n:
		var u: BattleUnit = turn_queue[(i + k) % n]
		if u == null or not is_instance_valid(u) or not u.alive:
			continue
		out.append(u)
	return out


## 进入 turn_queue[turn_index] 的回合；敌方顺带跑完 AI。整个流程主要停在这里等输入。
## 副作用：改写 actor/state/turn_index/info_label；emit turn_started（我方还 emit command_requested）。
## 跳过阵亡/空位用自调用而非 while（队伍只有个位数，优先可读性）；队列走完交给 _next_round()。
func _begin_turn() -> void:
	if _check_battle_end():
		return

	# 队列走完 = 本回合结束；小停顿让"回合切换"看得出来。
	if turn_index >= turn_queue.size():
		await get_tree().create_timer(0.25).timeout
		_next_round()
		return

	actor = turn_queue[turn_index]
	# 排序之后才死的单位在这里跳过；actor 也可能是已释放对象。
	if actor == null or not actor.alive:
		turn_index += 1
		_begin_turn()
		return

	# 自己的回合开始：取消上次的防御姿态、结算状态（持续回血 / 状态回合递减）。
	# 返回值 true = 被封印：跳过一次行动（直接把游标推到下一个人）。
	var sealed := actor.begin_turn()
	if sealed:
		actor.set_selected(true)
		state = State.TURN_START
		turn_order.update_turn(_turn_display(), actor)
		create_floating_text(actor, "封印", block_color)
		await get_tree().create_timer(0.45).timeout
		actor.set_selected(false)
		turn_index += 1
		_begin_turn()
		return

	# 点亮行动者轮廓：我方青 / 敌方橙红（见 BattleUnit.OUTLINE_*）。
	actor.set_selected(true)
	state = State.TURN_START
	turn_order.update_turn(_turn_display(), actor)
	turn_started.emit(actor)
	# 不再播报"某某的回合"：当前出手者已在顺序条第一格高亮，信息栏留给伤害/状态播报。
	info_label.text = ""
	await get_tree().create_timer(0.15).timeout

	if actor.is_player:
		# 我方：开菜单 + 发信号，然后什么都不做，等 CommandMenu.command_selected 接手。
		state = State.COMMAND
		command_menu.open_for(actor)
		command_requested.emit(actor)
	else:
		# 敌方：多等 0.4s 做"思考感"；await 确保整段演出（含伤害结算）跑完再进下一个人。
		await get_tree().create_timer(0.4).timeout
		await _enemy_act()


## 收尾一个单位的回合：清状态 → 游标 +1 → 立刻进下一个（非协程，调用方不必 await）。
## 副作用：state=TURN_END；actor、_pending_skill 清空（这就是"await 后 actor 已换人"的根源）。
## 坑：turn_index 只在这里推进，任何分支漏调都会导致战斗卡死。
func _finish_turn() -> void:
	state = State.TURN_END
	# 熄灭轮廓要在 actor 置 null 之前做，否则找不到它。
	if actor != null and is_instance_valid(actor):
		actor.set_selected(false)
	actor = null
	_pending_skill = null
	turn_index += 1
	_begin_turn()


## 敌方 AI：从存活我方里随机挑一个，走一次普通攻击（无技能、无残血优先、无集火）。
## 目标为空说明我方全灭：只判一次胜负就返回，**不**调 _finish_turn()——_check_battle_end() 会结束流程。
func _enemy_act() -> void:
	var targets := _alive(_players)
	if targets.is_empty():
		_check_battle_end()
		return
	# 每只怪开战时会随机进一个门派（GameRoot._make_enemy_team），这里按概率放它的门派招式；
	# 没蓝/在冷却/掷骰没中就普攻。_perform_skill 内部会处理扣蓝、冷却、群体演出和收尾回合。
	var skill := _pick_enemy_skill()
	if skill != null:
		await _perform_skill(actor, skill, _enemy_skill_targets(skill, targets))
		return
	# TODO: 更聪明的 AI（优先残血、优先给己方加血/护盾）在这里替换
	await _perform_attack(actor, targets[randi() % targets.size()])


## 敌方 AI 挑一个本回合能放的门派技能；null = 这回合普攻。
func _pick_enemy_skill() -> SkillData:
	if actor == null or actor.stats == null:
		return null
	var usable: Array[SkillData] = []
	for s in actor.available_skills:
		if s != null and actor.can_use_skill(s):
			usable.append(s)
	if usable.is_empty() or randf() > ENEMY_SKILL_CHANCE:
		return null
	return usable[randi() % usable.size()]


## 从**敌方视角**给技能选目标：ENEMY_* 打我方，SELF / ALLY_SINGLE 落在敌方自己人身上。
func _enemy_skill_targets(skill: SkillData, foes: Array[BattleUnit]) -> Array[BattleUnit]:
	var out: Array[BattleUnit] = []
	match skill.target_mode:
		SkillData.TargetMode.SELF:
			out.append(actor)
		SkillData.TargetMode.ALLY_SINGLE:
			var allies := _alive(_enemies)
			if not allies.is_empty():
				out.append(allies[randi() % allies.size()])
		SkillData.TargetMode.ENEMY_ALL:
			out.assign(foes)
		_:
			out.append(foes[randi() % foes.size()])
	return out


# ── 指令 → 目标 → 结算 ──

## 指令菜单回调（CommandMenu.command_selected）。command 取值：&"attack"/&"defend"/&"flee"/&"skill"/&"item"。
## 准入：state 不是 COMMAND 直接丢弃——await 期间玩家可能连点，靠它挡过期输入。
## 任何彻底结束本回合的分支都必须走到 _finish_turn()，否则战斗不会继续。
func _on_command_selected(command: StringName) -> void:
	if state != State.COMMAND or actor == null:
		return
	command_menu.close()

	match command:
		&"attack":
			# 普攻不在这里结算，先切到选目标；_pending_skill 为 null 就是"这次是普攻"的标记。
			_begin_target_select()

		&"defend":
			# 防御立刻生效（伤害 ×0.5、下限 1，见 BattleUnit.take_damage）；await 前把该做的做完。
			actor.set_defending(true)
			create_floating_text(actor, "防御", block_color)
			await get_tree().create_timer(action_delay).timeout
			_finish_turn()

		&"flee":
			# TODO: 做成有成功率的逃跑（速度/等级差决定概率）；现在无条件判负。
			_finish_battle(false, "撤退")

		&"skill":
			# 法术走 CommandMenu 的二级菜单（skill_selected），不会进到这里。
			pass

		&"item":
			# TODO: 道具系统。注意是"重新打开菜单"而不是 _finish_turn()，玩家还能改选。
			info_label.text = ""
			command_menu.open_for(actor)

		_:
			# 未知指令当"放弃本次行动"，避免战斗卡住。
			_finish_turn()


## CommandMenu 里点了某个技能。准入：state=COMMAND 且技能 can_use_skill（蓝够 + 冷却归零 + 活着）。
## 蓝不够/冷却中只改 info_label 并 return（菜单不关，仍可返回重选）；ENEMY_ALL 直接全体施放，
## 单体写入 _pending_skill 进目标选择；SELF/ALLY_SINGLE 未实现，提示后重开菜单（不消耗回合）。
func _on_skill_selected(skill: SkillData) -> void:
	if state != State.COMMAND or actor == null or skill == null:
		return
	if not actor.can_use_skill(skill):
		info_label.text = ""
		return
	command_menu.close()

	match skill.target_mode:
		SkillData.TargetMode.ENEMY_ALL:
			# 群体技能不选目标；显式置 null，保证不会被误当"单体待选"。
			_pending_skill = null
			await _perform_skill(actor, skill, _alive(_enemies))
		SkillData.TargetMode.SELF:
			# 自身/全体队友的增益：不用选目标，直接结算。
			_pending_skill = null
			await _perform_skill(actor, skill, [actor])
		SkillData.TargetMode.ALLY_SINGLE:
			# 治疗/单体增益：要选一个队友，切到"选队友"模式。
			_pending_skill = skill
			_begin_ally_select(skill)
		_:
			# 剩下的是 ENEMY_SINGLE（及未来需要选目标的模式）：暂存技能，等玩家点目标。
			_pending_skill = skill
			_begin_target_select(skill)


## 进入"选队友"：和 _begin_target_select() 同构，只是候选换成存活的我方单位。
## 用于 ALLY_SINGLE（回春诀这类治疗/单体增益）。
func _begin_ally_select(skill: SkillData) -> void:
	_targets = _alive(_players if (actor != null and actor.is_player) else _enemies)
	if _targets.is_empty():
		_check_battle_end()
		return
	state = State.TARGET_SELECT
	_target_index = 0
	# 同样不写提示文案：选队友的高亮就是反馈（与选敌人保持一致）。
	info_label.text = ""
	for target in _targets:
		target.set_targetable(true)
	_refresh_target_focus()


## 进入选目标：把存活敌人标成可点选、改提示，state=TARGET_SELECT（同步函数，不 await）。
## skill 为 null 表示普攻（默认值，所以可以直接无参调用）。
## 特例：敌人已全灭时只判一次胜负并返回（_check_battle_end 会直接收口），不会进入 TARGET_SELECT。
func _begin_target_select(skill: SkillData = null) -> void:
	_targets = _alive(_enemies)
	if _targets.is_empty():
		_check_battle_end()
		return
	state = State.TARGET_SELECT
	# 键盘光标默认停在第一个敌人上；鼠标点/悬停会同步它。
	_target_index = 0
	# 不再写"选择攻击目标…"的提示文案：目标高亮 + 键盘光标本身就是反馈，信息栏留给战斗播报。
	info_label.text = ""
	for target in _targets:
		target.set_targetable(true)
	_refresh_target_focus()


## 统一取消目标高亮并清空候选列表（一次性收尾动作，不能用来重新高亮同一批目标）。
## 坑：不论 value 传什么都会 _targets.clear() 并复位光标；is_instance_valid 防目标已阵亡/释放。
func _highlight_targets(value: bool) -> void:
	for target in _targets:
		if is_instance_valid(target):
			target.set_targetable(value)
			# 收掉键盘光标外观，否则取消选目标后还会有一个单位顶着箭头。
			target.set_focused(false)
	_targets.clear()
	_target_index = 0


# ── 键盘选目标（与鼠标并存，共用同一个"当前目标"）──

## 只给键盘光标停的那个目标加轮廓 + 头顶箭头，其余候选保持红色高亮框。
## 区分两种高亮是因为候选可能有 4 个，全加轮廓+箭头就分不清"这一下打谁"。
func _refresh_target_focus() -> void:
	for i in _targets.size():
		if is_instance_valid(_targets[i]):
			_targets[i].set_focused(i == _target_index)


## 移动键盘光标（首尾循环）并刷新高亮，播一次 UI 音效；只有一个目标时直接返回（避免空转提示音）。
func _move_target_cursor(step: int) -> void:
	if _targets.size() <= 1:
		return
	_target_index = wrapi(_target_index + step, 0, _targets.size())
	_refresh_target_focus()
	SoundManager.play_sound(SoundManager.Sound.UI)


## 键盘确认当前光标目标，完全复用鼠标点击那条路径（清高亮 → 取 _pending_skill → 执行）。
func _confirm_focused_target() -> void:
	if _target_index < 0 or _target_index >= _targets.size():
		return
	var target := _targets[_target_index]
	if target != null and is_instance_valid(target):
		_on_unit_clicked(target)


## 鼠标悬停候选敌人时把键盘光标也挪过去，避免"鼠标指一个、箭头指另一个"的割裂感。
## entered=false（离开）或不在选目标阶段时忽略。
func _on_unit_hovered(unit: BattleUnit, entered: bool) -> void:
	if not entered or state != State.TARGET_SELECT:
		return
	var index := _targets.find(unit)
	if index < 0 or index == _target_index:
		return
	_target_index = index
	_refresh_target_focus()


## 玩家点了某个单位（敌我双方的 clicked 都连到这里）：TARGET_SELECT 且是合法目标 → 清高亮后走
## _perform_skill（有技能）或 _perform_attack（普攻）；其他情况只把 HP/MP 写进 info_label 当"查看"。
## 坑：先存局部 caster/skill 防 await 期间成员被换掉；_targets.has(unit) 是唯一合法性校验。
func _on_unit_clicked(unit: BattleUnit) -> void:
	if state == State.TARGET_SELECT and _targets.has(unit) and actor != null:
		var caster := actor
		var skill := _pending_skill
		_pending_skill = null
		_highlight_targets(false)
		if skill != null:
			var one: Array[BattleUnit] = [unit]     # _perform_skill 要 Array，单目标包一层
			await _perform_skill(caster, skill, one)
		else:
			await _perform_attack(caster, unit)
	else:
		# 非选目标阶段点单位：以后可以在这里弹"查看单位信息"面板。
		info_label.text = ""


## 普攻：冲过去 → 格挡 → 伤害/暴击 → 飘字/受击 → 停顿 → 判胜负或收尾回合（协程）。
## 数值口径：roll_damage() → 暴击 ×1.5 → **BattleUnit.take_damage() 内部**做防御减伤 + 格挡值固定减去，
##   返回实际扣血量，飘字用这个值（不显示未减伤的原始伤害）。坑：校验失败也必须 _finish_turn()，否则卡死。
func _perform_attack(attacker: BattleUnit, target: BattleUnit) -> void:
	# 三重校验：两个节点都有效、目标还活着。
	if not is_instance_valid(attacker) or not is_instance_valid(target) or not target.alive:
		_finish_turn()
		return

	state = State.EXECUTE
	info_label.text = ""
	# 演出分三段：① 走到目标面前 → ② 结算（飘字 + 受击闪红）→ ③ 出招并退回原位。
	# home 必须在 approach 之前记下来 —— 那之后 attacker.position 已经不是站位了。
	var home := attacker.position
	await attacker.attack_approach(target)

	var damage := attacker.roll_damage()
	var is_crit := attacker.roll_crit()
	if is_crit:
		damage = ceilf(damage * attacker.crit_multiplier())
	var dealt := target.take_damage(damage)
	# 飘字只显示整数部分（伤害是 float），避免出现 "12.000000"。
	create_floating_text(target, str(int(roundf(dealt))), critical_color if is_crit else normal_color)
	# 受击后仰与出招**并行**：它俩时长一样，串着等会把一次普攻拖成两倍。
	target.play_hit(attacker.global_position)
	# ③ 出招 → 退回原位（攻击动画完成时，受击也刚好收尾）
	await attacker.attack_finish(home)

	# 命中都要等，节奏一致观感才不忽快忽慢（还要等本轮特效播完）。
	await _wait_action_end()
	# 先判胜负：已结束就**不能**再 _finish_turn()，否则会把结束的战斗继续往下推。
	if not _check_battle_end():
		_finish_turn()


# ── 技能 ──

## 单位本场能用的技能：优先 UnitStats.skills，否则我方用 default_skills，敌方为空。
## 注意返回的是 UnitStats.skills 里那个数组对象本身（不是拷贝），只读不改，否则污染共享资源。
func _skills_for(unit: BattleUnit, is_player: bool) -> Array[SkillData]:
	var source: Array[SkillData] = []
	if unit.stats != null and not unit.stats.skills.is_empty():
		source = unit.stats.skills
	elif is_player:
		source = default_skills
	# 只把"战斗能真正执行"的技能放进菜单：增益/封印/治疗要等状态系统，先隐藏，免得点了没反应。
	var playable: Array[SkillData] = []
	for skill in source:
		if is_skill_playable(skill):
			playable.append(skill)
	return playable


## 这个技能现在能不能在战斗里真正生效。
## 伤害类：power > 0 / 固定伤害 / 带封印或封法术（太虚封天、封灵诀）；
## 辅助类（SELF / ALLY_SINGLE）：有治疗量或带 buff。
static func is_skill_playable(skill: SkillData) -> bool:
	if skill == null:
		return false
	match skill.target_mode:
		SkillData.TargetMode.ENEMY_SINGLE, SkillData.TargetMode.ENEMY_ALL:
			return skill.power > 0.0 or skill.fixed_damage \
					or skill.seal_chance > 0.0 or skill.silence_chance > 0.0
		_:
			return skill.heal_power > 0.0 or not skill.buff_stat.is_empty()


## 技能是否"有伤害"（没伤害的技能只施加状态/治疗，不飘伤害数字、不播命中特效）。
static func _skill_deals_damage(skill: SkillData) -> bool:
	return skill.power > 0.0 or skill.fixed_damage


## 伤害技能：起手 → 飞行 → 命中结算 → 收尾（协程）。扣蓝/进冷却在起手一次扣完（目标死了不退）。
## 顺序：先扣蓝进冷却再播演出；单体逐目标串行、群体交 _cast_aoe()；fly_to() 返回才结算，
##   burst() 放在结算之后。坑：victims 是循环前快照，循环内每个目标重判 alive，跳过而非 break。
## 辅助类技能（SELF / ALLY_SINGLE）走 _perform_support()。
func _perform_skill(caster: BattleUnit, skill: SkillData, targets: Array[BattleUnit]) -> void:
	if not is_instance_valid(caster) or skill == null:
		_finish_turn()
		return
	# 辅助技能（自身/队友增益、治疗）另一条路径。
	if skill.target_mode == SkillData.TargetMode.SELF \
			or skill.target_mode == SkillData.TargetMode.ALLY_SINGLE:
		await _perform_support(caster, skill, targets)
		return
	# 只对"这一刻还活着"的目标施法；群体传进来的可能含死人。
	var victims := _alive(targets)
	if victims.is_empty():
		# 没有有效目标：先判胜负（可能刚好已经全灭），没结束才正常收尾。
		if not _check_battle_end():
			_finish_turn()
		return
	# 多目标技能（三尺青锋打 2~3 人）：**先把目标补足**。
	# 后面「全屏动画 / 受击后仰 / 群体演出」都用这同一份完整名单。
	# 补足动作原来写在 _cast_aoe 里，导致起手时 victims 只有点选的那 1 个人，
	# 于是全屏特效之后的受击后仰只歪了这一个人。
	if skill.target_mode == SkillData.TargetMode.ENEMY_SINGLE and skill.max_targets > 1:
		victims = _expand_targets(victims, skill.max_targets)

	state = State.EXECUTE
	_show_cast(caster, skill)
	caster.spend_mana(skill.mana_cost)
	caster.start_cooldown(skill)
	_play_sfx(skill.cast_sfx)
	# 本技能的一整段动画时长：受击后仰要保持这么久（三尺青锋 1.4 秒、五雷正法 1.5 秒…）
	var anim_time := _skill_anim_time(skill)
	# 近战门派技能（太虚神剑 / 星罗魔爪）：先走到目标面前再放。
	# home 必须在走之前记下来 —— 走完 caster.position 已经不是站位了。
	var home := caster.position
	var approaching := skill.melee and victims.size() == 1
	if approaching:
		await caster.attack_approach(victims[0])
	# 把"被打的那一组"传下去：敌方施法时动画要盖在我方身上，不能按技能类型猜。
	_spawn_screen_effect(skill, Vector2.INF, victims)
	# 有**全屏动画**的技能（三尺青锋 / 群星陨落 …）：受击后仰从动画起点就开始，
	# 和动画同进同出。放在这里而不是 _cast_aoe 的结算循环里 ——
	# 那条路要先等弹体飞完（0.5~1 秒），后仰会晚到动画快结束才出现。
	if skill.screen_effect_scene != null:
		for t in victims:
			if is_instance_valid(t):
				t.play_hit(caster.global_position, anim_time)
	await caster.play_cast()

	# 多目标（max_targets > 1）或全体技能：走**群体演出**——
	# 只生成一颗弹体、只播一次大特效，然后所有目标同时结算（雷动九天就是这条路径）。
	# 之前 max_targets 走单体循环，会变成"每个敌人各播一遍"，观感像连放 3 次技能。
	if skill.target_mode == SkillData.TargetMode.ENEMY_ALL:
		await _cast_aoe(caster, skill, victims, anim_time)
		if not _check_battle_end():
			_finish_turn()
		return
	if skill.target_mode == SkillData.TargetMode.ENEMY_SINGLE and skill.max_targets > 1:
		await _cast_aoe(caster, skill, victims, anim_time)
		if not _check_battle_end():
			_finish_turn()
		return

	for target in victims:
		# 串行演出期间目标可能已死/被释放：跳过而不是 break，后面的目标仍然该被打到。
		if not is_instance_valid(target) or not target.alive:
			continue

		# 无弹道技能（instant_hit）：不飞弹体，招式直接落在目标身上（五雷正法：天降雷柱）。
		# 弹体变量先置空，命中段按 instant_hit 分流。
		var projectile: SkillProjectile = null
		if not skill.instant_hit:
			projectile = SKILL_PROJECTILE_SCENE.instantiate() as SkillProjectile
			fx_root.add_child(projectile)
			# 起点/落点都用 body_center()（脚在原点，往上抬半个身高）——敌我可能挂在不同的父节点下。
			projectile.setup(skill, caster.body_center())
			# await 到飞体抵达目标坐标那一刻再结算。
			await projectile.fly_to(target.body_center())

		# 连击（hits > 1）：同一个飞体命中后连续结算 N 次。
		var times := maxi(1, skill.hits)
		for hit in times:
			if not is_instance_valid(target) or not target.alive:
				break
			# ① 先把这一击的动画放出去（多段技能各自一段）。
			#    顺序很重要：动画 → 等它播完 → 再跳伤害数字，就是打完才出伤害。
			var seg_fx: Node = null
			if skill.hit_effect_per_hit:
				seg_fx = _spawn_per_hit_effect(skill, target, hit, caster.global_position)
			var seg_waits: bool = seg_fx != null and is_instance_valid(seg_fx) \
					and seg_fx.has_signal("finished")
			# 受击后仰**从动画开始就保持**，一直持续到这一段播完（不后退）。
			# 时长取这一段序列帧的长度；没有 duration() 的（程序化特效）退回默认值。
			var hold := anim_time
			if seg_fx != null and seg_fx.has_method("duration"):
				hold = float(seg_fx.call("duration"))   # 多段技能按"这一段"算
			target.play_hit(caster.global_position, hold)
			# ② 结算（没有伤害的技能只走状态，不飘伤害数字）
			if _skill_deals_damage(skill):
				# 伤害 = skill_damage()（power×攻击力 / 固定值 + 状态加成），暴击再乘 crit_multiplier()；
				# 防御减伤与格挡值在 take_damage() 内部结算，返回实际扣血量。
				var damage := caster.skill_damage(skill, hit)
				var is_crit := caster.skill_crit(skill)
				if is_crit:
					damage = ceilf(damage * caster.crit_multiplier())
				var dealt := target.take_damage(damage, skill.damage_type == SkillData.DamageType.MAGIC)
				# ③ 等这一段动画播完再跳数字
				if seg_waits:
					await seg_fx.finished
				create_floating_text(target, str(int(roundf(dealt))), critical_color if is_crit else normal_color)
			elif seg_waits:
				await seg_fx.finished
			_apply_skill_statuses(caster, skill, target)
			# 段与段之间留一点呼吸（动画本身已经占时，这里只要一点点）
			if hit < times - 1:
				await get_tree().create_timer(maxf(0.02, skill.hit_interval)).timeout

		# 命中爆点：无弹道技能直接在目标位置放一份（逐击放过特效的就别重复放）；
		# 有弹道的走 burst()（内部会 queue_free 飞体本身，之后不能再碰 projectile）。
		if skill.instant_hit:
			if not skill.hit_effect_per_hit:
				var instant_pos: Vector2 = target.global_position if skill.hit_effect_on_ground \
						else target.body_center()
				_spawn_instant_burst(skill, instant_pos, caster.body_center())
		elif projectile != null:
			# 贴地类特效（地面法阵）压到目标脚下再爆。
			if skill.hit_effect_on_ground:
				projectile.global_position = Vector2(target.global_position.x, target.global_position.y)
			# 逐击放过特效的，就别再放一次总爆点了（会多出一段重叠）
			projectile.burst(skill.hit_effect_per_hit)
		_play_sfx(skill.hit_sfx)
		# screen_shake 为 0 表示不抖镜头。
		if skill.screen_shake > 0.0:
			_shake_camera(skill.screen_shake)
		# 每个目标之间也留一个 action_delay，并且等这一段的特效播完。
		await _wait_action_end()

	# 近战技能：打完退回原位（不播 attack 动作，招式本身的特效已经演完了）
	if approaching:
		await caster.attack_return(home)

	# 先判胜负，没结束才收尾回合。
	if not _check_battle_end():
		_finish_turn()


## 群体演出（ENEMY_ALL，或多目标技能 ENEMY_SINGLE + max_targets > 1）：
## 一颗飞行体飞目标阵型中心 → **只播一次**大特效 → 按 aoe_step_delay 逐个结算（间隔极短 = 同时受击）。
## 蓝/冷却不在这里扣（_perform_skill 起手已扣）；hit_sfx 与镜头抖动只做一次；命中者再补一朵小爆炸，
## 中心爆炸先于伤害结算。坑：循环内重判有效/存活（不要 break）；play_hit() 故意不 await，要同时闪红。
func _cast_aoe(caster: BattleUnit, skill: SkillData, victims: Array[BattleUnit],
		hold := 0.35) -> void:
	var center := _group_center(victims)

	# ① 一颗飞行体飞向敌阵中心（序列帧/粒子来自 SkillData）
	var projectile: SkillProjectile = SKILL_PROJECTILE_SCENE.instantiate() as SkillProjectile
	fx_root.add_child(projectile)
	projectile.setup(skill, caster.body_center())
	await projectile.fly_to(center)

	# ② 中心大爆炸：burst() 内部读 skill.hit_effect_scene / burst_scale，并自毁
	# 贴地类特效（雷动九天）把落点压到敌人脚下的地面线，否则地面法阵会浮在半空。
	# hit_effect_center = false 时中心不炸（群星陨落只在每个目标脚下各落一颗陨星）。
	if skill.hit_effect_on_ground:
		projectile.global_position = Vector2(center.x, _group_ground_y(victims))
	projectile.burst(not skill.hit_effect_center)
	_play_sfx(skill.hit_sfx)
	if skill.screen_shake > 0.0:
		_shake_camera(skill.screen_shake)

	# ③ 逐个结算（间隔很短，观感是"同时被炸到"）
	for target in victims:
		if not is_instance_valid(target) or not target.alive:
			continue

		if _skill_deals_damage(skill):
			var damage := caster.skill_damage(skill)
			var is_crit := caster.skill_crit(skill)
			if is_crit:
				damage = ceilf(damage * caster.crit_multiplier())
			var dealt := target.take_damage(damage, skill.damage_type == SkillData.DamageType.MAGIC)
			create_floating_text(target, str(int(roundf(dealt))), critical_color if is_crit else normal_color)
			# 中心那朵盖不到斜排角落，所以每个敌人身上再补一朵小的。
			# 贴地技能（群星陨落）把这份"小爆点"放到目标脚下的地面线上。
			var burst_pos: Vector2 = target.global_position if skill.hit_effect_on_ground \
					else target.body_center()
			# 逐目标小爆点：只有"本来就配了逐目标特效"或显式打开逐目标开关的技能才放。
			# 为什么加这个判断：只靠全屏序列帧动画的技能（群星陨落/雷动九天/缥缈剑指/药雾弥漫）
			# 如果这里再补一发兜底的程序化爆炸，看起来就是"素材动画之后又冒出一段不是素材的东西"。
			if skill.hit_effect_per_target or skill.target_effect_scene != null:
				# 专属的 target_effect_scene 给足尺寸（不乘 0.55 的小爆比例）
				var ratio := 1.0 if skill.target_effect_scene != null else AOE_TARGET_BURST_RATIO
				# 传入施法者位置：陨石等特效据此决定"从哪边斜插过来"
				_spawn_hit_burst(skill, burst_pos, ratio, caster.body_center())
			# 后仰：有全屏动画的技能已经在起手时统一后仰过了（见 _perform_skill），
			# 这里只补"没有全屏动画"的（比如只靠逐目标特效的群体技能）。
			if skill.screen_effect_scene == null:
				target.play_hit(caster.global_position, hold)   # 故意不 await：要的是"同时闪红"
		_apply_skill_statuses(caster, skill, target)
		await get_tree().create_timer(aoe_step_delay).timeout

	await _wait_action_end()


## 技能附带的状态：封印（下回合跳过）/ 封法术（N 回合不能放技能）。
## 参数 caster/target 都是 BattleUnit；概率在 SkillData 里（0~1）。
## 只在目标还活着时判定；命中飘一条彩色文字提示。
func _apply_skill_statuses(caster: BattleUnit, skill: SkillData, target: BattleUnit) -> void:
	if not is_instance_valid(target) or not target.alive:
		return
	if skill.seal_chance > 0.0 and Global.get_chance_success(skill.seal_chance):
		target.add_status("seal", 0.0, 1)
		create_floating_text(target, "封印", block_color)
	if skill.silence_chance > 0.0 and Global.get_chance_success(skill.silence_chance):
		target.add_status("silence", 0.0, maxi(1, skill.silence_turns))
		create_floating_text(target, "封法", block_color)


## 辅助技能（SELF / ALLY_SINGLE）：治疗 + 持续回血 + 增益状态。
## SELF：作用于自己；buff_all_allies = true 时作用于全体存活队友。
## ALLY_SINGLE：作用于选中的队友，max_targets > 1 时自动补最近的几个队友。
## 蓝/冷却在起手扣一次（和伤害技能一致）。
func _perform_support(caster: BattleUnit, skill: SkillData, targets: Array[BattleUnit]) -> void:
	var allies := _alive(targets)
	if skill.buff_all_allies:
		allies = _alive(_players if caster.is_player else _enemies)
	elif skill.target_mode == SkillData.TargetMode.ALLY_SINGLE and skill.max_targets > 1:
		allies = _expand_allies(allies, skill.max_targets)
	if allies.is_empty():
		_finish_turn()
		return

	state = State.EXECUTE
	_show_cast(caster, skill)
	caster.spend_mana(skill.mana_cost)
	caster.start_cooldown(skill)
	_play_sfx(skill.cast_sfx)
	# ⚠ 辅助/自身增益也要放 screen_effect（人剑合一就是这条路径）：
	#   以前只在"打敌人"的分支里调，导致自身 buff 的全屏特效永远不播。
	_spawn_screen_effect(skill, caster.global_position, allies)
	await caster.play_cast()

	for target in allies:
		_apply_support_to(caster, skill, target)
		# 治疗/增益也能有专属表现：每个被照顾到的队友脚下各放一份
		_spawn_support_effect(skill, target)
		await get_tree().create_timer(0.08).timeout

	await _wait_action_end()
	if not _check_battle_end():
		_finish_turn()


## 辅助技能（治疗 / 增益）的"每个目标一份"表现。
## 用 target_effect_scene，没配就退回 hit_effect_scene；两者都没有就什么都不放。
func _spawn_support_effect(skill: SkillData, target: BattleUnit) -> void:
	if skill == null or not is_instance_valid(target):
		return
	var scene: PackedScene = skill.target_effect_scene
	if scene == null:
		scene = skill.hit_effect_scene
	if scene == null:
		return
	var fx = scene.instantiate()
	fx_root.add_child(fx)
	fx.global_position = target.global_position
	fx.scale = Vector2.ONE * maxf(0.05, skill.burst_scale)
	if fx.has_method("play"):
		fx.play(skill.tint, skill.hit_particles)
	_track_fx(fx)


## 对**单个**目标结算辅助效果（治疗 / 持续回血 / 增益），顺带飘字；不推进回合、不 await。
## 抽出来是为了能单独测：_perform_support 只负责选目标、扣蓝、演出和收尾。
func _apply_support_to(caster: BattleUnit, skill: SkillData, target: BattleUnit) -> void:
	if not is_instance_valid(target) or not target.alive or not is_instance_valid(caster):
		return
	# 治疗：回复量 = 施法者 healing × heal_power
	if skill.heal_power > 0.0:
		var amount := maxf(1.0, caster.stats.healing * skill.heal_power)
		target.heal(amount)
		create_floating_text(target, "+%d" % int(roundf(amount)), heal_color)
	# 持续回血：每回合回 healing × hot_power，持续 hot_turns 回合
	if skill.hot_turns > 0 and skill.hot_power > 0.0:
		target.add_status("hot", 0.0, skill.hot_turns, maxf(1.0, caster.stats.healing * skill.hot_power))
	# 增益状态：数值 = buff_value（已在 _attach_sect_skills 里按等级烤好）
	if not skill.buff_stat.is_empty() and skill.buff_value > 0.0:
		target.add_status(skill.buff_stat, skill.buff_value, maxi(1, skill.buff_turns))
		create_floating_text(target, _buff_label(skill.buff_stat), critical_color)


## 状态名 → 头顶飘字（"暴击↑"之类）。
static func _buff_label(stat: String) -> String:
	match stat:
		"crit_rate":
			return "暴击↑"
		"crit_damage_bonus":
			return "暴伤↑"
		"spell_damage":
			return "法伤↑"
		"damage_pct":
			return "伤害↑"
		"damage_spell":
			return "攻法↑"
		"defense":
			return "防御↑"
		"seal_hit":
			return "封命中↑"
	return "状态↑"


## 把队友列表补到 count 个：以第一个（玩家选的）为锚，按距离从近到远补存活队友。
func _expand_allies(allies: Array[BattleUnit], count: int) -> Array[BattleUnit]:
	var out: Array[BattleUnit] = []
	out.assign(allies)
	if out.is_empty() or count <= 1:
		return out
	var anchor := out[0]
	var pool: Array[BattleUnit] = _alive(_players if anchor.is_player else _enemies)
	var candidates: Array[BattleUnit] = []
	for unit in pool:
		if not out.has(unit):
			candidates.append(unit)
	candidates.sort_custom(func(a: BattleUnit, b: BattleUnit) -> bool:
		return a.global_position.distance_to(anchor.global_position) \
				< b.global_position.distance_to(anchor.global_position))
	for unit in candidates:
		if out.size() >= count:
			break
		out.append(unit)
	return out


## 把目标列表补到 count 个：以第一个（玩家选的主目标）为锚，按距离从近到远补存活敌人。
## 参数 victims：已经确认的主目标列表（通常只有一个）；count：想要的总目标数。
## 返回值：新的列表（不修改传入的数组）。目标不够时就有几个给几个。
func _expand_targets(victims: Array[BattleUnit], count: int) -> Array[BattleUnit]:
	var out: Array[BattleUnit] = []
	out.assign(victims)
	if out.is_empty() or count <= 1:
		return out
	var anchor := out[0]
	# 在**被打的那一方**里补目标：原来的实现写死 _enemies，
	# 敌方放多目标技能时会把自己人一起算进去（自己打自己）。
	var pool: Array[BattleUnit] = _alive(_players) if anchor.is_player else _alive(_enemies)
	var candidates: Array[BattleUnit] = []
	for unit in pool:
		if not out.has(unit):
			candidates.append(unit)
	candidates.sort_custom(func(a: BattleUnit, b: BattleUnit) -> bool:
		return a.global_position.distance_to(anchor.global_position) \
				< b.global_position.distance_to(anchor.global_position))
	for unit in candidates:
		if out.size() >= count:
			break
		out.append(unit)
	return out


## 一组单位的世界坐标几何中心（群体技能的落点）；空列表返回 ZERO 兜底。
## 用 global_position 而非 position：敌我可能挂在不同父节点下。
func _group_center(units: Array[BattleUnit]) -> Vector2:
	var sum := Vector2.ZERO
	var count := 0
	for unit in units:
		if is_instance_valid(unit):
			sum += unit.global_position
			count += 1
	if count == 0:
		return Vector2.ZERO
	return sum / float(count)


## 一组单位"脚下地面"的 y 坐标（脚在原点，取最低的那个）。
## 贴地特效（地面法阵 / 天降落雷）要放在这里，放在身体中心就会浮在半空。
func _group_ground_y(units: Array[BattleUnit]) -> float:
	var y := -INF
	for unit in units:
		if is_instance_valid(unit):
			y = maxf(y, unit.global_position.y)
	return y if y > -INF else 0.0


## 施法瞬间放一次"全屏氛围特效"（夜色压暗 / 流星雨 / 暴雨）。
## 场景根节点通常是 CanvasLayer，所以直接挂到 Battle 根下即可（不受相机与震屏影响）。
## 参数 at：给世界坐标就摆到那里（自身增益要挂在施法者脚下）；默认 Vector2.INF = 按场景自带位置。
## 参数 targets：这一发**打的是谁**。实现了 fit_units() 的序列帧特效据此决定铺在哪一方 ——
##   ⚠ 必须看"目标是谁"而不是"技能是什么类型"：敌方放攻击技能时，动画要盖在我方身上。
func _spawn_screen_effect(skill: SkillData, at := Vector2.INF, targets: Array = []) -> void:
	if skill == null or skill.screen_effect_scene == null:
		return
	var fx = skill.screen_effect_scene.instantiate()
	add_child(fx)
	# fit_units 优先：序列帧全屏动画从该方阵型的锚点起铺、盖住整队。
	# 老的程序化全屏特效没有这个方法，走 at 分支。
	if fx.has_method("fit_units"):
		var group: Array[BattleUnit] = _alive(targets)
		if group.is_empty():
			# 没传目标（或已全灭）时按技能类型兜底，至少别铺错边。
			group = _alive(_players if _skill_targets_allies(skill) else _enemies)
		if group.is_empty():
			group = _alive(_all_units())
		if not group.is_empty():
			# 阵营直接看单位自己的标记，不看技能/施法者 —— 这样敌方放技能也一定铺对边。
			var on_player_side: bool = group[0].is_player
			fx.fit_units(group, _screen_effect_anchor(on_player_side))
			# 铺在我方阵地时把画面左右镜像：敌方放的三尺青锋该从对面扎过来，方向才不反。
			if fx.has_method("set_on_player_side"):
				fx.set_on_player_side(on_player_side)
	elif at != Vector2.INF and fx is Node2D:
		(fx as Node2D).global_position = at
	_track_fx(fx)


## 我方名字用绿色、敌方用红色（和指令菜单/血条配色一致）。
const CAST_NAME_ALLY := Color(0.5, 0.94, 0.58, 1)
const CAST_NAME_ENEMY := Color(1.0, 0.42, 0.40, 1)
## 施放提示停留时长与淡出时长（秒）。
## 只亮一会儿：一直挂着会盖住战场，而且玩家真正需要看的是"谁在放什么"这一瞬间。
const CAST_HOLD := 1.0
const CAST_FADE := 0.25

## 当前那条施放提示的计时 tween（新提示来了要先 kill 掉旧的）。
var _cast_tween: Tween


## 刷新底部的施放提示条：名字按阵营上色，技能名金色并去掉「」括号。
## 拆成三个 Label 而不是富文本：项目这套字体没有粗体字重，RichTextLabel 的 [b] 不生效，
## 而且分节点改色最直观。
func _show_cast(caster: BattleUnit, skill: SkillData) -> void:
	if cast_name == null or cast_skill == null or caster == null or skill == null:
		return
	cast_name.text = caster.stats.name
	cast_name.add_theme_color_override("font_color",
			CAST_NAME_ALLY if caster.is_player else CAST_NAME_ENEMY)
	# "施放"这两个字也在这里才填 —— 写死在场景里的话，一进战斗就会孤零零挂在屏幕下方。
	cast_verb.text = " 施放 "
	cast_skill.text = skill.display_name
	if cast_bar == null:
		return
	# 新提示顶掉旧提示的计时：先复位透明度，再重新"停 1 秒 → 淡出 → 清空"。
	if _cast_tween != null and _cast_tween.is_valid():
		_cast_tween.kill()
	cast_bar.modulate.a = 1.0
	_cast_tween = create_tween()
	_cast_tween.tween_interval(CAST_HOLD)
	_cast_tween.tween_property(cast_bar, "modulate:a", 0.0, CAST_FADE)
	_cast_tween.tween_callback(func() -> void:
		cast_name.text = ""
		cast_verb.text = ""
		cast_skill.text = ""
	)


## 刷新顶部常驻的回合数（"第 N 回合"里的 N）。
## 那个面板属于 TurnOrder（跟着头像排一起缩放），所以只转发。
func _set_round(n: int) -> void:
	turn_order.set_round(n)


## 这个技能的一整段动画有多长（秒）—— 受击后仰要保持这么久。
## 顺序：全屏特效（三尺青锋/群星陨落这类走这条）→ 命中特效 → 都没有就 0.35 兜底。
## 实现是"实例化一次问 duration() 再 free"：那些场景都很轻（根节点 + 一个 Sprite2D），
## 而且只有施法瞬间调一次，开销可以忽略。程序化特效没有 duration()，返回 0 会被跳过。
func _skill_anim_time(skill: SkillData) -> float:
	if skill == null:
		return 0.35
	for scene in [skill.screen_effect_scene, skill.hit_effect_scene, skill.target_effect_scene]:
		if scene == null:
			continue
		var inst = scene.instantiate()
		var d := 0.0
		if inst.has_method("duration"):
			d = float(inst.call("duration"))
		inst.free()
		if d > 0.0:
			return d
	return 0.35


## 这个技能是"打我方的"吗：给自己加 buff / 全体队友 / 选一个队友，都算。
func _skill_targets_allies(skill: SkillData) -> bool:
	if skill == null:
		return false
	if skill.buff_all_allies:
		return true
	return skill.target_mode == SkillData.TargetMode.SELF \
			or skill.target_mode == SkillData.TargetMode.ALLY_SINGLE


## 全屏序列帧动画的原点站位（世界坐标）：
##   打敌方 → EnemySlots/Back2（敌方后排，从后往前铺满整片敌阵）
##   打我方 → PlayerSlots/Front1（我方前排，Buff 从最前面的队友起罩住全队）
## 站位是 battle.tscn 里 Stage/{PlayerSlots,EnemySlots}/<名字> 的 Marker2D；
## 找不到就返回 INF —— fit_units() 会退回"取阵型包围盒中点"。
func _screen_effect_anchor(ally: bool) -> Vector2:
	var root: Node2D = player_slots if ally else enemy_slots
	if root == null:
		return Vector2.INF
	var marker := root.get_node_or_null("Front1" if ally else "Back2") as Node2D
	return marker.global_position if marker != null else Vector2.INF


## 在指定位置补一朵（缩小版）命中爆炸，用来表现"这个敌人也被炸到了"。
## 场景优先级：`target_effect_scene`（每个目标专属，群星陨落）→ `hit_effect_scene`（逐目标开关为真时）
## → 默认程序化爆炸；scale_ratio 相对 skill.burst_scale。
## 参数 from：施法者位置。给了就通知特效"从哪边砸过来"（实现 set_impact_direction 的特效才有方向感）。
## 坑：纯序列帧特效没有 play()，要走 SkillProjectile.play_sequence_once()，故用 has_method 而非类型判断。
func _spawn_hit_burst(skill: SkillData, pos: Vector2, scale_ratio: float,
		from := Vector2.INF) -> void:
	var scene: PackedScene = DEFAULT_BURST_EFFECT_SCENE
	if skill.target_effect_scene != null:
		scene = skill.target_effect_scene
	elif skill.hit_effect_scene != null and skill.hit_effect_per_target:
		scene = skill.hit_effect_scene
	if scene == null:
		return
	var boom = scene.instantiate()
	fx_root.add_child(boom)
	boom.global_position = pos
	boom.scale = Vector2.ONE * maxf(0.05, skill.burst_scale * scale_ratio)
	# 有方向感的特效（陨石砸落）：告诉它"从施法者那边斜插过来"
	if from != Vector2.INF and boom.has_method("set_impact_direction"):
		boom.call("set_impact_direction", pos - from)
	if boom.has_method("play"):
		@warning_ignore("integer_division")
		boom.play(skill.tint, maxi(8, skill.hit_particles / 2))
	else:
		SkillProjectile.play_sequence_once(boom)


## 无弹道技能（instant_hit）：招式直接落在目标位置 —— 实例化 hit_effect_scene 并播放。
## 优先 hit_effect_scene，没配退回默认程序化爆炸；缩放用 burst_scale（不乘群体小爆比例）。
## 参数 from：施法者位置，给实现了 set_impact_direction 的特效提供方向感（同 _spawn_hit_burst）。
func _spawn_instant_burst(skill: SkillData, pos: Vector2, from := Vector2.INF) -> void:
	var scene: PackedScene = skill.hit_effect_scene
	if scene == null:
		scene = DEFAULT_BURST_EFFECT_SCENE
	if scene == null:
		return
	var boom = scene.instantiate()
	fx_root.add_child(boom)
	boom.global_position = pos
	boom.scale = Vector2.ONE * maxf(0.05, skill.burst_scale)
	if from != Vector2.INF and boom.has_method("set_impact_direction"):
		boom.call("set_impact_direction", pos - from)
	if boom.has_method("play"):
		boom.play(skill.tint, maxi(8, skill.hit_particles))
	else:
		SkillProjectile.play_sequence_once(boom)
	_track_fx(boom)
## 约定：特效场景实现了 play_segment(index) 就播对应片段（太虚神剑三段动画），
##   否则退回 play(tint, count) —— 这样别的技能也能开这个开关而不报错。
func _spawn_per_hit_effect(skill: SkillData, target: BattleUnit, hit: int,
		source_position: Vector2 = Vector2.ZERO) -> Node:
	var scene: PackedScene = skill.hit_effect_scene
	if scene == null:
		scene = skill.target_effect_scene
	if scene == null or not is_instance_valid(target):
		return null
	var boom = scene.instantiate()
	fx_root.add_child(boom)
	var pos: Vector2 = target.global_position if skill.hit_effect_on_ground else target.body_center()
	boom.global_position = pos
	boom.scale = Vector2.ONE * maxf(0.05, skill.burst_scale)
	if boom.has_method("set_attack_direction"):
		boom.call("set_attack_direction", target.global_position - source_position)
	# 特效铺在谁身上，就按谁的阵营镜像画面（敌方放太虚神剑时方向才不会反）；
	# 必须在 play_segment 之前调 —— 它内部会按当前朝向起播。
	if boom.has_method("set_on_player_side"):
		boom.call("set_on_player_side", target.is_player)
	if boom.has_method("play_segment"):
		boom.call("play_segment", hit, skill.tint)
	elif boom.has_method("play"):
		@warning_ignore("integer_division")
		boom.play(skill.tint, maxi(8, skill.hit_particles / 2))
	else:
		SkillProjectile.play_sequence_once(boom)
	_track_fx(boom)
	return boom


# ── 特效时长追踪：让下一个行动等动画播完再开始 ──

## 本轮动作放出去的特效什么时候播完（秒，以 Time.get_ticks_msec 为基准）。
## 只有实现了 duration() 的序列帧特效才计入；程序化特效没有这个方法，等于 0（行为不变）。
var _fx_until := 0.0


## 单调时钟（秒）。用 ticks 而不是 get_unix_time —— 后者精度只有 1 秒。
func _now_sec() -> float:
	return float(Time.get_ticks_msec()) / 1000.0


## 登记一个特效的播放时长。没有 duration() 的（程序化爆炸/老特效）直接忽略。
func _track_fx(fx: Node) -> void:
	if fx == null or not is_instance_valid(fx) or not fx.has_method("duration"):
		return
	_fx_until = maxf(_fx_until, _now_sec() + float(fx.call("duration")))


## 动作收尾：先等 action_delay，再等本轮特效播完。
## 为什么必须等：技能动画有 2.5 秒，不等的话下一个人已经出手、上一段的特效还在放，
## 屏幕上会同时叠两段技能动画。
func _wait_action_end() -> void:
	await get_tree().create_timer(action_delay).timeout
	while _now_sec() < _fx_until:
		await get_tree().create_timer(0.05).timeout
	_fx_until = 0.0


## 播一个一次性音效：new AudioStreamPlayer 挂 Battle 根节点（不是 %Fx），播完自动 queue_free。
## 不走 SoundManager（那是 UI/常驻音效）；volume_db 写死 -6.0，技能音效没有独立音量字段。
func _play_sfx(stream: AudioStream) -> void:
	if stream == null:
		return
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.volume_db = -6.0
	add_child(player)
	# 用 Callable 而不是 lambda：节点释放后回调不会持有无效引用。
	player.finished.connect(player.queue_free)
	player.play()


## 抖一下镜头（纯代码，不阻塞流程，**不 await**）。amount 来自 SkillData.screen_shake。
## 实现：先记 base，4 次随机偏移各 0.04s（共 0.16s）+ 0.06s 动画回正。
## 坑：收尾必须动画回 base，否则镜头永久偏移；抖的是 Camera2D.position，若挂跟随脚本会打架。
func _shake_camera(amount: float) -> void:
	if camera == null:
		return
	var base := camera.position
	var tween := create_tween()
	for i in 4:
		tween.tween_property(camera, "position",
			base + Vector2(randf_range(-amount, amount), randf_range(-amount, amount)), 0.04)
	tween.tween_property(camera, "position", base, 0.06)


## 有单位阵亡（BattleUnit.died）时刷新出手顺序条；**不动 turn_queue/turn_index**。
## 死掉的那个会在 _begin_turn() 轮到时被跳过，所以本回合不会出现下标错位。
func _on_unit_died(_unit: BattleUnit) -> void:
	# 用轮转后的队列刷新，否则顺序条会跳回"速度排序"，和玩家看到的"出完手到队尾"对不上。
	turn_order.update_turn(_turn_display(), actor)


# ── 胜负 / 飘字 / 工具 ──

## 胜负判定。流程里被反复调用，必须幂等：返回 true = 战斗已结束（调用方立刻 return，不再推进）。
## 口径：**只看我方是否还有人活着**——我方死光算失败，敌方死光算胜利，同时死光算失败。
## 幂等靠第一句 state==FINISHED，保证 battle_ended 只发一次（重复发会让外部重复结算经验/掉落）。
func _check_battle_end() -> bool:
	if state == State.FINISHED:
		return true
	# _alive 顺带做 is_instance_valid 过滤，能处理"节点已被外部释放"。
	var players_alive := not _alive(_players).is_empty()
	var enemies_alive := not _alive(_enemies).is_empty()
	if players_alive and enemies_alive:
		return false
	# 我方还有人 = 胜；reason 只是信息栏文案。
	_finish_battle(players_alive, "胜利！" if players_alive else "战斗失败…")
	return true


## 战斗唯一收口：清干净进行中的状态后广播结果。player_won 胜负，reason 信息栏结束语。
## 顺序敏感：state=FINISHED 必须第一件事（让 await 续行在 _check_battle_end() 收敛），再清
##   actor/_pending_skill、关菜单、清高亮与顺序条、写提示，最后 emit battle_ended；不释放单位、不切场景。
func _finish_battle(player_won: bool, reason: String) -> void:
	if state == State.FINISHED:
		return
	state = State.FINISHED
	actor = null
	_pending_skill = null
	command_menu.close()
	_highlight_targets(false)
	# 收掉所有行动者轮廓。
	for unit in _all_units():
		if is_instance_valid(unit):
			unit.set_selected(false)
	turn_order.clear_current()
	info_label.text = reason
	battle_ended.emit(player_won)
	# TODO: 结算（经验 / 掉落 / 回地图）接在这里


## 在单位头顶生成飘字（伤害/Blocked!/防御），播完自毁。
## 坐标：立绘脚在原点，body_center() 是身体中心，再往上抬 30px 落到头顶附近；
## x 随机 ±18 防止连炸时飘字叠成竖线。
## 坑：必须先 add_child() 再 setup()——setup() 内部访问 @onready 的 value_label。
func create_floating_text(unit: BattleUnit, text: String, color: Color) -> void:
	var fx := Global.FLOATING_TEXT_SCENE.instantiate() as FloatingText
	fx_root.add_child(fx)
	fx.global_position = unit.body_center() + Vector2(randf_range(-18.0, 18.0), -30.0)
	fx.setup(text, color)


## 返回我方 + 敌方全部单位（含已阵亡）。是新数组，增删不影响 _players/_enemies。
## 每次新建而不缓存：成员列表随生成/清场变化，缓存容易不同步，个位数单位开销可忽略。
func _all_units() -> Array[BattleUnit]:
	var out: Array[BattleUnit] = []
	out.append_array(_players)
	out.append_array(_enemies)
	return out


## 过滤出还活着的单位（本项目唯一可靠的存活判断入口），返回新数组，不改原数组。
## 双重判断：is_instance_valid 防节点已释放（访问 .alive 会报错），unit.alive 是 hp<=0 时置的标记。
## 建队时数组可能含 null，is_instance_valid(null) 为 false，天然被滤掉。
func _alive(list: Array[BattleUnit]) -> Array[BattleUnit]:
	var out: Array[BattleUnit] = []
	for unit in list:
		if is_instance_valid(unit) and unit.alive:
			out.append(unit)
	return out


## 选目标阶段的输入兜底：ESC/右键退回指令菜单，方向键切目标，Enter/空格确认。
## 每个分支都 set_input_as_handled() 吃掉事件，否则同一个 ESC 会继续上传，一次按键关两层界面。
## 用 _unhandled_input 让 Button 先处理；坑：没判 actor 是否为 null 就 open_for(actor)（当前安全）。
func _unhandled_input(event: InputEvent) -> void:
	if state != State.TARGET_SELECT:
		return

	# 键盘操作；鼠标那条路不受影响（单位被点击照样走 _on_unit_clicked）。
	# ui_accept 在指令菜单有焦点时会被 Button 先吃掉，不会跑到这里。
	if event.is_action_pressed("ui_cancel"):
		_highlight_targets(false)
		_pending_skill = null
		state = State.COMMAND
		command_menu.open_for(actor)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("ui_left") or event.is_action_pressed("ui_up"):
		_move_target_cursor(-1)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("ui_right") or event.is_action_pressed("ui_down"):
		_move_target_cursor(1)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("ui_accept"):
		_confirm_focused_target()
		get_viewport().set_input_as_handled()
