extends Control
class_name PartyPanel

## 团队管理面板（操作菜单 →「团队管理」）。
##
## ── 版式 ──
##   第一排 **5 个坑位**：队伍中（上阵）的五个人；
##   第二排 **10 个坑位**：团队里但没上阵的人。
##   每个坑位是「头像在上、名字在下」的纵向格子（空位画成虚线框），点一下选中，
##   再用底部「上阵 / 下阵 / 移出团队」按钮把他在这两个名单之间搬。
##
## ── 在系统里的位置 ──
##   纯 UI 场景：由 WorldMap._setup_overlays() 实例化后挂在它的 UI（CanvasLayer）下面。
##   本文件**不改任何队伍数据**：三个按钮各自只 emit 一个请求信号
##   （deploy_requested / undeploy_requested / remove_requested），真正的判定与改动都在
##   GameRoot（deploy_member / undeploy_member / remove_party_member），改完回调
##   WorldMap.notify_party_changed() → 本面板 show_party() 重建坑位。
##
## ── 键盘操作 ──
##   ←→ / A D 在坑位间移动（Godot 焦点系统），Enter/E 选中，W/S 交给 WorldMap 的焦点环
##   在「坑位 → 按钮」之间上下走；置灰按钮不进焦点环。

## 点了「上阵」。参数是选中的那个 UnitStats（不是节点）。
signal deploy_requested(stats: UnitStats)
## 点了「下阵」。
signal undeploy_requested(stats: UnitStats)
## 点了「移出团队」。
signal remove_requested(stats: UnitStats)
## 点了「设为队长」（把选中的人挪到上阵名单第一位 = 队长）。
signal lead_requested(stats: UnitStats)
## 点了底部「返回」（或按 Esc，由 WorldMap 处理）：退回操作菜单。
signal close_requested

## 第一排坑位数量 = 上阵上限。
const TEAM_SLOTS := 5
## 第二排坑位数量 = 未上阵展示位（5 列 × 2 行，列数在场景里配）。
const RESERVE_SLOTS := 10

## 坑位尺寸 —— **两排一致**（未上阵也是同样大的框，只是排成两行）。
const SLOT_SIZE := Vector2(96, 150)
const SLOT_ICON := 88.0

# ── 选中态配色 ──
# 用样式盒明确定义，而不是吃主题默认的 pressed 样式：
#   默认主题的按下态只比 normal 亮一点点，重建坑位后焦点一丢就完全看不出来了。
const SLOT_BG := Color(1, 1, 1, 0.05)
const SLOT_BORDER := Color(1, 1, 1, 0.14)
const SLOT_BG_HOVER := Color(1, 1, 1, 0.12)
const SLOT_BORDER_HOVER := Color(1, 0.95, 0.8, 0.45)
const SLOT_BG_SELECTED := Color(1.0, 0.82, 0.35, 0.20)
const SLOT_BORDER_SELECTED := Color(1.0, 0.84, 0.42, 1.0)

@onready var title_label: Label = %TitleLabel
@onready var message_label: Label = %MessageLabel
@onready var team_title: Label = %TeamTitle
@onready var team_row: HBoxContainer = %TeamRow
@onready var reserve_title: Label = %ReserveTitle
## 未上阵那一块：GridContainer（5 列 × 2 行），不是单行 HBox。
@onready var reserve_row: Container = %ReserveRow
@onready var deploy_button: Button = %DeployButton
@onready var undeploy_button: Button = %UndeployButton
@onready var remove_button: Button = %RemoveButton
@onready var lead_button: Button = %LeadButton
@onready var close_button: Button = %CloseButton

## 当前选中的成员（点击坑位设置）；null = 没选。
var _selected: UnitStats = null
## 上阵 / 团队名单的引用（show_party 传进来，只读）。
var _deployed: Array[UnitStats] = []
var _team: Array[UnitStats] = []


