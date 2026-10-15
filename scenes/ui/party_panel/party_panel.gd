extends Control
class_name PartyPanel

## 队伍管理面板（操作菜单 →「队伍管理」的二级页）。
##
## ── 两层结构（先读这个再看代码）──
##   · **团队（大名单）**：招到的人都在这里，默认不限人数 —— 面板每行一个成员；
##   · **上阵名单**：真正进战斗的，最多 GameRoot.MAX_DEPLOYED = 5 人，必须是团队的子集。
##   每行右侧两个按钮就是在这两层之间搬人：「上阵/下阵」只动上阵名单，
##   「移出团队」则把人从大名单里彻底删掉（顺带也会从上阵名单摘掉）。
##
## ── 在系统里的位置 ──
##   纯 UI 场景：由 WorldMap._setup_overlays() 实例化后挂在它的 UI（CanvasLayer）下面。
##   本文件**不改任何队伍数据**：三个按钮各自只 emit 一个请求信号
##   （deploy_requested / undeploy_requested / remove_requested），真正的判定与改动都在
##   GameRoot（deploy_member / undeploy_member / remove_party_member），改完回调
##   WorldMap.notify_party_changed() → 本面板 show_party() 重建列表。
##   与招募面板（NPC 对话面板）遵循同一套"UI 只请求、GameRoot 才改数据"的约定；
##   按钮灰不灰也是调 GameRoot 的静态规则函数算的，所以不会出现"能点但点完没反应"。
##
## ── 键盘操作 ──
##   每行两个按钮 + 底部「返回」，按视觉顺序通过 focus_ring() 交给 WorldMap 做 W/S 循环切换；
##   ↑↓ 由 Godot 的 GUI 焦点系统处理；Enter/空格由 GUI 直接按下；E 由 WorldMap._overlay_nav() 按下；
##   Esc 由 WorldMap 处理成"退回操作菜单（上一级）"。置灰的按钮不进焦点环（否则 W/S 会卡住）。

## 某一行点了「上阵」。参数是那一行的 UnitStats（不是节点）。
signal deploy_requested(stats: UnitStats)
## 某一行点了「下阵」。
signal undeploy_requested(stats: UnitStats)
## 某一行点了「移出团队」。
signal remove_requested(stats: UnitStats)
## 点了底部「返回」（或按 Esc，由 WorldMap 处理）：退回操作菜单。
signal close_requested

## 头像显示尺寸（TextureRect）。
const ICON_SIZE := 72.0
## 每一行的最小高度。低于这个值头像会被压扁、属性两行也会挤在一起。
const ROW_HEIGHT := 92.0

@onready var title_label: Label = %TitleLabel
@onready var rows: VBoxContainer = %Rows
@onready var message_label: Label = %MessageLabel
@onready var close_button: Button = %CloseButton


func _ready() -> void:
	hide()
	close_button.pressed.connect(_emit_close)


## 按当前"团队 + 上阵名单"重建成员行，并显示面板。
## 参数 team：团队（大名单）数组，就是 GameRoot.party —— 引用语义，本函数只读不写。
## 参数 deployed：上阵名单数组，就是 GameRoot.deployed —— 同样是引用，只读。
## 副作用：show()；改标题里的计数；清空并重建 %Rows 的子节点。
## ⚠ 本函数**刻意不清空提示文字**（message_label）：上阵/下阵/移出成员时，WorldMap 是
##   "先 show_message()、再 call_deferred("show_party")"（因为直接在按钮回调里重建列表
##   会把正在发信号的按钮摘掉）—— 如果这里清一次，玩家就永远看不到"XXX 已上阵。"。
##   需要清掉旧提示时调 clear_message()（打开面板时用）。
func show_party(team: Array[UnitStats], deployed: Array[UnitStats]) -> void:
	show()
	title_label.text = "队伍管理　　团队 %d 人 · 上阵 %d/%d" % [
		GameRoot.party_count(team), GameRoot.party_count(deployed), GameRoot.MAX_DEPLOYED]
	for child in rows.get_children():
		rows.remove_child(child)
		child.queue_free()
	for i in team.size():
		rows.add_child(_make_member_row(team[i], i, deployed))
	# 空位提示只在"团队有人数上限"时才有意义；默认不限人数（MAX_TEAM_SIZE = 0），
	# 这时只在团队为空时给一行指路。
	if GameRoot.MAX_TEAM_SIZE > 0:
		for slot in range(team.size(), GameRoot.MAX_TEAM_SIZE):
			rows.add_child(_make_empty_row(slot))
	elif team.is_empty():
		rows.add_child(_make_note_row("团队还是空的 —— 去地图上找「队友」NPC 招募"))


