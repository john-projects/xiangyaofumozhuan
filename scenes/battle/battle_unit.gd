extends Node2D
class_name BattleUnit

## 战斗单位：血量/蓝量状态 + 表现。战斗流程（谁出手、打谁、什么时候结束）由 Battle 驱动。
##
## 数据来源：UnitStats（name / icon / health / mana / damage / speed / luck / block_chance / skills）
## 扩展点：
##   · 伤害公式        → roll_damage() / roll_crit() / try_block()
##   · 技能数值        → skill_damage() / skill_crit()（火球术在 resources/skills/skill_fireball.tres）
##   · 动作演出        → play_attack() / play_cast() / play_hit()（现在是最简 Tween）
##   · 状态效果(Buff)  → 以后在这里加 status 字典 + tick_status()

signal clicked(unit: BattleUnit)
signal hovered(unit: BattleUnit, entered: bool)
signal hp_changed(unit: BattleUnit)
signal mp_changed(unit: BattleUnit)
signal died(unit: BattleUnit)

const SELECT_COLOR := Color(1.0, 0.86, 0.35, 0.30)
const TARGET_COLOR := Color(1.0, 0.35, 0.35, 0.35)
const HOVER_COLOR := Color(1.0, 1.0, 1.0, 0.20)
const HIT_TINT := Color(1.0, 0.45, 0.45)
const DEFEND_TINT := Color(0.75, 0.85, 1.0)
const CAST_TINT := Color(1.45, 1.2, 0.9)

@export var stats: UnitStats

var is_player := false
var max_hp := 1.0
var hp := 1.0
var max_mp := 0.0
var mp := 0.0
var alive := true
var defending := false

## skill_id -> 剩余冷却回合数
var cooldowns: Dictionary[String, int] = {}
## 这个单位本场能用的技能（Battle 在生成时填：优先 UnitStats.skills，否则用 Battle.default_skills）
var available_skills: Array[SkillData] = []

var _selected := false
var _targetable := false
var _hovered := false
var _base_scale := Vector2.ONE

@onready var sprite: Sprite2D = %Sprite
@onready var health_bar: HealthBar = %HealthBar
@onready var mana_bar: HealthBar = %ManaBar
@onready var name_label: Label = %NameLabel
@onready var selection: Polygon2D = %Selection
@onready var click_area: Area2D = %ClickArea


func _ready() -> void:
	_base_scale = sprite.scale
	click_area.input_event.connect(_on_click_area_input_event)
	click_area.mouse_entered.connect(_on_mouse_entered)
	click_area.mouse_exited.connect(_on_mouse_exited)
	# 血条/蓝条/名字都是 Control，默认会吃鼠标事件 → 会让"点单位选目标"点不到
	_ignore_mouse(health_bar)
	_ignore_mouse(mana_bar)
	_ignore_mouse(name_label)


## 把自身及所有 Control 子节点设成不接收鼠标事件
func _ignore_mouse(node: Node) -> void:
	if node is Control:
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in node.get_children():
		_ignore_mouse(child)


## 由 Battle 在 add_child() 之后调用
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
	_refresh_visuals()


func _refresh_visuals() -> void:
	sprite.texture = stats.icon
	name_label.text = stats.name
	sprite.flip_h = not is_player
	health_bar.self_modulate = Color(1, 1, 1) if is_player else Color(1, 0.72, 0.72)
	mana_bar.visible = max_mp > 0.0
	mana_bar.self_modulate = Color(1, 1, 1) if is_player else Color(0.85, 0.85, 1)
	_refresh_hp()
	_refresh_mana()


# ══════════════════════════════════════════════════════════
#  数值（想改公式只动这里）
# ══════════════════════════════════════════════════════════

func roll_damage() -> float:
	return maxf(1.0, stats.damage)


func roll_crit(crit_bonus := 0.0) -> bool:
	return Global.get_chance_success(0.10 + crit_bonus)


func try_block() -> bool:
	return Global.get_chance_success(stats.block_chance / 100.0)


func turn_speed() -> float:
	return float(stats.speed) + randf_range(-4.0, 4.0)


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


func heal(amount: float) -> void:
	if not alive:
		return
	hp = minf(max_hp, hp + amount)
	_refresh_hp()


func _refresh_hp() -> void:
	health_bar.update_bar(hp / max_hp, hp)
	hp_changed.emit(self)


func _refresh_mana() -> void:
	if max_mp > 0.0:
		mana_bar.update_bar(mp / max_mp, mp)
	mp_changed.emit(self)


