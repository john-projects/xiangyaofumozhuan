extends Node2D
class_name Battle

## 回合制战斗场景（梦幻西游式骨架）
##
## 结构：Node2D 根（舞台 / 镜头 / 世界特效） + CanvasLayer（UI）
## 流程：Battle 用状态机驱动；出手顺序按 speed 排序，每回合重排
##
## 怎么用：
##   1) 直接 F6 运行本场景 → 用 DEMO_* 里的 .tres 起一场示例战斗，方便调表现
##   2) 从地图进战斗时调用：Battle.start_battle(我方 UnitStats 数组, 敌方 UnitStats 数组)
##   3) 结束用 battle_ended(player_won) 接结算（经验/掉落/回地图）
##
## 站位：改 Stage/PlayerSlots、Stage/EnemySlots 下的 Marker2D 即可，不用改代码
## 扩展点：
##   · 技能            → resources/skills/*.tres（数值+素材都在里面）+ _perform_skill()
##   · 道具            → _on_command_selected() 的 &"item" 分支
##   · 伤害 / 暴击 / 防御 → BattleUnit.roll_damage() / roll_crit() / try_block()
##   · 技能数值        → BattleUnit.skill_damage() / skill_crit()
##   · 敌方 AI          → _enemy_act()
##   · 动作演出         → BattleUnit.play_attack() / play_cast() / play_hit()

signal turn_started(unit: BattleUnit)
signal command_requested(unit: BattleUnit)
signal battle_ended(player_won: bool)

const BATTLE_UNIT_SCENE := preload("res://scenes/battle/battle_unit.tscn")
const SKILL_PROJECTILE_SCENE := preload("res://scenes/battle/skill_projectile.tscn")

# 直接运行场景时的示例队伍（换成你自己的 .tres 即可）
const DEMO_PLAYERS := [
	"res://resources/units/players/stats_player_knight.tres",
	"res://resources/units/players/stats_player_bunny.tres",
	"res://resources/units/players/stats_player_crazy.tres",
	"res://resources/units/players/stats_player_well_rounded.tres",

]
const DEMO_ENEMIES := [
	"res://resources/units/enemies/stats_enemy_chaser_slow.tres",
	"res://resources/units/enemies/stats_enemy_chaser_mid.tres",
	"res://resources/units/enemies/stats_enemy_chaser_fast.tres",
	"res://resources/units/enemies/stats_enemy_charger.tres",
]

enum State { IDLE, INTRO, TURN_START, COMMAND, TARGET_SELECT, EXECUTE, TURN_END, FINISHED }

@export var player_team: Array[UnitStats] = []
@export var enemy_team: Array[UnitStats] = []
## 我方单位没在自己的 UnitStats 里配 skills 时，默认给这些技能（火球术）
@export var default_skills: Array[SkillData] = []
@export var auto_start_demo := true      # 直接运行本场景时自动开打（编辑器里设的队伍优先）
@export var action_delay := 0.35         # 每个动作之间的停顿（秒）

@export_group("飘字颜色")
@export var normal_color := Color(0.98, 0.98, 0.99)
@export var critical_color := Color(1.0, 0.80, 0.35)
@export var block_color := Color(1.0, 0.55, 0.35)
@export var heal_color := Color(0.40, 0.90, 0.55)

@onready var player_slots: Node2D = %PlayerSlots
@onready var enemy_slots: Node2D = %EnemySlots
@onready var units_root: Node2D = %Units
@onready var fx_root: Node2D = %Fx
@onready var camera: Camera2D = $Camera2D
@onready var turn_order: TurnOrder = $UI/TurnOrder
@onready var command_menu: CommandMenu = $UI/CommandMenu
@onready var info_label: Label = $UI/InfoLabel

var state := State.IDLE
var actor: BattleUnit
var turn_queue: Array[BattleUnit] = []
var turn_index := 0
var round_count := 0

var _players: Array[BattleUnit] = []
var _enemies: Array[BattleUnit] = []
var _targets: Array[BattleUnit] = []
var _pending_skill: SkillData = null      # 已经选了技能、正在等玩家点目标


func _ready() -> void:
	# Area2D 的 input_event / mouse_entered 需要开启物理点选（也可以去项目设置里开）
	get_viewport().physics_object_picking = true
	command_menu.command_selected.connect(_on_command_selected)
	command_menu.skill_selected.connect(_on_skill_selected)

	if auto_start_demo:
		var players := player_team if not player_team.is_empty() else _load_demo(DEMO_PLAYERS)
		var enemies := enemy_team if not enemy_team.is_empty() else _load_demo(DEMO_ENEMIES)
		start_battle(players, enemies)