func _ready() -> void:
	hide()
	close_button.pressed.connect(_emit_close)
	deploy_button.pressed.connect(_on_deploy_pressed)
	undeploy_button.pressed.connect(_on_undeploy_pressed)
	remove_button.pressed.connect(_on_remove_pressed)
	lead_button.pressed.connect(_on_lead_pressed)
	_refresh_buttons()


## 按当前"团队 + 上阵名单"重建两排坑位并显示面板。
## 参数 team：团队（大名单）；deployed：上阵名单 —— 都是 GameRoot 的数组引用，只读。
## 副作用：show()、改三处计数文字、清空并重建两排坑位；尽量保留上次选中的那个人。
## ⚠ 不清空 message_label：WorldMap 是"先 show_message()、再 call_deferred 重建"。
func show_party(team: Array[UnitStats], deployed: Array[UnitStats]) -> void:
	_team = team
	_deployed = deployed
	show()
	# 标题固定不带人数（上阵/团队人数由下面的两排直接看出来，别在标题里再报一遍）。
	title_label.text = "团队管理"
	team_title.text = "队伍中"
	reserve_title.text = "未上阵"

	# 选中的人还在就保留，否则默认选第一个上阵成员
	if _selected == null or not _contains(team, _selected):
		_selected = deployed[0] if not deployed.is_empty() else (team[0] if not team.is_empty() else null)

	var reserved := _reserved_members()
	_rebuild_row(team_row, deployed, TEAM_SLOTS, SLOT_SIZE, SLOT_ICON)
	_rebuild_row(reserve_row, reserved, RESERVE_SLOTS, SLOT_SIZE, SLOT_ICON)
	_refresh_buttons()
	# 重建后把焦点还给选中的坑位：否则坑位全被换掉，焦点落空，键盘方向键会失效。
	_focus_selected.call_deferred()


## 把焦点还给「当前选中」的那个坑位（重建坑位后调用）。
func _focus_selected() -> void:
	if not visible:
		return
	for row in [team_row, reserve_row]:
		for child in row.get_children():
			if child is Button and (child as Button).button_pressed:
				(child as Button).grab_focus()
				return


## 在面板上显示一句提示（"XXX 已上阵。" / "至少要留 1 人上阵。" 等）。
func show_message(text: String) -> void:
	message_label.text = text


## 清掉提示文字（WorldMap 每次打开本面板时调一次）。
func clear_message() -> void:
	message_label.text = ""


## 按视觉顺序返回可聚焦的控件（WorldMap 做 W/S 循环切换用）：
## 第一排坑位 → 第二排坑位 → 可用的操作按钮 → 「返回」。
func focus_ring() -> Array[Control]:
	var out: Array[Control] = []
	for row in [team_row, reserve_row]:
		for child in row.get_children():
			if child is Button and not (child as Button).disabled:
				out.append(child as Control)
	for button in [deploy_button, undeploy_button, remove_button, lead_button]:
		if not button.disabled:
			out.append(button)
	out.append(close_button)
	return out


## 重建一排坑位。
## 参数 row：目标容器（第一排 HBox / 第二排 GridContainer）；members：这一排要展示的人；
## slots：坑位总数；slot_size / icon_size：格子/头像尺寸（两排一致）。
func _rebuild_row(row: Container, members: Array[UnitStats], slots: int,
		slot_size: Vector2, icon_size: float) -> void:
	for child in row.get_children():
		row.remove_child(child)
		child.queue_free()
	for i in slots:
		if i < members.size() and members[i] != null:
			row.add_child(_make_slot(members[i], slot_size, icon_size))
		else:
			row.add_child(_make_empty_slot(slot_size))


