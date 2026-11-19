extends RefCounted

## 共用界面样式。下列颜色是绢纸卷轴的原始色值。
const UiSkin := preload("res://styles/ui_skin.gd")
const INK := Color("#433123")
const SOFT_INK := Color("#6c563f")
const VERMILION := Color("#894434")
const PAPER := Color("#dac19b")
const INSET := Color("#c4a880")
const EDGE := Color("#b4976b")
const PALE_EDGE := Color("#ad9069")
const THEME := UiSkin.THEME
const PORTRAIT_WASH := preload("res://assets/ui/paper_portrait.png")
const INK_TONES := {
	"433123": "#e7eef3", "6c563f": "#aac0ca", "894434": "#f08ea9",
	"dac19b": "#354b57", "c4a880": "#233840", "b4976b": "#688594",
	"ad9069": "#526e7c", "f2e2c0": "#2b414a", "efd5b2": "#3c485e",
	"983c30": "#ff9c94", "2b684c": "#9ce2b6", "2b557b": "#acd3fb",
	"477756": "#79be95", "a34f45": "#e88481", "49352b": "#243544",
	"256247": "#99e0b1", "175e64": "#8cdbdf", "775119": "#efd1a0",
	"76511e": "#f2d7a2", "255477": "#a7d2ff", "69417f": "#d4b2f4",
	"8e3e67": "#edadd1", "904c1d": "#ffb989", "9c342a": "#ffa19a",
	"695844": "#b5c6ce",
}


static func tone(original: Color) -> Color:
	if not UiSkin.is_ink():
		return original
	var mapped: String = INK_TONES.get(original.to_html(false), "")
	return Color(mapped, original.a) if not mapped.is_empty() else original


## 装饰与样式跟随皮肤，节点离树时解除监听。
static func bind(control: Node, refresh: Callable) -> void:
	refresh.call()
	UiSkin.changed().connect(refresh)
	control.tree_exiting.connect(func(): UiSkin.changed().disconnect(refresh), CONNECT_ONE_SHOT)


static func bind_panel(control: Control, source_type: StringName, margins: Vector4) -> void:
	bind(control, func():
		var style := THEME.get_stylebox(&"panel", source_type).duplicate() as StyleBox
		style.content_margin_left = margins.x
		style.content_margin_top = margins.y
		style.content_margin_right = margins.z
		style.content_margin_bottom = margins.w
		control.add_theme_stylebox_override("panel", style))


static func add_heading(content: VBoxContainer, title: String, mark: String) -> void:
	var heading := Label.new()
	heading.text = title
	content.add_child(heading)
	content.move_child(heading, 0)
	style_heading(heading, mark)


static func style_heading(heading: Label, mark: String, title_scale := 1.0) -> void:
	var parent := heading.get_parent()
	var index := heading.get_index()
	var header := VBoxContainer.new()
	header.add_theme_constant_override("separation", roundi(4.0 * title_scale))
	parent.add_child(header)
	parent.move_child(header, index)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", roundi(12.0 * title_scale))
	header.add_child(row)
	var seal := Label.new()
	seal.theme_type_variation = &"PaperSeal"
	seal.custom_minimum_size = Vector2(36, 36) * title_scale
	if title_scale != 1.0:
		var font_size := THEME.get_font_size(&"font_size", &"PaperSeal")
		seal.add_theme_font_size_override("font_size", roundi(font_size * title_scale))
	seal.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	seal.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	seal.text = mark
	row.add_child(seal)
	heading.reparent(row, false)
	heading.theme_type_variation = &"PaperHeading"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	heading.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(HSeparator.new())


static func add_shortcut(content: VBoxContainer, shortcut: String, caption: String) -> Label:
	var row := HBoxContainer.new()
	content.add_child(row)
	row.add_theme_constant_override("separation", 8)
	var key := Label.new()
	key.theme_type_variation = &"PaperKey"
	key.text = shortcut
	row.add_child(key)
	var label := Label.new()
	label.add_theme_font_size_override("font_size", 15)
	label.text = caption
	row.add_child(label)
	bind(label, func(): label.add_theme_color_override("font_color", tone(SOFT_INK)))
	return label


## 大幅纸面的纤维和淡墨印在内容下面，纹理平铺，山形等比缩放。
static func add_panel_pattern(frame: Control) -> void:
	if frame == null:
		return
	var pattern := Control.new()
	pattern.name = "PaperPattern"
	pattern.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pattern.clip_contents = true
	frame.add_child(pattern)
	frame.move_child(pattern, 0)
	bind(pattern, func(): pattern.visible = not UiSkin.is_ink())
	if not frame is Container:
		pattern.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		pattern.offset_left = 17
		pattern.offset_top = 17
		pattern.offset_right = -17
		pattern.offset_bottom = -17

	var fibers := TextureRect.new()
	fibers.texture = load("res://assets/ui/paper_fibers.png") as Texture2D
	fibers.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	fibers.stretch_mode = TextureRect.STRETCH_TILE
	fibers.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	fibers.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pattern.add_child(fibers)
	fibers.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var landscape := TextureRect.new()
	landscape.texture = load("res://assets/ui/paper_landscape.png") as Texture2D
	landscape.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	landscape.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pattern.add_child(landscape)
	if landscape.texture != null:
		var original_size := landscape.texture.get_size()
		var place_landscape := func() -> void:
			var room := pattern.size * Vector2(0.90, 0.75)
			var factor := minf(room.x / original_size.x, room.y / original_size.y)
			landscape.size = original_size * factor
			landscape.position = pattern.size - landscape.size
		pattern.resized.connect(place_landscape)
		place_landscape.call()


static func add_portrait_wash(frame: Control) -> void:
	var wash := TextureRect.new()
	wash.texture = PORTRAIT_WASH
	wash.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	wash.stretch_mode = TextureRect.STRETCH_SCALE
	wash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(wash)
	frame.move_child(wash, 0)
	bind(wash, func(): wash.visible = not UiSkin.is_ink())
	wash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	wash.offset_left = 3
	wash.offset_top = 3
	wash.offset_right = -3
	wash.offset_bottom = -3


static func quality_fill(tier_color: Color, weight: float) -> Color:
	return tone(PAPER).lerp(Color(tone(tier_color), 1.0), weight)


static func quality_edge(tier_color: Color) -> Color:
	return tone(SOFT_INK).lerp(Color(tone(tier_color), 1.0), 0.55)