func _die() -> void:
	alive = false
	defending = false
	set_selected(false)
	set_targetable(false)
	click_area.input_pickable = false
	name_label.modulate = Color(1, 1, 1, 0.35)
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, 0.45)
	tween.tween_callback(func() -> void: visible = false)
	died.emit(self)


# ══════════════════════════════════════════════════════════
#  技能：蓝量 / 冷却 / 数值
# ══════════════════════════════════════════════════════════

func has_skills() -> bool:
	return not available_skills.is_empty()


func can_use_skill(skill: SkillData) -> bool:
	if skill == null or not alive:
		return false
	if mp < skill.mana_cost:
		return false
	if cooldown_left(skill) > 0:
		return false
	return true


func cooldown_left(skill: SkillData) -> int:
	if skill == null or not cooldowns.has(skill.id):
		return 0
	return cooldowns[skill.id]


func spend_mana(amount: float) -> void:
	mp = maxf(0.0, mp - amount)
	_refresh_mana()


func start_cooldown(skill: SkillData) -> void:
	if skill == null:
		return
	var left := cooldown_left(skill)
	cooldowns[skill.id] = maxi(left, skill.cooldown)
	mp_changed.emit(self)          # 顺便刷新技能菜单的显示


## 每回合开始时调用（Battle._next_round 里对全体单位调一次）
func tick_cooldowns() -> void:
	if cooldowns.is_empty():
		return
	var expired: Array[String] = []
	for key: String in cooldowns.keys():
		cooldowns[key] = cooldowns[key] - 1
		if cooldowns[key] <= 0:
			expired.append(key)
	for key in expired:
		cooldowns.erase(key)


func skill_damage(skill: SkillData) -> float:
	if skill == null:
		return roll_damage()
	return maxf(1.0, skill.power * stats.damage)


func skill_crit(skill: SkillData) -> bool:
	return roll_crit(skill.crit_bonus if skill != null else 0.0)


# ══════════════════════════════════════════════════════════
#  选中 / 目标高亮
# ══════════════════════════════════════════════════════════

func set_selected(value: bool) -> void:
	_selected = value
	_update_selection()


func set_targetable(value: bool) -> void:
	_targetable = value
	_update_selection()


func _update_selection() -> void:
	selection.visible = alive and (_selected or _targetable or _hovered)
	if _targetable:
		selection.color = TARGET_COLOR
	elif _selected:
		selection.color = SELECT_COLOR
	else:
		selection.color = HOVER_COLOR


func set_defending(value: bool) -> void:
	defending = value
	if value:
		var tween := create_tween()
		tween.tween_property(sprite, "modulate", DEFEND_TINT, 0.15)
	else:
		sprite.modulate = Color.WHITE


# ══════════════════════════════════════════════════════════
#  表现（演出）—— 都可以换成 AnimationPlayer
# ══════════════════════════════════════════════════════════

func play_attack(target: BattleUnit) -> void:
	if not is_instance_valid(target):
		return
	var from := position
	var dir := (target.global_position - global_position).normalized()
	var to := from + dir * 80.0
	var tween := create_tween()
	tween.tween_property(self, "position", to, 0.12)
	tween.tween_interval(0.04)
	tween.tween_property(self, "position", from, 0.16)
	await tween.finished


## 施法起手：微微涨大 + 染色一下（没有施法动画素材时也有反馈）
func play_cast() -> void:
	sprite.modulate = Color.WHITE
	var tween := create_tween()
	tween.tween_property(sprite, "scale", _base_scale * 1.14, 0.14)
	tween.parallel().tween_property(sprite, "modulate", CAST_TINT, 0.14)
	tween.tween_property(sprite, "scale", _base_scale, 0.16)
	tween.parallel().tween_property(sprite, "modulate", DEFEND_TINT if defending else Color.WHITE, 0.16)
	await tween.finished


func play_hit() -> void:
	var tween := create_tween()
	tween.tween_property(sprite, "modulate", HIT_TINT, 0.05)
	tween.tween_property(sprite, "modulate", DEFEND_TINT if defending else Color.WHITE, 0.15)
	await tween.finished


# ══════════════════════════════════════════════════════════
#  点击 / 悬停
# ══════════════════════════════════════════════════════════

func _on_click_area_input_event(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if not alive:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		clicked.emit(self)


func _on_mouse_entered() -> void:
	_hovered = true
	_update_selection()
	hovered.emit(self, true)
	if _targetable:
		Input.set_default_cursor_shape(Input.CURSOR_POINTING_HAND)


func _on_mouse_exited() -> void:
	_hovered = false
	_update_selection()
	hovered.emit(self, false)
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)
