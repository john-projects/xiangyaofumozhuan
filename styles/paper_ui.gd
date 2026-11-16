extends RefCounted

## 地图菜单共用的绢纸样式。控件仍由各面板管理。
const INK := Color("#433123")
const SOFT_INK := Color("#6c563f")
const VERMILION := Color("#894434")
const PAPER := Color("#dac19b")
const INSET := Color("#c4a880")
const EDGE := Color("#b4976b")
const PALE_EDGE := Color("#ad9069")
const THEME := preload("res://styles/paper_theme.tres")
const PORTRAIT_WASH := preload("res://assets/ui/paper_portrait.png")


static func add_heading(content: VBoxContainer, title: String, mark: String) -> void:
	var heading := Label.new()
	heading.text = title
	content.add_child(heading)
	content.move_child(heading, 0)
	style_heading(heading, mark)


static func style_heading(heading: Label, mark: String) -> void:
	var parent := heading.get_parent()
	var index := heading.get_index()
	var header := VBoxContainer.new()
	header.add_theme_constant_override("separation", 4)
	parent.add_child(header)
	parent.move_child(header, index)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	header.add_child(row)
	var seal := Label.new()
	seal.theme_type_variation = &"PaperSeal"
	seal.custom_minimum_size = Vector2(36, 36)
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
	label.add_theme_color_override("font_color", SOFT_INK)
	label.text = caption
	row.add_child(label)
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
	wash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	wash.offset_left = 3
	wash.offset_top = 3
	wash.offset_right = -3
	wash.offset_bottom = -3


static func quality_fill(tier_color: Color, weight: float) -> Color:
	return PAPER.lerp(Color(tier_color, 1.0), weight)


static func quality_edge(tier_color: Color) -> Color:
	return SOFT_INK.lerp(Color(tier_color, 1.0), 0.55)