## 造一个成员坑位：纵向（头像 → 名字 → 门派），点一下选中。
## 选中态用样式盒明确定义（见 SLOT_BG_SELECTED），不依赖主题的 pressed 样式和焦点圈 ——
## 否则坑位一重建、焦点一丢，选中框就"消失"了。
func _make_slot(stats: UnitStats, slot_size: Vector2, icon_size: float) -> Button:
	var slot := Button.new()
	slot.name = "Slot_%s" % GameRoot.character_key(stats)
	slot.custom_minimum_size = slot_size
	slot.toggle_mode = true
	slot.focus_mode = Control.FOCUS_ALL
	slot.tooltip_text = "%s　%s" % [stats.name, _stats_text(stats)]
	slot.button_pressed = _selected != null and GameRoot.character_key(_selected) == GameRoot.character_key(stats)
	slot.set_meta("char_key", GameRoot.character_key(stats))
	slot.add_theme_stylebox_override("normal", _slot_style(SLOT_BG, SLOT_BORDER, 1))
	slot.add_theme_stylebox_override("hover", _slot_style(SLOT_BG_HOVER, SLOT_BORDER_HOVER, 2))
	slot.add_theme_stylebox_override("pressed", _slot_style(SLOT_BG_SELECTED, SLOT_BORDER_SELECTED, 2))
	slot.add_theme_stylebox_override("hover_pressed", _slot_style(SLOT_BG_SELECTED, SLOT_BORDER_SELECTED, 2))
	# 焦点圈：**向外**扩 3px 画一圈细白线（expand_margin），不盖住选中态的金框。
	# 之前设成 StyleBoxEmpty，方向键移动时完全看不出光标在哪 —— 这就是"移动选择框消失了"。
	slot.add_theme_stylebox_override("focus", _focus_style())
	slot.pressed.connect(_on_slot_pressed.bind(stats))

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 4
	box.offset_top = 8
	box.offset_right = -4
	box.offset_bottom = -6
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 2)

	var icon := TextureRect.new()
	# 队伍格是小的方形格，优先用方形头像；没配就退回 icon（全身立绘）。
	icon.texture = stats.avatar if stats.avatar != null else stats.icon
	icon.custom_minimum_size = Vector2(icon_size, icon_size)
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	# ⚠ 必须 IGNORE_SIZE：否则 TextureRect 的最小尺寸会跟着贴图原始尺寸（150px）走，
	# 把坑位撑爆、整排挤成一团。
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(icon)

	var name_label := Label.new()
	name_label.text = stats.name
	name_label.add_theme_color_override("font_color", Color(0.95, 0.92, 0.85, 1))
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 17)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(name_label)

	# 门派：挂在名字下面一行，淡金色，和名字拉开层次。
	var sect_label := Label.new()
	sect_label.text = _sect_name(stats)
	sect_label.add_theme_color_override("font_color", Color(0.96, 0.84, 0.55, 0.85))
	sect_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sect_label.add_theme_font_size_override("font_size", 13)
	sect_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(sect_label)

	slot.add_child(box)
	return slot


## 坑位样式盒（每次 new：共享 Resource 就地改色会污染其它坑位）。
func _slot_style(bg: Color, border: Color, width: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	style.set_border_width_all(width)
	style.set_corner_radius_all(8)
	return style


## 焦点圈：透明底 + 1px 白边，并向外扩 3px。
## 向外扩是为了和"选中"的金框错开 —— 同一个坑位既可能被选中、又可能正好有键盘焦点。
func _focus_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0)
	style.border_color = Color(1, 1, 1, 0.9)
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.set_expand_margin_all(3)
	return style


## 角色的门派显示名；没拜师显示"散修"（团队里全是玩家角色，不会是魔物）。
func _sect_name(stats: UnitStats) -> String:
	var id := GameRoot.sect_of(stats)
	if id.is_empty() or not Global.SECTS.has(id):
		return "散修"
	return String(Global.SECTS[id].get("name", id))


## 造一个空坑位（虚线框 +「空位」）。不可点、不可聚焦。
func _make_empty_slot(slot_size: Vector2) -> Panel:
	var panel := Panel.new()
	panel.custom_minimum_size = slot_size
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1, 1, 1, 0.04)
	style.border_color = Color(1, 1, 1, 0.18)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	panel.add_theme_stylebox_override("panel", style)
	var label := Label.new()
	label.text = "空位"
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 14)
	label.modulate = Color(1, 1, 1, 0.35)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(label)
	return panel