## 在面板上显示一句提示（"XXX 已上阵。" / "至少要留 1 人上阵。" 等）。
## 由 WorldMap.notify_party_changed() 调用。
func show_message(text: String) -> void:
	message_label.text = text


## 清掉提示文字（WorldMap 每次打开本面板时调一次，免得看到上一次留下的旧提示）。
func clear_message() -> void:
	message_label.text = ""


## 按视觉顺序返回可聚焦的按钮（WorldMap 做 W/S 循环切换用）。
## 顺序 = 从上到下、每行先「上阵/下阵」再「移出团队」，最后「返回」。
## 只收没被置灰的按钮：置灰按钮 grab_focus() 无效，留在环里会让 W/S 卡住不动。
func focus_ring() -> Array[Control]:
	var out: Array[Control] = []
	for child in rows.get_children():
		for button_name in [^"DeployButton", ^"RemoveButton"]:
			var button := child.get_node_or_null(button_name) as Button
			if button != null and not button.disabled:
				out.append(button)
	out.append(close_button)
	return out


## 造一行成员：头像 +「序号. 名字（队长）+ 上阵状态」 + 属性行 + 两个按钮。
## 参数 team_index：在团队里的序号（0 = 队长，不可移出团队）。
## 参数 deployed：上阵名单（只读），用来决定按钮是「上阵」还是「下阵」、以及灰不灰。
##
## 按钮规则（三条互相独立的约束，都写在这一处，面板只是"把规则画出来"）：
##   · 已在名单里 → 「下阵」；只剩他一个上阵时置灰（至少要留 1 人，否则进不了战斗）；
##   · 不在名单里 → 「上阵」；上阵位满（5 人）时置灰，玩家得先下阵一个；
##   · 队长行额外把「移出团队」置灰（队长位固定，避免整局没有稳定的大名单首位）。
## 为什么状态既画在文字上（"上阵中/待上阵"）又画在按钮上：按钮可能是灰的，
##   光看按钮分不清"是已经上阵了"还是"位子满了"，所以状态单独用一个标签写清楚。
func _make_member_row(stats: UnitStats, team_index: int, deployed: Array[UnitStats]) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "Row%d" % team_index
	row.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	row.add_theme_constant_override("separation", 14)

	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(ICON_SIZE, ICON_SIZE)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture = stats.icon
	row.add_child(icon)

	# 名字 + 属性两行，垂直居中，横向占满剩余宽度
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.alignment = BoxContainer.ALIGNMENT_CENTER
	info.add_theme_constant_override("separation", 4)

	var on_field := GameRoot.is_deployed(deployed, stats)
	var name_label := Label.new()
	name_label.text = "%d. %s%s　%s" % [
		team_index + 1, stats.name, "（队长）" if team_index == 0 else "",
		"[上阵中]" if on_field else "[待上阵]"]
	name_label.add_theme_font_size_override("font_size", 23)
	name_label.modulate = Color(1, 1, 1, 1.0) if on_field else Color(1, 1, 1, 0.62)
	info.add_child(name_label)

	var stats_label := Label.new()
	stats_label.text = _stats_text(stats)
	stats_label.add_theme_font_size_override("font_size", 17)
	stats_label.modulate = Color(1, 1, 1, 0.72)
	info.add_child(stats_label)
	row.add_child(info)

	row.add_child(_make_deploy_button(stats, deployed))
	row.add_child(_make_remove_button(stats, team_index))
	return row


