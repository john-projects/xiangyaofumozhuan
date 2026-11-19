extends RefCounted

const THEME := preload("res://styles/paper_theme.tres")
const PAPER := &"paper"
const INK := &"ink"
const CONFIG_PATH := "user://ui_skin.cfg"

class SkinEvents:
	extends RefCounted
	signal changed

static var _events := SkinEvents.new()
static var _paper_theme := THEME.duplicate() as Theme
static var _active := PAPER


static func changed() -> Signal:
	return _events.changed


static func is_ink() -> bool:
	return _active == INK


static func display_name() -> String:
	return "玄青银边" if is_ink() else "绢纸卷轴"


static func load_preference() -> void:
	var config := ConfigFile.new()
	if config.load(CONFIG_PATH) == OK:
		_apply(StringName(str(config.get_value("ui", "skin", PAPER))))


static func cycle() -> void:
	if not _apply(PAPER if is_ink() else INK):
		return
	var config := ConfigFile.new()
	config.set_value("ui", "skin", String(_active))
	var error := config.save(CONFIG_PATH)
	if error != OK:
		push_warning("皮肤已切换，本次设置保存失败（%s）。" % error_string(error))


static func _apply(id: StringName) -> bool:
	if id == _active:
		return false
	var source := _paper_theme
	if id == INK:
		source = load("res://styles/ink_theme.tres") as Theme
	elif id != PAPER:
		return false
	if source == null:
		return false
	_active = id
	THEME.clear()
	THEME.merge_with(source)
	THEME.set_default_font(source.default_font)
	THEME.set_default_font_size(source.default_font_size)
	_events.changed.emit()
	return true


static func refresh_screen_frame(frame: NinePatchRect) -> void:
	var path := "res://assets/ui/ink_screen_frame.png" if is_ink() else "res://assets/ui/paper_screen_frame.png"
	frame.texture = load(path) as Texture2D
