extends PanelContainer
class_name MsgLog

const Paper := preload("res://styles/paper_ui.gd")

## 左下角常驻消息栏（地图 / 战斗共用）。
##
## 结构：纸面消息框与可滚动的消息列表。
##   · 固定显示 VISIBLE_ROWS 行高度，多了靠滚轮/拖动往上翻
##   · 最多保留 max_lines 行，超了从最旧的开始删
##   · 新消息自动滚到底；玩家往上翻时不会被强行拉回（除非本来就在底部）

const VISIBLE_ROWS := 10
const LINE_HEIGHT := 26
const WIDTH := 540.0

var max_lines := 300

## 是否跟随最新消息（在底部 = true，玩家往上滚就变 false）。
var _follow := true
## 判定"在底部"的容差（像素）。
const BOTTOM_TOLERANCE := 24.0


var _scroll: ScrollContainer = null
var _lines: VBoxContainer = null


func setup(p_max_lines := 300) -> void:
	max_lines = p_max_lines
	name = "MsgLog"
	mouse_filter = Control.MOUSE_FILTER_STOP
	# ⚠ 必须裁剪：向上滚时旧行会画到框外，看起来底部多一层
	clip_contents = true
	anchor_left = 0.0
	anchor_right = 0.0
	anchor_top = 1.0
	anchor_bottom = 1.0
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	offset_left = 16.0
	offset_right = 16.0 + WIDTH
	var content_h := float(VISIBLE_ROWS * LINE_HEIGHT)
	offset_bottom = -16.0
	theme = preload("res://styles/paper_theme.tres")
	var frame := get_theme_stylebox("panel", &"Panel").duplicate() as StyleBox
	frame.content_margin_left = 17
	frame.content_margin_right = 17
	frame.content_margin_top = 12
	frame.content_margin_bottom = 12
	add_theme_stylebox_override("panel", frame)

	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.custom_minimum_size = Vector2(0, content_h)
	_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	_scroll.clip_contents = true
	_scroll.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	add_child(_scroll)
	offset_top = offset_bottom - get_combined_minimum_size().y

	_lines = VBoxContainer.new()
	_lines.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lines.add_theme_constant_override("separation", 2)
	_scroll.add_child(_lines)

	# 滚动条一动就重新判定"是否还在底部"
	_scroll.get_v_scroll_bar().value_changed.connect(_on_scroll_changed)
	_follow = true

	visible = false


func push(text: String) -> void:
	var t := text.strip_edges()
	if t.is_empty():
		return
	if _lines == null:
		return

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 6)

	# 时间戳：紧凑的 [HH:MM]，固定宽度，不换行
	var stamp := Label.new()
	var now := Time.get_time_dict_from_system()
	stamp.text = "[%02d:%02d]" % [int(now["hour"]), int(now["minute"])]
	stamp.custom_minimum_size = Vector2(60, 0)
	stamp.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	stamp.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	stamp.add_theme_font_size_override("font_size", 17)
	stamp.add_theme_color_override("font_color", Paper.SOFT_INK)
	stamp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(stamp)

	# RichTextLabel：支持一条消息里多段不同颜色（[绿色]名字[/绿色]获得[金色]经验[/金色]）
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("normal_font_size", 18)
	label.add_theme_color_override("default_color", Paper.INK)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.text = _bbcode_for(t)
	row.add_child(label)

	_lines.add_child(row)

	while _lines.get_child_count() > max_lines:
		var old := _lines.get_child(0)
		_lines.remove_child(old)
		old.queue_free()

	visible = true
	# 内容还没撑满，或玩家本来就停在底部 → 自动跟随
	if _follow or _content_fits():
		_scroll_to_bottom.call_deferred()


func _is_at_bottom() -> bool:
	if _scroll == null:
		return true
	var bar := _scroll.get_v_scroll_bar()
	if bar == null:
		return true
	# 内容还没超出可视区：永远算在底部
	if bar.max_value <= bar.page + BOTTOM_TOLERANCE:
		return true
	return bar.value >= bar.max_value - bar.page - BOTTOM_TOLERANCE