## 造「上阵」/「下阵」按钮（规则见 _make_member_row 的注释）。
func _make_deploy_button(stats: UnitStats, deployed: Array[UnitStats]) -> Button:
	var button := Button.new()
	button.name = "DeployButton"
	button.custom_minimum_size = Vector2(140, 56)
	button.add_theme_font_size_override("font_size", 20)
	if GameRoot.is_deployed(deployed, stats):
		button.text = "下阵"
		button.tooltip_text = "把他从上阵名单里拿下来（至少要留 1 人上阵）"
		if not GameRoot.deploy_can_remove(deployed, stats):
			button.disabled = true
			button.tooltip_text = "至少要留 1 人上阵，不能把最后一个也下阵"
		else:
			button.pressed.connect(_on_undeploy_pressed.bind(stats))
	else:
		button.text = "上阵"
		button.tooltip_text = "把他放进上阵名单（最多 %d 人）" % GameRoot.MAX_DEPLOYED
		if not GameRoot.deploy_can_add(deployed, stats):
			button.disabled = true
			button.tooltip_text = "上阵位已经满了（%d 人），先让一个下阵" % GameRoot.MAX_DEPLOYED
		else:
			button.pressed.connect(_on_deploy_pressed.bind(stats))
	return button


## 造「移出团队」按钮（队长那一行置灰）。
func _make_remove_button(stats: UnitStats, team_index: int) -> Button:
	var button := Button.new()
	button.name = "RemoveButton"
	button.custom_minimum_size = Vector2(150, 56)
	button.add_theme_font_size_override("font_size", 20)
	if team_index == 0:
		button.text = "队长（固定）"
		button.disabled = true
		button.tooltip_text = "队长不能移出团队（大名单的第一位是稳定引用）"
	else:
		button.text = "移出团队"
		button.tooltip_text = "从团队里彻底删掉他（也会自动从上阵名单里摘掉）"
		button.pressed.connect(_on_remove_pressed.bind(stats))
	return button


## 造一行空位提示（纯文字，不可点也不可聚焦）。只在 MAX_TEAM_SIZE > 0 时用得上。
func _make_empty_row(slot: int) -> Control:
	return _make_note_row("空位 %d —— 去地图上找「队友」NPC 招募" % (slot + 1))


## 造一行说明文字（不可点、不可聚焦），用于空位提示 / 团队为空时的指路。
func _make_note_row(text: String) -> Control:
	var row := HBoxContainer.new()
	row.name = "NoteRow"
	row.custom_minimum_size = Vector2(0, 44)
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 18)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.modulate = Color(1, 1, 1, 0.4)
	row.add_child(label)
	return row


## 属性文字。用 Global.format_stat() 统一"整数不带小数点"的显示规则 ——
## 招募面板（WorldMap）用的是同一个函数，两处显示不会出现 25 与 25.0 这种不一致。
func _stats_text(stats: UnitStats) -> String:
	return "HP %s · 伤害 %s · 速度 %s · 幸运 %s · 格挡 %s%%" % [
		Global.format_stat(stats.health),
		Global.format_stat(stats.damage),
		Global.format_stat(stats.speed),
		Global.format_stat(stats.luck),
		Global.format_stat(stats.block_chance),
	]


## 「上阵」回调：只发请求（见文件头"UI 只请求、GameRoot 才改数据"）。
func _on_deploy_pressed(stats: UnitStats) -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	deploy_requested.emit(stats)


## 「下阵」回调：同上，只发请求。
func _on_undeploy_pressed(stats: UnitStats) -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	undeploy_requested.emit(stats)


## 「移出团队」回调：只发请求。
func _on_remove_pressed(stats: UnitStats) -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	remove_requested.emit(stats)


func _emit_close() -> void:
	close_requested.emit()
