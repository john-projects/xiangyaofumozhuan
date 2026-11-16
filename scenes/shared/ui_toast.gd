extends RefCounted

const Paper := preload("res://styles/paper_ui.gd")
## 全局统一的「弹窗消息」外观与时长。
##
## 为什么不用 class_name：全局类名要编辑器扫描后才进缓存，命令行/CI 里可能还没注册。
## 用 `const UiToast := preload("res://scenes/shared/ui_toast.gd")` 引用，任何环境都能解析。
##
## 为什么要有这个东西：地图上的提示条（WorldMap）和团体面板的提示（PartyPanel）
## 原来各写一套配色/圆角/时长，长得不一样 —— 一眼就看出"这两个弹窗不是一个东西"。
## 现在两边都从这里取，改一次全局生效。
##
## 用法（两种都行）：
##   var box := UiToast.make_box("夜魑 已上阵。")      # 自己塞进某个容器
##   UiToast.apply_style(some_panel_container)         # 只借样式

## 停留时长（秒）。
const HOLD := 1.5
## 淡出时长（秒）。
const FADE := 0.35
## 标准宽度（像素）。
const WIDTH := 720.0
## 文字金色、黑色描边 —— 底板调透之后仍然清楚。
const TEXT_COLOR := Color(1.0, 0.88, 0.60, 1.0)
const OUTLINE_COLOR := Color(0.03, 0.02, 0.01, 0.9)
const OUTLINE_SIZE := 4
const FONT_SIZE := 20


## 短提示复用地图题牌的暗底和四角边饰。
static func make_style() -> StyleBox:
	return Paper.THEME.get_stylebox(&"normal", &"PaperPatrol")


## 按统一规格配好的文字（靠左、自动换行、支持 [绿色]xxx[/绿色] 多段染色）。
## 靠左而不是居中：条宽固定，长短不一的提示居中对齐会参差不齐。
static func make_label(text: String) -> RichTextLabel:
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(WIDTH - 32.0, 0)
	label.add_theme_font_size_override("normal_font_size", FONT_SIZE)
	label.add_theme_color_override("default_color", TEXT_COLOR)
	label.add_theme_color_override("font_outline_color", OUTLINE_COLOR)
	label.add_theme_constant_override("outline_size", OUTLINE_SIZE)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.text = to_bbcode(text)
	return label


## 一条完整的提示弹窗（底板 + 文字）。调用方负责 add_child 与生命周期。
static func make_box(text: String) -> PanelContainer:
	var box := PanelContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.theme = Paper.THEME
	box.add_theme_stylebox_override("panel", make_style())
	box.add_child(make_label(text))
	return box


## 给场景里已有的 PanelContainer / Label 套上统一样式（团体面板用的是这条）。
static func apply_style(container: PanelContainer) -> void:
	if container != null:
		container.add_theme_stylebox_override("panel", make_style())
		container.mouse_filter = Control.MOUSE_FILTER_IGNORE


## 套样式的文字标签版本（场景里已有的 Label）。
static func apply_label_style(label: Label) -> void:
	if label == null:
		return
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", FONT_SIZE)
	label.add_theme_color_override("font_color", TEXT_COLOR)
	label.add_theme_color_override("font_outline_color", OUTLINE_COLOR)
	label.add_theme_constant_override("outline_size", OUTLINE_SIZE)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE

## 中文颜色标签 → BBCode（和 msg_log.gd 同一套色值）。
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


## 有中文标签就转 BBCode，没有就整条套默认金色。
static func to_bbcode(text: String) -> String:
	var out := text
	var tagged := false
	for cn in CN_COLORS.keys():
		if out.contains("[%s]" % cn):
			tagged = true
			out = out.replace("[%s]" % cn, "[color=%s]" % CN_COLORS[cn])
		out = out.replace("[/%s]" % cn, "[/color]")
	if tagged:
		return out
	return "[color=#%s]%s[/color]" % [TEXT_COLOR.to_html(false), text]
