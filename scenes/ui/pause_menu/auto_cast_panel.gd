extends Control

const Paper := preload("res://styles/paper_ui.gd")
## Per-character skill choices, keyed by character resource and round number.

signal back_requested
signal focusables_changed

const PARTY_COLUMNS := 5
const ROUND_WIDTH := 116.0
const CHARACTER_WIDTH := 175.0

@onready var _grid: GridContainer = %PlanGrid
@onready var _back: Button = %BackButton

var _plan: Dictionary


func _ready() -> void:
	Paper.add_panel_pattern($Center/Panel)
	var frame := get_theme_stylebox("panel", &"Panel").duplicate() as StyleBox
	frame.content_margin_left = 32
	frame.content_margin_right = 32
	frame.content_margin_top = 25
	frame.content_margin_bottom = 25
	$Center/Panel.add_theme_stylebox_override("panel", frame)
	Paper.style_heading($Center/Panel/Content/Title, "策")
	hide()
	_back.pressed.connect(func(): back_requested.emit())


func open(deployed: Array[UnitStats], plan: Dictionary) -> void:
	_plan = plan
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()

	var corner := Control.new()
	corner.custom_minimum_size.x = ROUND_WIDTH
	_grid.add_child(corner)
	var columns: Array[UnitStats] = []
	var skills_by_column: Array = []
	for i in range(PARTY_COLUMNS):
		var member: UnitStats = deployed[i] if i < deployed.size() else null
		columns.append(member)
		skills_by_column.append(GameRoot.player_skills(member))
		_grid.add_child(_portrait_header(member))

	for plan_key in range(Battle.AUTO_CAST_ROUNDS + 1):
		var is_loop := plan_key == Battle.AUTO_CAST_LOOP_ROW
		var round_label := _label("循环" if is_loop else "第 %d 回合" % plan_key, 21)
		round_label.custom_minimum_size.x = ROUND_WIDTH
		if is_loop:
			round_label.tooltip_text = "选「回合循环」可分别安排 5 回合，其他选项从第 1 回合起重复执行。"
		_grid.add_child(round_label)
		for i in range(PARTY_COLUMNS):
			_grid.add_child(_skill_choice(columns[i], skills_by_column[i], plan_key))

	show()


func focus_ring() -> Array[Control]:
	return Global.collect_focusable(self)


func _portrait_header(member: UnitStats) -> Control:
	var column := VBoxContainer.new()
	column.custom_minimum_size.x = CHARACTER_WIDTH
	column.add_theme_constant_override("separation", 6)
	var avatar := TextureRect.new()
	avatar.custom_minimum_size = Vector2(66, 66)
	avatar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	if member != null:
		avatar.texture = member.avatar if member.avatar != null else member.icon
	column.add_child(avatar)
	column.add_child(_label(member.name if member != null else "空位", 19))
	return column


func _skill_choice(member: UnitStats, skills: Array[SkillData], plan_key: int) -> OptionButton:
	var option := OptionButton.new()
	option.custom_minimum_size = Vector2(CHARACTER_WIDTH, 48)
	option.fit_to_longest_item = false
	option.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	option.add_theme_font_size_override("font_size", 19)
	if member == null:
		option.add_item("—")
		option.disabled = true
		return option

	if plan_key == Battle.AUTO_CAST_LOOP_ROW:
		_add_choice(option, "回合循环", Battle.AUTO_CAST_CYCLE)
	var attack_index := option.item_count
	_add_choice(option, "攻击", Battle.AUTO_CAST_ATTACK)
	_add_choice(option, "防御", Battle.AUTO_CAST_DEFEND)
	for skill in skills:
		if Battle.is_skill_playable(skill) and not skill.id.is_empty():
			_add_choice(option, skill.display_name, skill.id)

	var key := GameRoot.character_key(member)
	var choices: Dictionary = _plan.get(key, {})
	var mode := String(choices.get(Battle.AUTO_CAST_LOOP_ROW, Battle.AUTO_CAST_CYCLE))
	if plan_key == Battle.AUTO_CAST_LOOP_ROW:
		_select_action(option, mode, attack_index)
	else:
		var can_edit := mode == Battle.AUTO_CAST_CYCLE
		_select_action(option, String(choices.get(plan_key, Battle.AUTO_CAST_ATTACK)) if can_edit else mode)
		option.disabled = not can_edit
	option.item_selected.connect(_select_skill.bind(option, key, plan_key))
	return option


func _select_action(option: OptionButton, action: String, fallback: int = 0) -> void:
	for i in range(option.item_count):
		if option.get_item_metadata(i) == action:
			option.select(i)
			return
	option.select(fallback)



func _add_choice(option: OptionButton, label: String, action: String) -> void:
	option.add_item(label)
	option.set_item_metadata(option.item_count - 1, action)



func _select_skill(index: int, option: OptionButton, key: String, plan_key: int) -> void:
	var choices: Dictionary = _plan.get(key, {})
	var action := String(option.get_item_metadata(index))
	if plan_key == Battle.AUTO_CAST_LOOP_ROW:
		# An explicit empty mode means fixed manual. Missing mode means round cycling.
		choices[plan_key] = action
		var can_edit := action == Battle.AUTO_CAST_CYCLE
		var column := option.get_index() % _grid.columns
		for round_number in range(1, Battle.AUTO_CAST_ROUNDS + 1):
			var cell := _grid.get_child((round_number + 1) * _grid.columns + column) as OptionButton
			if not can_edit:
				choices[round_number] = action
				_select_action(cell, action)
			cell.disabled = not can_edit
		_plan[key] = choices
		focusables_changed.emit()
		return
	if action.is_empty():
		choices.erase(plan_key)
	else:
		choices[plan_key] = action
	if choices.is_empty():
		_plan.erase(key)
	else:
		_plan[key] = choices



func _label(value: String, font_size: int) -> Label:
	var label := Label.new()
	label.text = value
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", Paper.INK)
	return label