func _load_demo(paths: Array) -> Array[UnitStats]:
	var out: Array[UnitStats] = []
	for path in paths:
		var res := load(path)
		if res is UnitStats:
			out.append(res)
		else:
			push_warning("Battle: 载入失败或类型不对 -> %s" % path)
	return out


# ══════════════════════════════════════════════════════════
#  开战
# ══════════════════════════════════════════════════════════

func start_battle(players: Array[UnitStats], enemies: Array[UnitStats]) -> void:
	_clear_units()
	command_menu.close()
	turn_order.update_order([])
	state = State.INTRO
	round_count = 1

	_players = _spawn_team(players, player_slots, true)
	_enemies = _spawn_team(enemies, enemy_slots, false)

	if _players.is_empty() or _enemies.is_empty():
		push_warning("Battle: 有一方队伍是空的，检查 player_team / enemy_team 或传进来的参数")
		state = State.IDLE
		return

	info_label.text = "战斗开始"
	turn_order.update_order(_alive(_all_units()))
	await get_tree().create_timer(0.6).timeout
	_next_round()


func _spawn_team(stats_list: Array[UnitStats], slots_root: Node2D, is_player: bool) -> Array[BattleUnit]:
	var result: Array[BattleUnit] = []
	var slots := slots_root.get_children()
	var count: int = mini(stats_list.size(), slots.size())
	if stats_list.size() > slots.size():
		push_warning("Battle: %s 的站位不够（%d 个队伍 / %d 个 Marker2D）" % [slots_root.name, stats_list.size(), slots.size()])

	for i in count:
		if stats_list[i] == null:
			continue
		var unit := BATTLE_UNIT_SCENE.instantiate() as BattleUnit
		units_root.add_child(unit)
		unit.setup(stats_list[i], is_player)          # 必须在 add_child 之后
		unit.available_skills = _skills_for(unit, is_player)
		unit.global_position = (slots[i] as Node2D).global_position
		unit.clicked.connect(_on_unit_clicked)
		unit.died.connect(_on_unit_died)
		result.append(unit)
	return result


func _clear_units() -> void:
	for unit in _all_units():
		if is_instance_valid(unit):
			unit.queue_free()
	_players.clear()
	_enemies.clear()
	_targets.clear()
	actor = null
	_pending_skill = null


# ══════════════════════════════════════════════════════════
#  回合流程
# ══════════════════════════════════════════════════════════

func _next_round() -> void:
	if _check_battle_end():
		return
	turn_queue = _alive(_all_units())
	for unit in turn_queue:
		unit.tick_cooldowns()                        # 每回合开始时刷新技能冷却
	turn_queue.sort_custom(func(a: BattleUnit, b: BattleUnit) -> bool:
		return a.turn_speed() > b.turn_speed())
	turn_index = 0
	turn_order.update_order(turn_queue)
	info_label.text = "第 %d 回合" % round_count
	round_count += 1
	await get_tree().create_timer(0.3).timeout
	_begin_turn()


func _begin_turn() -> void:
	if _check_battle_end():
		return

	if turn_index >= turn_queue.size():
		await get_tree().create_timer(0.25).timeout
		_next_round()
		return

	actor = turn_queue[turn_index]
	if actor == null or not actor.alive:
		turn_index += 1
		_begin_turn()
		return

	state = State.TURN_START
	turn_order.set_current(actor)
	turn_started.emit(actor)
	info_label.text = "%s 的回合" % actor.stats.name
	await get_tree().create_timer(0.15).timeout

	if actor.is_player:
		state = State.COMMAND
		command_menu.open_for(actor)
		command_requested.emit(actor)
	else:
		await get_tree().create_timer(0.4).timeout
		await _enemy_act()


func _finish_turn() -> void:
	state = State.TURN_END
	actor = null
	_pending_skill = null
	turn_index += 1
	_begin_turn()


func _enemy_act() -> void:
	var targets := _alive(_players)
	if targets.is_empty():
		_check_battle_end()
		return
	# TODO: 更聪明的 AI（优先残血、优先给己方加血/护盾）在这里替换
	await _perform_attack(actor, targets[randi() % targets.size()])


# ══════════════════════════════════════════════════════════
#  指令 → 目标 → 结算
# ══════════════════════════════════════════════════════════

