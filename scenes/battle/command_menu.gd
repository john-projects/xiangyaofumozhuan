extends Panel
class_name CommandMenu

## 指令菜单：主菜单（攻击/法术/道具/防御/逃跑）+ 技能二级菜单
## 只负责"显示 + 发信号"，具体做什么由 Battle 决定。

signal command_selected(command: StringName)
signal skill_selected(skill: SkillData)

@onready var title_label: Label = %TitleLabel
@onready var main_buttons: VBoxContainer = %MainButtons
@onready var skill_buttons: VBoxContainer = %SkillButtons
@onready var attack_button: Button = %AttackButton
@onready var skill_button: Button = %SkillButton
@onready var item_button: Button = %ItemButton
@onready var defend_button: Button = %DefendButton
@onready var flee_button: Button = %FleeButton
@onready var back_button: Button = %BackButton

var _unit: BattleUnit


func _ready() -> void:
	attack_button.pressed.connect(_on_main_pressed.bind(&"attack"))
	skill_button.pressed.connect(_open_skills)
	item_button.pressed.connect(_on_main_pressed.bind(&"item"))
	defend_button.pressed.connect(_on_main_pressed.bind(&"defend"))
	flee_button.pressed.connect(_on_main_pressed.bind(&"flee"))
	back_button.pressed.connect(_show_main)

	# 道具系统还没做，先禁用
	item_button.disabled = true

	_show_main()
	close()


func open_for(unit: BattleUnit) -> void:
	_unit = unit
	if unit != null and unit.stats != null:
		title_label.text = unit.stats.name
	else:
		title_label.text = "指令"
	skill_button.disabled = unit == null or not unit.has_skills()
	_show_main()
	show()


func close() -> void:
	hide()
	_unit = null


# ══════════════════════════════════════════════════════════
#  主菜单 / 技能菜单
# ══════════════════════════════════════════════════════════

func _show_main() -> void:
	main_buttons.visible = true
	skill_buttons.visible = false
	back_button.visible = false


func _open_skills() -> void:
	if _unit == null:
		return
	SoundManager.play_sound(SoundManager.Sound.UI)

	for child in skill_buttons.get_children():
		skill_buttons.remove_child(child)
		child.queue_free()

	var count := 0
	for skill in _unit.available_skills:
		if skill == null:
			continue
		skill_buttons.add_child(_make_skill_button(skill))
		count += 1
	if count == 0:
		var empty := Label.new()
		empty.text = "（没有可用技能）"
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		skill_buttons.add_child(empty)

	main_buttons.visible = false
	skill_buttons.visible = true
	back_button.visible = true


func _make_skill_button(skill: SkillData) -> Button:
	var button := Button.new()
	var suffix := ""
	var cd := _unit.cooldown_left(skill)
	if cd > 0:
		suffix = "  冷却%d" % cd
	elif _unit.mp < skill.mana_cost:
		suffix = "  蓝不够"
	button.text = "%s  蓝%d%s" % [skill.display_name, int(skill.mana_cost), suffix]
	button.custom_minimum_size = Vector2(180, 46)
	button.add_theme_font_size_override("font_size", 20)
	button.disabled = not _unit.can_use_skill(skill)
	button.pressed.connect(_on_skill_pressed.bind(skill))
	return button


# ══════════════════════════════════════════════════════════

func _on_main_pressed(command: StringName) -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	command_selected.emit(command)


func _on_skill_pressed(skill: SkillData) -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	skill_selected.emit(skill)