## 按当前选中的人刷新四个按钮的可用状态。
## 队长 = 上阵名单第 0 位：选中的人不是第一位时「设为队长」才可用。
## 不再写 tooltip 文案（面板上的操作提示已全部移除）。
func _refresh_buttons() -> void:
	var s := _selected
	var on_field := s != null and GameRoot.is_deployed(_deployed, s)
	var in_team := s != null and _index_in(_team, s) >= 0
	var deploy_index := _index_in(_deployed, s) if on_field else -1
	# 团队只剩一人时不允许移出（地图上得有个人可操控）
	var can_remove := in_team and GameRoot.party_count(_team) > 1

	deploy_button.disabled = not (s != null and not on_field and GameRoot.deploy_can_add(_deployed, s))
	undeploy_button.disabled = not (s != null and on_field and GameRoot.deploy_can_remove(_deployed, s))
	lead_button.disabled = not (on_field and deploy_index > 0)
	remove_button.disabled = not can_remove


## 团队里但没上阵的人（保持团队顺序）。
func _reserved_members() -> Array[UnitStats]:
	var out: Array[UnitStats] = []
	for stats in _team:
		if stats == null or GameRoot.is_deployed(_deployed, stats):
			continue
		out.append(stats)
	return out


## 点坑位：只改选中，不动数据。
func _on_slot_pressed(stats: UnitStats) -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	_selected = stats
	_sync_slot_selection()
	_refresh_buttons()


## 让"按下态"严格等于"只有选中那一个是按下的"。
## ⚠ 必须手动同步：坑位是 toggle_mode 的 Button，点谁谁自己变成按下态，
##   不清其它人的话会好几个坑位同时顶着金框（截图里就同时亮了 4 个）。
func _sync_slot_selection() -> void:
	var key := GameRoot.character_key(_selected) if _selected != null else ""
	for row in [team_row, reserve_row]:
		for child in row.get_children():
			if child is Button:
				var k := String(child.get_meta("char_key", ""))
				(child as Button).button_pressed = not key.is_empty() and k == key


## 「上阵」回调：只发请求。
func _on_deploy_pressed() -> void:
	if _selected == null:
		return
	SoundManager.play_sound(SoundManager.Sound.UI)
	deploy_requested.emit(_selected)


## 「下阵」回调：同上。
func _on_undeploy_pressed() -> void:
	if _selected == null:
		return
	SoundManager.play_sound(SoundManager.Sound.UI)
	undeploy_requested.emit(_selected)


## 「移出团队」回调：同上。
func _on_remove_pressed() -> void:
	if _selected == null:
		return
	SoundManager.play_sound(SoundManager.Sound.UI)
	remove_requested.emit(_selected)


## 「设为队长」回调：同上。
func _on_lead_pressed() -> void:
	if _selected == null:
		return
	SoundManager.play_sound(SoundManager.Sound.UI)
	lead_requested.emit(_selected)


func _emit_close() -> void:
	close_requested.emit()


## 数组里找某个角色（用 character_key 比，资源重新加载也不会认错）。
static func _index_in(list: Array[UnitStats], stats: UnitStats) -> int:
	if stats == null:
		return -1
	var key := GameRoot.character_key(stats)
	for i in list.size():
		if list[i] != null and GameRoot.character_key(list[i]) == key:
			return i
	return -1


static func _contains(list: Array[UnitStats], stats: UnitStats) -> bool:
	return _index_in(list, stats) >= 0


## 属性文字（tooltip 用）。全部走派生值：.tres 里的旧数字在战斗副本里会被覆盖，直接读会显示过期数据。
func _stats_text(stats: UnitStats) -> String:
	var d := GameRoot.derived_stats(stats)
	return "气血 %s · 伤害 %s · 速度 %s · 格挡值 %s" % [
		Global.format_stat(d["hp"]),
		Global.format_stat(d["damage"]),
		Global.format_stat(d["speed"]),
		Global.format_stat(d["block_value"]),
	]