func _on_command_selected(command: StringName) -> void:
	if state != State.COMMAND or actor == null:
		return
	command_menu.close()

	match command:
		&"attack":
			_begin_target_select()

		&"defend":
			actor.set_defending(true)
			create_floating_text(actor, "防御", block_color)
			info_label.text = "%s 进入防御" % actor.stats.name
			await get_tree().create_timer(action_delay).timeout
			_finish_turn()

		&"flee":
			# TODO: 做成有成功率的逃跑（速度/等级差决定概率）
			_finish_battle(false, "撤退")

		&"skill":
			# 法术走 CommandMenu 的二级菜单（列表 → skill_selected），不会进到这里
			pass

		&"item":
			# TODO: 道具系统（二级菜单 → 选目标 → 使用）
			info_label.text = "道具系统还没做"
			command_menu.open_for(actor)

		_:
			_finish_turn()


## CommandMenu 里点了某个技能
func _on_skill_selected(skill: SkillData) -> void:
	if state != State.COMMAND or actor == null or skill == null:
		return
	if not actor.can_use_skill(skill):
		info_label.text = "%s 现在用不了（蓝不够或冷却中）" % skill.display_name
		return
	command_menu.close()

	match skill.target_mode:
		SkillData.TargetMode.ENEMY_ALL:
			_pending_skill = null
			await _perform_skill(actor, skill, _alive(_enemies))
		SkillData.TargetMode.SELF, SkillData.TargetMode.ALLY_SINGLE:
			# TODO: 治疗/增益效果（等 BattleUnit 加了 status 系统再做）
			info_label.text = "%s 的效果还没实现（先把单体伤害做好了）" % skill.display_name
			command_menu.open_for(actor)
		_:
			_pending_skill = skill
			_begin_target_select(skill)


func _begin_target_select(skill: SkillData = null) -> void:
	_targets = _alive(_enemies)
	if _targets.is_empty():
		_check_battle_end()
		return
	state = State.TARGET_SELECT
	if skill != null:
		info_label.text = "选择「%s」的目标（点敌人，右键/ESC 取消）" % skill.display_name
	else:
		info_label.text = "选择攻击目标（点敌人，右键/ESC 取消）"
	for target in _targets:
		target.set_targetable(true)


func _highlight_targets(value: bool) -> void:
	for target in _targets:
		if is_instance_valid(target):
			target.set_targetable(value)
	_targets.clear()


func _on_unit_clicked(unit: BattleUnit) -> void:
	if state == State.TARGET_SELECT and _targets.has(unit) and actor != null:
		var caster := actor
		var skill := _pending_skill
		_pending_skill = null
		_highlight_targets(false)
		if skill != null:
			var one: Array[BattleUnit] = [unit]
			await _perform_skill(caster, skill, one)
		else:
			await _perform_attack(caster, unit)
	else:
		# 非选目标阶段点单位：以后可以在这里弹"查看单位信息"面板
		info_label.text = "%s  HP %.0f/%.0f   MP %.0f/%.0f" % [unit.stats.name, unit.hp, unit.max_hp, unit.mp, unit.max_mp]


func _perform_attack(attacker: BattleUnit, target: BattleUnit) -> void:
	if not is_instance_valid(attacker) or not is_instance_valid(target) or not target.alive:
		_finish_turn()
		return

	state = State.EXECUTE
	info_label.text = "%s → %s" % [attacker.stats.name, target.stats.name]
	await attacker.play_attack(target)

	if target.try_block():
		create_floating_text(target, "Blocked!", block_color)
	else:
		var damage := attacker.roll_damage()
		var is_crit := attacker.roll_crit()
		if is_crit:
			damage = ceilf(damage * 1.5)
		target.take_damage(damage)
		create_floating_text(target, str(int(damage)), critical_color if is_crit else normal_color)
		await target.play_hit()

	await get_tree().create_timer(action_delay).timeout
	if not _check_battle_end():
		_finish_turn()


# ══════════════════════════════════════════════════════════
#  技能
# ══════════════════════════════════════════════════════════

## 单位本场能用的技能：优先用 UnitStats.skills，否则我方用 default_skills
func _skills_for(unit: BattleUnit, is_player: bool) -> Array[SkillData]:
	if unit.stats != null and not unit.stats.skills.is_empty():
		return unit.stats.skills
	if is_player:
		return default_skills
	return []


