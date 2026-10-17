## ═══════════════════════════════════════════════════════════════════════════
## HealthBar —— 单位头顶的血条 / 蓝条（一个 ProgressBar + 一个叠在中间的 Label）
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   同一个脚本服务两种条：血条和蓝条 —— 行为完全一样，只靠 @export 的颜色区分。
##   唯一的使用方：scenes/battle/battle_unit.tscn（回合制战斗）放了 **2 个**
##   （%HealthBar 与 %ManaBar），两个都在场景里显式填了 back_color / fill_color；
##   由 battle_unit.gd 的 _refresh_visuals() / _refresh_hp() / _refresh_mana() 主动调 update_bar() 刷新。
##   （竞技场时代在 scenes/unit/unit.tscn 里还挂过一个走 HealthComponent 信号的实例，已随竞技场移除。）
##   两种玩法共用一个控件，但**数据入口不同**（一个靠信号、一个靠直接调用），改动时两边都要顾及。
##
## 数据流：
##   主动调用入口：battle_unit.gd 直接 update_bar(hp / max_hp, hp)，比例由调用方自己算。
##   （竞技场时代还有一条"HealthComponent.on_health_changed → 本文件"的编辑器连线，
##     那条链随竞技场一起删掉了；下面 _on_health_component_on_health_changed 保留成通用入口。）
##
## 数值约定（最容易踩的一点）：
##   health_bar.tscn 里 ProgressBar 的 max_value 被固定成 1.0、show_percentage = false，
##   所以传进来的 value 必须是 **0~1 的比例**（不是血量本身）；
##   具体血量另有一个 Label（HealthAmount）负责显示 —— 那个"百分比数字"是关掉的，
##   中间的数字其实是这个 Label 叠上去的。
##
## 坑：
##   · _ready() 里必须先 duplicate() 再改 bg_color：get_theme_stylebox() 返回的是场景里
##     那个 StyleBoxFlat 资源本体，而 PackedScene.instantiate() 出来的多个实例**共享同一份子资源**；
##     不复制就地改色，会把所有血条/蓝条（以及任何引用同一风格的地方）一起改掉 ——
##     这就是"共享 Resource 就地修改会污染所有引用者"。
##   · 两个 @export 颜色**没有写默认值**（Color 的默认值是 Color(0,0,0,1) 黑色），
##     而 _ready() 会无条件把它写进覆盖样式 —— 所以 .tscn 里**没填**这两个颜色的实例
##     运行时会变成一条全黑的条。
##     现在唯一的实例是 battle_unit.tscn（血条一套 + 蓝条一套，都填了颜色）。
##     （health_bar.tscn 里那套"深红底 + 亮粉条"的 StyleBoxFlat 只是编辑器里的默认外观，
##      一进 _ready() 就被 @export 的黑色覆盖掉了 —— 这是本文件最容易看走眼的一点。）
##   · 本类直接继承 Control，没有需要自己初始化的父脚本，所以 _ready() 不需要 super._ready()。
##   · 本节点是 Control，默认会吃掉鼠标事件；它会挡住"点击单位选目标"，
##     所以 battle_unit.gd 里专门用 _ignore_mouse() 把它的 mouse_filter 设成 IGNORE。
extends Control
class_name HealthBar

## ── 视觉（颜色，单位都是 0~1 的浮点 RGBA）────────────────────────────────
## 只在 _ready() 里读一次并做成主题覆盖（theme override）。
## 运行期再改这两个变量**不会**自动生效 —— 想动态换色得自己再调一次
## add_theme_stylebox_override()，或者直接改 progress_bar 上的覆盖样式。
## 取值参考（.tscn 里实际填的，都是 0~1 浮点 RGBA）：
##   · battle_unit.tscn 血条：(0.08, 0.08, 0.10) 深灰底 + (0.35, 0.85, 0.40) 绿；
##   · battle_unit.tscn 蓝条：(0.06, 0.07, 0.12) + (0.32, 0.58, 0.95) 蓝；
##   · player_well_rounded.tscn 血条：暗红底 + 亮粉 (1, 0.282, 0.455)；
##   · enemy_chaser_slow.tscn 血条：深蓝底 + 灰蓝 (0.373, 0.537, 0.757)。
@export var back_color: Color
@export var fill_color: Color

