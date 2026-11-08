extends PanelContainer
class_name MsgLog

## 左下角常驻消息栏（地图 / 战斗共用）。
##
## 结构：PanelContainer → ScrollContainer → VBoxContainer(每行一个 Label)
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
	offset_left = 16.0
	offset_right = 16.0 + WIDTH
	# 高度 = 7 行 + 内边距；用 top 负偏移把底边钉在屏幕下方
	var content_h := float(VISIBLE_ROWS * LINE_HEIGHT)
	offset_top = -(content_h + 16.0 + 12.0)
	offset_bottom = -16.0

	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.04, 0.06, 0.08, 0.62)
	box.border_color = Color(0.75, 0.68, 0.50, 0.28)
	box.set_border_width_all(1)
	box.set_corner_radius_all(6)
	box.content_margin_left = 8
	box.content_margin_right = 8
	box.content_margin_top = 6
	box.content_margin_bottom = 6
	add_theme_stylebox_override("panel", box)

	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.custom_minimum_size = Vector2(WIDTH - 16.0, content_h)
	_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	_scroll.clip_contents = true
	_scroll.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	add_child(_scroll)

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
	stamp.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	stamp.add_theme_font_size_override("font_size", 17)
	stamp.add_theme_color_override("font_color", Color(0.62, 0.66, 0.62, 0.9))
	stamp.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	stamp.add_theme_constant_override("outline_size", 3)
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
	label.add_theme_color_override("default_color", Color(0.88, 0.90, 0.86))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	label.add_theme_constant_override("outline_size", 3)
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
	var tier_colors := {
		"白": Color(0.82, 0.82, 0.82),
		"蓝": Color(0.42, 0.72, 1.00),
		"紫": Color(0.76, 0.52, 1.00),
		"粉": Color(1.00, 0.58, 0.88),
		"橙": Color(1.00, 0.72, 0.32),
	}
	if text.contains("掉落") or text.contains("装备"):
		for key in tier_colors.keys():
			if text.contains("（%s）" % key) or text.contains("(%s)" % key):
				return tier_colors[key]

	if text.contains("胜利"):
		return Color(0.42, 1.00, 0.76)
	if text.contains("失败") or text.contains("无法") or text.contains("不足"):
		return Color(1.00, 0.48, 0.42)
	if text.contains("升级") or text.contains("等级"):
		return Color(0.55, 0.95, 1.00)
	if text.contains("金币") or text.contains("获得") or text.contains("奖励"):
		return Color(1.00, 0.86, 0.40)
	# 巡逻开关：开=青绿，关=灰白
	if text.begins_with("开始自动巡逻"):
		return Color(0.42, 1.00, 0.76)
	if text.begins_with("停止自动巡逻"):
		return Color(0.80, 0.82, 0.78)
	# 欢迎语 / 开局提示：金色
	if text.begins_with("欢迎") or text.begins_with("【开局】"):
		return Color(1.00, 0.86, 0.40)
	# 抵达某地：整条用金色，地图名也跟着亮起来
	if text.begins_with("抵达"):
		return Color(1.00, 0.86, 0.40)
	if text.contains("买下") or text.contains("卖出"):
		return Color(0.98, 0.90, 0.62)
	if text.contains("拜师") or text.contains("门派"):
		return Color(0.82, 0.70, 1.00)
	if text.contains("上阵") or text.contains("下阵") or text.contains("队伍"):
		return Color(0.72, 0.92, 0.98)
	return Color(0.88, 0.90, 0.86)


## 中文颜色标签 → BBCode 颜色。写消息时直接用中文，调用方不用记色值。
const CN_COLORS := {
	"绿色": "#6bffc2",
	"青色": "#8cf2ff",
	"金色": "#ffdb66",
	"黄色": "#ffe082",
	"蓝色": "#6bb8ff",
	"紫色": "#c285ff",
	"粉色": "#ff94e0",
	"橙色": "#ffb852",
	"红色": "#ff7a6b",
	"白色": "#e6e8e2",
	"灰色": "#9aa09a",
}


## 把 "[绿色]xxx[/绿色]" 换成 "[color=#6bffc2]xxx[/color]"。
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
