extends HBoxContainer

signal shortcut_pressed(action: StringName)

const Paper := preload("res://styles/paper_ui.gd")
const ICON_CELL := 96
const ICON_SIZE := 58
const SHORTCUTS := [
	[&"bag", "背包", "打开背包（B）"],
	[&"stats", "属性", "打开角色属性（C）"],
	[&"party", "团队", "管理团队"],
	[&"auto_cast", "自动", "设置自动施法"],
	[&"skin", "皮肤", "切换界面皮肤"],
	[&"system", "系统", "打开系统菜单（Esc）"],
]

var _rail := StyleBoxFlat.new()
var _skin_button: Button


func _ready() -> void:
	var atlas := load("res://assets/ui/map_shortcuts_color.png") as Texture2D
	var hover := _plate(Color(0.08, 0.12, 0.10, 0.88), Color("#b8a16d"))
	var pressed := _plate(Color(0.03, 0.06, 0.05, 0.96), Color("#8b764c"))
	for index in SHORTCUTS.size():
		var entry: Array = SHORTCUTS[index]
		var button := Button.new()
		button.name = entry[0]
		button.accessibility_name = entry[1]
		button.tooltip_text = entry[2]
		button.custom_minimum_size = Vector2(62, 62)
		button.flat = true
		button.focus_mode = Control.FOCUS_NONE
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		button.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		button.icon = _tile(atlas, index)
		button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		button.expand_icon = true
		button.add_theme_constant_override("icon_max_width", ICON_SIZE)
		button.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
		button.add_theme_stylebox_override("hover", hover)
		button.add_theme_stylebox_override("pressed", pressed)
		button.pressed.connect(shortcut_pressed.emit.bind(entry[0]))
		add_child(button)
		if entry[0] == &"skin":
			_skin_button = button

	_rail.set_border_width_all(1)
	_rail.set_corner_radius_all(4)
	_rail.shadow_color = Color(0.0, 0.0, 0.0, 0.62)
	_rail.shadow_size = 2
	resized.connect(queue_redraw)
	Paper.bind(self, _refresh_skin)


func _draw() -> void:
	if size.x > 0.0:
		var top := size.y * 0.5
		var bottom := size.y - offset_bottom - MsgLog.visible_bottom_inset()
		draw_style_box(_rail, Rect2(-3.0, top, size.x + 6.0, bottom - top))


func _tile(atlas: Texture2D, index: int) -> AtlasTexture:
	var tile := AtlasTexture.new()
	tile.atlas = atlas
	tile.region = Rect2(index * ICON_CELL, 0, ICON_CELL, ICON_CELL)
	tile.filter_clip = true
	return tile


func _plate(fill: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(5)
	return style


func _refresh_skin() -> void:
	var ink := Paper.UiSkin.is_ink()
	_rail.bg_color = Color("#17252a") if ink else Color("#19221a")
	_rail.border_color = Color("#7698a7") if ink else Color("#9e8554")
	_skin_button.tooltip_text = "切换界面皮肤（当前：%s）" % Paper.UiSkin.display_name()
	queue_redraw()