## ── 节点引用 ──────────────────────────────────────────────────────────────
## 两个都是**普通子节点路径**（health_bar.tscn 里没有勾 unique_name_in_owner，不能用 %）。
## progress_bar：真正显示的进度条，max_value = 1.0，所以吃 0~1 的比例值。
## health_amount：叠在进度条正中间、锚点铺满的 Label，显示的是**具体血量**（字符串）。
## @onready 在 _ready() 之前（_init / 构造阶段）是 null，别提前访问。
@onready var progress_bar: ProgressBar = $ProgressBar
@onready var health_amount: Label = $HealthAmount


## 把两个 @export 颜色写进 ProgressBar 的主题覆盖（theme override）里。
## 参数：无（读自身 back_color / fill_color）。
## 返回值：无。
## 副作用：
##   · 给 progress_bar 安装两个 StyleBoxFlat 覆盖（"background" = 槽底、"fill" = 进度前景）；
##   · 这**不会**动到场景里原始的 StyleBoxFlat 资源（因为 duplicate() 过了），
##     所以多个 HealthBar 实例可以各是各的颜色；
##   · 不 emit 信号、不碰 Global。
## 执行时机：节点首次进入场景树时（_ready）。此时 @onready 变量已赋值，可以安全使用。
## 为什么不在 _init 里做：_init 阶段子节点还不存在，$ProgressBar 会直接报错。
## Called when the node enters the scene tree for the first time.
func _ready() -> void:
	# 取"槽底"样式并复制一份。★ .duplicate() 不能省：get_theme_stylebox() 拿到的是场景里
	# 那个 StyleBoxFlat 资源本体，同一个 .tscn 实例化出来的所有节点共享它；
	# 直接改 bg_color 会一次性改掉所有血条/蓝条（还会污染场景文件里存的原始值）。
	# duplicate() 默认是浅拷贝，对 StyleBoxFlat 这种纯数据资源足够用。
	var back_style := progress_bar.get_theme_stylebox("background").duplicate()
	back_style.bg_color = back_color
	
	# 同理，取"进度前景"样式再复制一份并上色
	var fill_style := progress_bar.get_theme_stylebox("fill").duplicate()
	fill_style.bg_color = fill_color
	
	# 名称必须正好是 "background" / "fill" —— 这是 ProgressBar 主题里这两个 StyleBox 项的固定键名，
	# 写错了不会报错，只是"颜色没生效"，很难查。
	# 覆盖只作用于本实例的 progress_bar，不影响其他 HealthBar。
	progress_bar.add_theme_stylebox_override("background", back_style)
	progress_bar.add_theme_stylebox_override("fill", fill_style)

## 刷新血条（对外的主入口，battle_unit.gd 也直接调它）。
## 参数 value：进度条的**比例值**（0.0 ~ 1.0）。因为 ProgressBar 的 max_value 固定是 1.0，
##   传血量本身会把条填爆（值会被 ProgressBar 自动 clamp 到 max_value，条永远满）——
##   所以两个参数职责不同，别合并。
## 参数 health：要显示在条中间的具体血量/蓝量数字，**原样 str() 后显示**。
##   因为走的是 str()，float 会显示成 "12.5" 这种；需要取整得调用方自己 int()。
##   负数不特殊处理（HealthComponent 里已经 clamp 到 0 了）。
## 返回值：无。
## 副作用：写 progress_bar.value 与 health_amount.text —— 纯 UI，不 emit 信号、不读不写 Global。
func update_bar(value: float, health: float) -> void:
	progress_bar.value = value
	health_amount.text = str(health)

## HealthComponent.on_health_changed 的回调（连线在 unit.tscn 里，编辑器连的）。
## 参数 current：当前血量（绝对值）。
## 参数 max：最大血量（绝对值，来自 UnitStats.health）。
## 返回值：无。
## 副作用：转调 update_bar()，也就是改本控件的显示；不改任何游戏状态。
## 坑：
##   · 这里的 max 是形参名，遮住了 GDScript 的全局函数 max()。本函数内**不能**再用 max(a, b)，
##     真要用得写 @GlobalScope.max(...)。
##   · current / max 是浮点除法：max 为 0.0 时会得到 inf/nan（ProgressBar 会自己夹住，
##     不会崩，但条会显示成满或空，属于"数据源头异常"的症状）。HealthComponent.max_health
##     初值是 1.0、setup() 里又直接取 stats.health，所以只要 .tres 里 health 不填 0 就没问题。
##   · 函数名是编辑器连线用的，**改名会静默断线**；要改名必须同时改 unit.tscn 里那行 [connection]。
func _on_health_component_on_health_changed(current: float, max: float) -> void:
	# 换算成 0~1 的比例再交给进度条（进度条的 max_value 是 1.0）
	var value = current / max
	update_bar(value, current)
	
