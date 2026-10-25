## HealthBar —— 单位头顶的血条 / 蓝条（一个 ProgressBar + 一个叠在中间的 Label）
##
## 同一个脚本服务两种条，行为一样，只靠 @export 颜色区分；唯一使用方是 battle_unit.tscn
## （%HealthBar 与 %ManaBar），由 battle_unit.gd 的 _refresh_*() 主动调 update_bar()。
## 数值约定：health_bar.tscn 里 ProgressBar 的 max_value 固定 1.0、show_percentage = false，
## 所以传入的 value 必须是 0~1 的比例（不是血量本身），具体血量由中间的 HealthAmount 显示。
## 坑：改颜色前必须 duplicate() StyleBox —— 实例之间共享同一份子资源（见 _ready）。
## 坑：@export 颜色没写默认值，.tscn 没填就是全黑条；本节点默认吃鼠标，battle_unit 里设成 IGNORE。
extends Control
class_name HealthBar

## 槽底颜色（0~1 浮点 RGBA）。只在 _ready() 读一次做成主题覆盖，运行期改它不生效。
@export var back_color: Color
## 进度条颜色（0~1 浮点 RGBA）。同上，也只 _ready() 读一次。
@export var fill_color: Color

## 两个都是普通子节点路径（health_bar.tscn 没勾 unique_name_in_owner，不能用 %）。
## progress_bar：max_value = 1.0，所以吃 0~1 的比例值。
## health_amount：叠在条正中间、锚点铺满的 Label，显示具体血量（字符串）。
@onready var progress_bar: ProgressBar = $ProgressBar
@onready var health_amount: Label = $HealthAmount


## 把两个 @export 颜色写进 ProgressBar 的主题覆盖（"background" 槽底 / "fill" 前景）。
## 副作用：只改本实例的 progress_bar；不 emit 信号、不碰 Global。_init 里做不了（子节点还不存在）。
func _ready() -> void:
	# ★ .duplicate() 不能省：get_theme_stylebox() 返回场景里的资源本体，多实例共享，就地改会污染所有血条。
	var back_style := progress_bar.get_theme_stylebox("background").duplicate()
	back_style.bg_color = back_color
	# 同理：进度前景也复制一份再上色。
	var fill_style := progress_bar.get_theme_stylebox("fill").duplicate()
	fill_style.bg_color = fill_color
	# 键名必须正好是 "background" / "fill"（ProgressBar 主题的固定项），写错不报错、只是颜色不生效。
	progress_bar.add_theme_stylebox_override("background", back_style)
	progress_bar.add_theme_stylebox_override("fill", fill_style)

## 运行期改进度条颜色（battle_unit 给敌人血条染红用；_ready 之后才调得到）。
## 副作用：只改本实例 progress_bar 的 "fill" 覆盖，不动 _ready 里已设好的槽底。
func set_fill_color(color: Color) -> void:
	fill_color = color
	var fill_style := progress_bar.get_theme_stylebox("fill").duplicate()
	fill_style.bg_color = color
	progress_bar.add_theme_stylebox_override("fill", fill_style)

## 刷新血条（对外主入口，battle_unit.gd 也直接调）。
## 参数 value：0.0~1.0 的**比例**（max_value = 1.0，传血量本身会一直满）；health：中间显示的具体数值。
## 显示一律取整（format_stat 四舍五入），内部数值仍保留小数。
## 副作用：只写 progress_bar.value 与 health_amount.text，不 emit 信号、不读写 Global。
func update_bar(value: float, health: float) -> void:
	progress_bar.value = value
	health_amount.text = Global.format_stat(health)

## HealthComponent.on_health_changed 的回调（旧链路已随竞技场移除，保留成通用入口）。
## 参数 current：当前血量；max_value：最大血量。副作用：转调 update_bar()，不改任何游戏状态。
## ⚠ 函数名是编辑器连线用的，改名会静默断线；max_value 为 0 时比例是 inf/nan（ProgressBar 自己夹住）。
func _on_health_component_on_health_changed(current: float, max_value: float) -> void:
	# 换算成 0~1 的比例再交给进度条（它的 max_value 是 1.0）。
	var value = current / max_value
	update_bar(value, current)