## 内容是否还没撑满可视区。
func _content_fits() -> bool:
	if _scroll == null:
		return true
	var bar := _scroll.get_v_scroll_bar()
	if bar == null:
		return true
	return bar.max_value <= bar.page + BOTTOM_TOLERANCE


## 滚动条变化：更新跟随标志（自己滚到底也会把它设回 true）。
func _on_scroll_changed(_value: float) -> void:
	_follow = _is_at_bottom()


func _scroll_to_bottom() -> void:
	if _scroll == null:
		return
	await get_tree().process_frame          # 等布局算完，max_value 才是新的
	if _scroll == null or not is_instance_valid(_scroll):
		return
	var bar := _scroll.get_v_scroll_bar()
	if bar != null:
		_scroll.scroll_vertical = int(bar.max_value)
		_follow = true


## 清空（换图时用）。
func clear() -> void:
	if _lines == null:
		return
	for c in _lines.get_children():
		_lines.remove_child(c)
		c.queue_free()
	visible = false

## 按消息内容挑一个颜色（调用方不用传，自动判定）。
func _color_for(text: String) -> Color:
	if text.contains("掉落") or text.contains("装备"):
		for tier in TIER_INK:
			if text.contains("（%s）" % tier) or text.contains("(%s)" % tier):
				return Color(CN_COLORS[TIER_INK[tier]])

	if text.contains("胜利") or text.begins_with("开始自动巡逻"):
		return Color(CN_COLORS["绿色"])
	if text.contains("失败") or text.contains("无法") or text.contains("不足"):
		return Color(CN_COLORS["红色"])
	if text.contains("升级") or text.contains("等级"):
		return Color(CN_COLORS["青色"])
	if text.contains("金币") or text.contains("获得") or text.contains("奖励") \
			or text.begins_with("欢迎") or text.begins_with("【开局】") or text.begins_with("抵达") \
			or text.contains("买下") or text.contains("卖出"):
		return Color(CN_COLORS["金色"])
	if text.begins_with("停止自动巡逻"):
		return Paper.SOFT_INK
	if text.contains("拜师") or text.contains("门派"):
		return Color(CN_COLORS["紫色"])
	if text.contains("上阵") or text.contains("下阵") or text.contains("队伍"):
		return Color(CN_COLORS["蓝色"])
	return Paper.INK


## 保留中文颜色标签，字色适配浅纸面。
const CN_COLORS := {
	"绿色": "#256247",
	"青色": "#175e64",
	"金色": "#775119",
	"黄色": "#76511e",
	"蓝色": "#255477",
	"紫色": "#69417f",
	"粉色": "#8e3e67",
	"橙色": "#904c1d",
	"红色": "#9c342a",
	"白色": "#433123",
	"灰色": "#695844",
}
const TIER_INK := {"白": "白色", "蓝": "蓝色", "紫": "紫色", "粉": "粉色", "橙": "橙色"}


## 把 "[绿色]xxx[/绿色]" 换成 "[color=#256247]xxx[/color]"。
func _to_bbcode(text: String) -> String:
	var out := text
	for cn in CN_COLORS.keys():
		out = out.replace("[%s]" % cn, "[color=%s]" % CN_COLORS[cn])
		out = out.replace("[/%s]" % cn, "[/color]")
	return out


## 这条消息里有没有写任何中文颜色标签。
func _has_cn_tag(text: String) -> bool:
	for cn in CN_COLORS.keys():
		if text.contains("[%s]" % cn):
			return true
	return false


## 生成最终的 BBCode：有标签就用标签，没标签就整条套 _color_for 的颜色。
func _bbcode_for(text: String) -> String:
	if _has_cn_tag(text):
		return _to_bbcode(text)
	var c := _color_for(text)
	return "[color=#%s]%s[/color]" % [c.to_html(false), text]