## 火球术这类单体/群体伤害技能的执行流程：起手 → 飞行 → 命中结算 → 收尾
func _perform_skill(caster: BattleUnit, skill: SkillData, targets: Array[BattleUnit]) -> void:
	if not is_instance_valid(caster) or skill == null:
		_finish_turn()
		return
	var victims := _alive(targets)
	if victims.is_empty():
		if not _check_battle_end():
			_finish_turn()
		return

	state = State.EXECUTE
	info_label.text = "%s 施放「%s」" % [caster.stats.name, skill.display_name]
	caster.spend_mana(skill.mana_cost)
	caster.start_cooldown(skill)
	_play_sfx(skill.cast_sfx)
	await caster.play_cast()

	for target in victims:
		if not is_instance_valid(target) or not target.alive:
			continue

		var projectile: SkillProjectile = SKILL_PROJECTILE_SCENE.instantiate() as SkillProjectile
		fx_root.add_child(projectile)
		projectile.setup(skill, caster.global_position)
		await projectile.fly_to(target.global_position)

		if target.try_block():
			create_floating_text(target, "Blocked!", block_color)
		else:
			var damage := caster.skill_damage(skill)
			var is_crit := caster.skill_crit(skill)
			if is_crit:
				damage = ceilf(damage * 1.5)
			target.take_damage(damage)
			create_floating_text(target, str(int(damage)), critical_color if is_crit else skill.tint)
			await target.play_hit()

		projectile.burst()
		_play_sfx(skill.hit_sfx)
		if skill.screen_shake > 0.0:
			_shake_camera(skill.screen_shake)
		await get_tree().create_timer(action_delay).timeout

	if not _check_battle_end():
		_finish_turn()


## 播一个一次性音效（不需要动 SoundManager）
func _play_sfx(stream: AudioStream) -> void:
	if stream == null:
		return
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.volume_db = -6.0
	add_child(player)
	player.finished.connect(player.queue_free)
	player.play()


## 命中时抖一下镜头（纯代码，不需要素材）
func _shake_camera(amount: float) -> void:
	if camera == null:
		return
	var base := camera.position
	var tween := create_tween()
	for i in 4:
		tween.tween_property(camera, "position",
			base + Vector2(randf_range(-amount, amount), randf_range(-amount, amount)), 0.04)
	tween.tween_property(camera, "position", base, 0.06)


func _on_unit_died(_unit: BattleUnit) -> void:
	turn_order.update_order(_alive(_all_units()))


# ══════════════════════════════════════════════════════════
#  胜负 / 飘字 / 工具
# ══════════════════════════════════════════════════════════

func _check_battle_end() -> bool:
	if state == State.FINISHED:
		return true
	var players_alive := not _alive(_players).is_empty()
	var enemies_alive := not _alive(_enemies).is_empty()
	if players_alive and enemies_alive:
		return false
	_finish_battle(players_alive, "胜利！" if players_alive else "战斗失败…")
	return true


func _finish_battle(player_won: bool, reason: String) -> void:
	if state == State.FINISHED:
		return
	state = State.FINISHED
	actor = null
	_pending_skill = null
	command_menu.close()
	_highlight_targets(false)
	turn_order.clear_current()
	info_label.text = reason
	battle_ended.emit(player_won)
	# TODO: 结算（经验 / 掉落 / 回地图）接在这里


func create_floating_text(unit: BattleUnit, text: String, color: Color) -> void:
	var fx := Global.FLOATING_TEXT_SCENE.instantiate() as FloatingText
	fx_root.add_child(fx)
	fx.global_position = unit.global_position + Vector2(randf_range(-18.0, 18.0), -70.0)
	fx.setup(text, color)


func _all_units() -> Array[BattleUnit]:
	var out: Array[BattleUnit] = []
	out.append_array(_players)
	out.append_array(_enemies)
	return out


func _alive(list: Array[BattleUnit]) -> Array[BattleUnit]:
	var out: Array[BattleUnit] = []
	for unit in list:
		if is_instance_valid(unit) and unit.alive:
			out.append(unit)
	return out


func _unhandled_input(event: InputEvent) -> void:
	# 选目标时按 ESC / 右键退回指令菜单
	if state == State.TARGET_SELECT and event.is_action_pressed("ui_cancel"):
		_highlight_targets(false)
		_pending_skill = null
		state = State.COMMAND
		command_menu.open_for(actor)
		get_viewport().set_input_as_handled()
