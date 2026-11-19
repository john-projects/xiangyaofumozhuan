extends RefCounted

const Paper := preload("res://styles/paper_ui.gd")

static var _icons: Dictionary[Texture2D, Texture2D] = {}


static func icon_for(texture: Texture2D) -> Texture2D:
	if texture == null:
		return null
	if not _icons.has(texture):
		_icons[texture] = _trim_icon(texture)
	return _icons[texture]


## 取透明边以内的图像区域。沿用原纹理，保持比例，也不重复读像素。
static func _trim_icon(texture: Texture2D) -> Texture2D:
	var image := texture.get_image()
	if image == null or image.is_empty():
		return texture
	if image.is_compressed() and image.decompress() != OK:
		return texture
	var bounds := image.get_used_rect()
	if not bounds.has_area() or bounds == Rect2i(Vector2i.ZERO, image.get_size()):
		return texture
	var trimmed := AtlasTexture.new()
	trimmed.atlas = texture
	trimmed.region = Rect2(bounds)
	trimmed.filter_clip = true
	return trimmed


static func add_type_label(slot: Button, slot_type: int) -> void:
	var label := Label.new()
	label.name = "SlotTypeLabel"
	label.text = ItemBase.equip_type_name(slot_type)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 13)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(label)


static func update_type_label(label: Label, has_item: bool) -> void:
	if label == null:
		return
	label.anchor_left = 0.0
	label.anchor_right = 1.0
	label.anchor_top = 1.0 if has_item else 0.0
	label.anchor_bottom = 1.0
	label.offset_left = 3.0
	label.offset_right = -3.0
	label.offset_top = -22.0 if has_item else 0.0
	label.offset_bottom = -2.0 if has_item else 0.0
	label.add_theme_color_override("font_color", Color.WHITE if has_item else Paper.tone(Paper.SOFT_INK))
	label.add_theme_color_override("font_outline_color", Color(0.03, 0.04, 0.06, 0.96))
	label.add_theme_constant_override("outline_size", 4 if has_item else 0)


static func style(border: Color, background: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Paper.tone(background)
	box.border_color = Paper.tone(border)
	box.set_border_width_all(2)
	box.set_corner_radius_all(6)
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		box.set_content_margin(side, 2)
	return box
