extends CanvasLayer
## TooltipManager —— 全局提示卡管理器（autoload 单例）
##
## 解决的问题：
##   1. 提示卡不再挂在会被裁剪的容器里（独立 CanvasLayer，永远画最上层、不会被裁）
##   2. 一个场景只实例化一份，反复复用（不随悬停次数增长）
##   3. 定位统一走"默认右下 → 放不下就翻转 → 最后夹在屏幕内"
##   4. 延迟出现 + 淡入淡出，鼠标快速划过一排卡片时不会乱闪
##   5. 提示卡整棵树都不吃鼠标事件，避免它触发下面卡片的 mouse_exited 造成闪烁
##
## ── 用法 ──────────────────────────────────────────────────────────
## 1) 项目设置 → 自动加载：添加本文件，节点名填 TooltipManager
##    （或直接在 project.godot 的 [autoload] 里加一行：
##     TooltipManager="*res://autoloads/tooltip_manager.gd"）
## 2) 在下面 _ready() 的"登记"区按需增删：数据类型 → 卡片场景 → 属性名
## 3) 任意位置调用：
##      TooltipManager.show_for(data)                  # 锚在鼠标旁
##      TooltipManager.show_for_control(card, data)    # 锚在控件右上角（手柄/键盘）
##      TooltipManager.hide_tip()                      # 隐藏
##
## 卡片的两种接法（任选其一）：
##   A. 注册时给属性名（推荐，零改动）：register(UnitStats, scene, &"unit")
##   B. 卡片脚本实现 func bind(data: Object) -> void: ...（注册时属性名留空）
##
## 注意事项：
##   · 卡片根节点请用 custom_minimum_size 固定尺寸，否则第一帧可能错位
##   · 卡片不要放进任何 Container（容器会重排它的位置）
##   · 提示卡是纯展示，鼠标事件全部忽略；需要交互的浮层请另做
##
## ── 系统位置与数据流（补充说明）──────────────────────────────────────────
## 本文件是 project.godot 里登记的第三个 autoload
##   （TooltipManager="*uid://5yg0vimadyd4" —— 指向本**脚本**本身；另外两个是 Global 与 SoundManager）。
## 因为它继承 CanvasLayer 又是 autoload，所以：
##   · 独立于任何场景存在，切场景不会重建 → _instances 里缓存的卡片可以长期复用而不泄漏；
##   · layer = LAYER(128)，永远画在所有游戏 UI 之上，也不会被父容器的 clip_contents 裁掉；
##   · process_mode = PROCESS_MODE_ALWAYS，即使 SceneTree 暂停也照常淡入淡出。
##
## 谁在用它（谁调用、传什么数据）：
##   · scenes/ui/selection_panel/selection_panel.gd —— 鼠标进入角色卡 / 初始武器卡时
##     show_for_control(card, UnitStats 或 ItemWeapon)，离开时 hide_tip()
##   · scenes/ui/shop_panel/shop_panel.gd —— 鼠标进入 ShopCard / ItemCard 时
##     show_for_control(card, 某个 ItemBase 子类)，离开时 hide_tip()
##   · 需要"跟着鼠标走"的场合可以直接用 show_for(data)（POINT 模式，带 24px 死区）
##
## 数据怎么流转（本文件不复制、不解释数据）：
##   调用方传进来的 data 是"原始数据对象"，本文件只负责把它灌进卡片：
##   card.set(属性名, data) 或 card.bind(data)。卡片脚本（hover_item_card.gd / hover_unit_card.gd）
##   自己读字段、拼 BBCode、按 item_tier 换样式。
##   本文件自身只对外发两个信号：tooltip_opened(data)（淡入开始时）与 tooltip_closed（淡出回调里）。
##
## 登记表怎么匹配（重要）：
##   _registry 的键是**脚本对象**（class_name 本身就是 GDScript 的 Script 资源，可以直接当键）。
##   匹配时沿 get_base_script() 向上爬 —— 所以只登记 ItemBase 就能同时服务 ItemWeapon /
##   ItemPassive / ItemUpgrade；UnitStats 将来若有子类也会自动命中。
##
## 与其他系统的边界：
##   · 不读不写 Global，也不碰 SoundManager —— 它只依赖"数据对象带脚本"这一个前提；
##   · 不产生任何玩法效果，纯展示；卡片长什么样完全由卡片场景 + 数据对象决定。

## 对外信号。它们描述的是"卡片状态的边沿"，不是鼠标事件 ——
## 鼠标进出控件是调用方自己接的信号（mouse_entered / mouse_exited）。
signal tooltip_opened(data: Object)   # 卡片开始淡入时 emit，携带当前绑定的数据对象；被新提示打断的旧卡片不会补发 tooltip_closed
signal tooltip_closed                 # 卡片淡出结束、真正 hide() 之后 emit；无参数

## ── 常量（时间单位一律是秒）────────────────────────────────────────────
## 想统一调节奏就改这里。其中 delay / placement_offset 还会被下面那组可调参数覆盖，
## 所以运行期也能改（例如"暂停期间干脆不要延迟"）。
## 逐个说明：
##   · LAYER = 128：高于所有游戏 UI（游戏 UI 一般 0~10），保证提示卡永远画在最上层；
##   · PLACEMENT_OFFSET = (16,16)：卡片相对锚点的右下偏移，避免紧贴鼠标/控件边缘；
##   · SHOW_DELAY = 0.25s：等鼠标停下来再显示，这样"快速划过一排卡片"不会乱闪；
##   · FADE_IN_TIME / FADE_OUT_TIME：淡入略长、淡出更短，收起时更干脆；
##   · MOUSE_DEADZONE = 24px：鼠标移动超过这个距离才重新定位，否则 1px 抖动也会让位置反复重排。
const LAYER := 128                  # 高于所有游戏 UI
const PLACEMENT_OFFSET := Vector2(16, 16)   # 卡片相对锚点的偏移（像素，右下方），让卡片不要紧贴鼠标/控件边缘
const SHOW_DELAY := 0.25            # 秒；0 = 立刻显示
const FADE_IN_TIME := 0.08          # 淡入时长（秒）。很短：观感是"立刻出现，但不生硬"
const FADE_OUT_TIME := 0.06         # 淡出时长（秒）。比淡入更短，收起来更干脆
const MOUSE_DEADZONE := 24.0        # 鼠标移动超过这个距离才重新定位

## 锚定模式：决定 _place() 从哪里取锚点。
enum AnchorMode { NONE, POINT, CONTROL }   # NONE=初始/无卡片；POINT=跟鼠标（show_for）；CONTROL=跟控件右上角（show_for_control）

# ── 可调参数 ──────────────────────────────────────────────────────
# （这四个是运行期可改的"全局开关"，改动会影响所有调用方）
var enabled := true                 # 总开关：false 时 show_for / show_for_control 只会收起卡片（等价于 hide_tip）
var delay := SHOW_DELAY             # 显示延迟（秒），默认取 SHOW_DELAY；设成 0 就是立即显示（调试或手柄导航时常用）
var placement_offset := PLACEMENT_OFFSET   # 卡片相对锚点的偏移（像素），默认 (16,16)；调大可以让卡片离鼠标更远
var follow_mouse := true            # POINT 模式下是否跟随鼠标（带死区）

# ── 内部状态 ──────────────────────────────────────────────────────
# （下划线开头，外部不要直接改；_registry 只由 register() / unregister() 维护，
#   _instances 是懒加载出来的卡片实例，一旦创建就常驻、从不清理）
var _registry: Dictionary = {}      # Script -> { scene: PackedScene, property: StringName }
var _instances: Dictionary = {}     # scene.resource_path -> Control（复用的实例）

var _current: Control = null        # 当前正在展示或淡出的卡片；null = 当前什么都没有
var _current_data: Object = null    # 与 _current 配对的数据对象；hide_tip 走完后清空
var _anchor_mode := AnchorMode.NONE # 当前锚定模式，决定 _place() 从哪里取锚点
var _anchor_point := Vector2.ZERO   # POINT 模式的锚点（视口坐标）；CONTROL 模式不用它
var _anchor_control: Control = null # CONTROL 模式的锚点控件；切到 POINT 模式时会被显式置 null
var _last_mouse := Vector2.ZERO     # 上一次记录到的鼠标位置，用于死区比较
var _token := 0                     # 显示请求的"版本号"：每次新显示请求或 hide 都 +1；await 醒来靠它判断自己是否已过期（防抖核心）
var _tween: Tween                   # 当前正在跑的淡入/淡出 tween；可能为 null，用之前必须先判 null 再 is_valid()


## 初始化：设图层、设"永远处理"、先关掉 _process（只有 POINT + follow_mouse 时才开），
## 然后完成"数据类型 → 卡片场景 → 属性名"的登记。
## 副作用：**不会**实例化任何卡片 —— 卡片是第一次真正要显示时才懒加载的（见 _get_card），
##   所以这里只是把两个 PackedScene 记进 _registry。
## 坑：
##   · 登记用的 preload 路径是写死的（res://scenes/ui/hover_card/hover_item_card.tscn 等），
##     文件被挪走/改名会在启动时就报错；
##   · 本类是 autoload（extends CanvasLayer），没有父类 _ready 需要 super 调用；
##   · set_process(false) 必须在 _ready 里做：CameraLayer 之类的基类不会自动关掉它。
func _ready() -> void:
	layer = LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)

	# ── 登记区：数据类型 → 卡片场景 → 属性名（用不到的删掉即可）──────
	register(ItemBase, preload("res://scenes/ui/hover_card/hover_item_card.tscn"), &"item")
	register(UnitStats, preload("res://scenes/ui/hover_card/hover_unit_card.tscn"), &"unit")


# ══════════════════════════════════════════════════════════════════
#  注册
# ══════════════════════════════════════════════════════════════════

## 登记"某种数据类型用哪张卡片、灌进哪个属性"。
## 参数 data_class：class_name 本身（例如 ItemBase）——它是 Script 对象，直接当字典键用；
##   登记父类即可覆盖其子类（匹配时沿继承链向上找，见 _find_entry）。
## 参数 scene：卡片场景，根节点必须是 Control，否则 _get_card() 会警告并返回 null。
## 参数 property_name：卡片脚本上接收数据的属性名（如 &"item"）；留空则改为调用卡片的 bind()。
## 返回值：无。
## 副作用：只写 _registry，不实例化卡片（真正实例化发生在第一次显示时）。
## 对同一个 data_class 重复登记＝覆盖旧值，不会产生第二份实例。
## data_class 传 class_name（例如 ItemBase）；property_name 留空则调用卡片的 bind()
func register(data_class: Script, scene: PackedScene, property_name: StringName = &"") -> void:
	_registry[data_class] = { "scene": scene, "property": property_name }


## 反注册：把某个数据类型从登记表里删掉。删掉之后再 show_for() 传这种数据只会 push_warning、什么都不显示。
## 参数 data_class：要移除的脚本（class_name）。传子类只会删掉子类那一条，父类的登记仍然有效。
## 返回值：无。
## 副作用：只改 _registry；已经实例化出来的卡片不会被释放（_instances 不动），只是再也 bind 不到数据。
func unregister(data_class: Script) -> void:
	_registry.erase(data_class)


## 总开关：关掉时立即收起当前的提示卡。适合"暂停 / 加载 / 过场"期间屏蔽所有悬停提示。
## 参数 value：true = 允许显示；false = 禁止显示。
## 返回值：无。
## 副作用：只有 value 为 false 时才会调 hide_tip() ——
##   那会作废所有等待中的延迟显示（_token += 1）、启动淡出 tween，并在淡出结束时 emit tooltip_closed；
##   设为 true 不会主动显示任何东西，也不重置 delay。
func set_enabled(value: bool) -> void:
	enabled = value
	if not enabled:
		hide_tip()


# ══════════════════════════════════════════════════════════════════
#  对外显示接口
# ══════════════════════════════════════════════════════════════════

## 对外接口：在鼠标旁显示提示卡（POINT 模式）。
## 参数 data：要展示的数据对象；传 null 等价于"收起提示卡"（内部转调 hide_tip()）。
## 参数 anchor_point：可选锚点（视口坐标，左上角为原点）。默认值 Vector2.INF 是**哨兵值**，
##   表示"用当前鼠标位置"；所以这个参数没法真的传 INF 当坐标（实际也没有意义）。
## 返回值：无。
## 副作用：改 _anchor_mode / _anchor_control / _anchor_point，然后转交 _begin()
##   —— 后者可能 await 一个延迟计时器，并最终 emit tooltip_opened / 触发淡入 tween。
## 相关开关：enabled 为 false 时和 data 为 null 走的是同一条早退分支。
## 锚在鼠标旁；传 anchor_point 则锚在指定的视口坐标（左上角为原点的坐标）
func show_for(data: Object, anchor_point: Vector2 = Vector2.INF) -> void:
	if data == null or not enabled:
		hide_tip()
		return
	_anchor_mode = AnchorMode.POINT
	_anchor_control = null
	_anchor_point = get_viewport().get_mouse_position() if anchor_point == Vector2.INF else anchor_point
	_begin(data)


## 对外接口：把提示卡锚到某个控件旁边（CONTROL 模式）。鼠标不在附近也能用 —— 手柄/键盘导航靠它。
## 参数 control：锚点控件（位置取它的右上角）；参数 data：要展示的数据对象。
## 返回值：无。
## 副作用：改 _anchor_mode / _anchor_control 后转交 _begin()；**不**立刻读鼠标位置（所以不会跳一下）。
## 校验：data 为 null、enabled 为 false、或 control 不是有效实例 —— 三者任一成立都先 hide_tip() 再返回，
##   调用方不必担心"控件已被释放还去悬停"。
## 现有用法（就是这么接的）：card.mouse_entered.connect(TooltipManager.show_for_control.bind(card, 数据))
## 锚在某个控件旁边（鼠标不在附近时也能用，适合手柄/键盘导航）
func show_for_control(control: Control, data: Object) -> void:
	if data == null or not enabled or not is_instance_valid(control):
		hide_tip()
		return
	_anchor_mode = AnchorMode.CONTROL
	_anchor_control = control
	_begin(data)


## 对外接口：隐藏当前提示卡。鼠标离开控件、set_enabled(false)、show_for(null) 最终都会走到这里。
## 参数：无。返回值：无。
## 副作用（三件事，顺序有意义）：
##   1) _token += 1 —— 让所有还在 await 延迟的 _begin() 醒来时发现"号变了"而直接放弃；
##   2) set_process(false) —— 停掉跟随鼠标的每帧定位；
##   3) 若卡片当前可见：起一个 FADE_OUT_TIME(0.06s) 的 tween 把 modulate.a 拉到 0，
##      **tween 结束的回调里**才 card.hide()、清 _current_data、并 emit tooltip_closed。
## 坑：
##   · 淡出是异步的，所以刚调完本函数时 is_showing() 可能还会返回 true 几帧；
##   · 本来就不可见时会走早退分支（只清 _current_data）——**不会** emit tooltip_closed，
##     所以别把 tooltip_closed 当成"每次 hide_tip 都会收到"的通知；
##   · 回调里 emit 前先判断了 is_instance_valid(card)，因为等待期间卡片理论上可能已被释放。
func hide_tip() -> void:
	_token += 1                       # 让还在等待延迟的 show 失效
	set_process(false)
	if _current == null or not _current.visible:
		_current_data = null
		return
	var card := _current
	_kill_tween()
	_tween = create_tween()
	_tween.tween_property(card, "modulate:a", 0.0, FADE_OUT_TIME)
	_tween.tween_callback(func() -> void:
		if is_instance_valid(card):
			card.hide()
		_current_data = null
		tooltip_closed.emit())


## 查询：当前是否有提示卡处于显示状态。
## 参数：无。返回值：bool（_current 不为 null 且其 visible 为 true）。
## 副作用：无。注意它看的是 visible 标志，所以淡出过程中仍然算"显示中"。
func is_showing() -> bool:
	return _current != null and _current.visible


## 查询：当前提示卡绑定的数据对象（可能为 null —— 没有卡片，或正在隐藏 / 刚隐藏完）。
## 参数：无。返回值：Object（调用方拿到后请自行判空、必要时 is_instance_valid）。
## 副作用：无（只读 _current_data）。
## 用途：给"卡片被点掉之后还想知道刚展示的是什么"这类场景留的口子。
func current_data() -> Object:
	return _current_data


# ══════════════════════════════════════════════════════════════════
#  内部实现
# ══════════════════════════════════════════════════════════════════

## 内部：显示流程的统一入口（show_for / show_for_control 最后都汇到这里）。
## 参数 data：要展示的数据对象。
## 返回值：无。
## 流程与副作用：
##   1) _find_entry 沿继承链找登记项；没登记就 push_warning 并直接返回（什么都不显示）；
##   2) _get_card 取卡片（首次会实例化并缓存）；**换目标时把上一张卡 hide()**，避免两张叠在一起；
##   3) 记录 _current / _current_data，并 _bind 把数据灌进卡片；
##   4) 若"还是同一份数据 + 同一张卡 + 已可见"（same_target），只重算位置就 return ——
##      这是防抖关键：同一次悬停里鼠标微动不会重新计时、不会重新淡入；
##   5) 否则 _token += 1 取一个号；delay > 0 时 await 一个 SceneTreeTimer；
##      醒来后核对"号没变 + 仍处于启用 + 卡还是这一张"，任一不满足就静默放弃 ——
##      这正是"鼠标快速划过一排卡片时不会乱闪"的实现方式。
## ⚠ 本函数是 async（含 await）：等待期间世界可能已经变了（场景切换、卡片被释放），
##   所以醒来后必须重新校验，不要假设 _current 仍然有效。
func _begin(data: Object) -> void:
	var entry := _find_entry(data)
	if entry.is_empty():
		push_warning("TooltipManager: 没有为 %s 登记卡片场景" % data.get_class())
		return

	var card := _get_card(entry["scene"] as PackedScene)
	if card == null:
		return

	# 换目标时立刻藏掉旧卡片，避免两张叠在一起
	if _current != null and _current != card:
		_current.hide()

	var same_target := _current == card and _current.visible and _current_data == data
	_current = card
	_current_data = data
	_bind(card, data, entry)

	if same_target:
		_place()                       # 内容没变，只更新位置
		return

	_token += 1
	var my_token := _token
	if delay > 0.0:
		await get_tree().create_timer(delay).timeout
		if my_token != _token or not enabled or _current != card:
			return                       # 期间被取消/换目标了
	_show_now()


## 内部：真正把卡片亮出来（延迟结束、校验通过后由 _begin 调用）。
## 参数：无（操作对象是 _current）。返回值：无。
## 副作用：
##   · 若卡片尺寸还是 Vector2.ZERO（第一帧尚未布局），用 get_combined_minimum_size() 兜一个尺寸，
##     避免 _place() 拿 0 去算位置导致错位 —— 这也是文档里强调"卡片根节点请用 custom_minimum_size 固定尺寸"的原因；
##   · modulate.a 先归 0，再用 FADE_IN_TIME(0.08s) 的 tween 拉到 1（保证每次都是淡入，不会硬闪）；
##   · 按需打开 _process（只有 POINT 模式 **且** follow_mouse 为真才需要每帧跟随鼠标）；
##   · 把 _last_mouse 记为当前鼠标位置，作为死区判断的基准点；
##   · **emit tooltip_opened(_current_data)** —— 这是本文件两个对外信号之一。
func _show_now() -> void:
	var card := _current
	if card == null:
		return
	if card.size == Vector2.ZERO:
		card.size = card.get_combined_minimum_size()
	card.modulate.a = 0.0
	card.show()
	_place()
	_kill_tween()
	_tween = create_tween()
	_tween.tween_property(card, "modulate:a", 1.0, FADE_IN_TIME)
	_last_mouse = get_viewport().get_mouse_position()
	set_process(_anchor_mode == AnchorMode.POINT and follow_mouse)
	tooltip_opened.emit(_current_data)


## 内部：POINT 模式下的"跟随鼠标"。只在显示中且 follow_mouse 为真时才会被启用（见 _show_now）。
## 参数 _delta：引擎给的帧间隔；本函数用不到它，所以参数名带下划线。
## 返回值：无。
## 副作用：
##   · 鼠标相对上次锚点移动超过 MOUSE_DEADZONE(24px) 时，更新 _last_mouse 与 _anchor_point 并重算位置；
##   · 若卡片已经不显示了，顺手 set_process(false) 自我关闭，省掉无意义的每帧调用。
## 为什么要有死区：不做死区的话鼠标抖 1 像素也会重排位置，视觉上会一直"抖"。
func _process(_delta: float) -> void:
	if _current == null or not _current.visible:
		set_process(false)
		return
	var mouse := get_viewport().get_mouse_position()
	if mouse.distance_to(_last_mouse) >= MOUSE_DEADZONE:
		_last_mouse = mouse
		_anchor_point = mouse
		_place()


## 内部：按当前锚点算出卡片该放哪儿。策略是"默认右下 → 放不下就朝反方向翻转 → 最后夹在屏幕内"。
## 参数：无。用到的状态是 _anchor_mode / _anchor_point / _anchor_control / placement_offset。
## 返回值：无。
## 副作用：写 _current.position；CONTROL 模式下若锚点控件已失效，会转调 hide_tip()（等于隐式收掉提示）。
## 坐标说明（全部是视口坐标，左上角为原点，单位像素）：
##   · CONTROL 模式把锚点取在控件的**右上角** = (rect.position.x + rect.size.x, rect.position.y)；
##   · 屏幕尺寸用 get_viewport().get_visible_rect().size —— 项目是 canvas_items 拉伸，
##     所以它就是逻辑分辨率（1920×1080）而不是实际窗口像素；
##   · clampf 的上界写成 maxf(0.0, screen - size)：卡片比屏幕还大时上界退化为 0，
##     保证不会出现"下界 0 > 上界负数"而把卡片顶出左上角。
func _place() -> void:
	if _current == null:
		return

	var anchor := _anchor_point
	if _anchor_mode == AnchorMode.CONTROL:
		if not is_instance_valid(_anchor_control):
			hide_tip()
			return
		var r := _anchor_control.get_global_rect()
		anchor = Vector2(r.position.x + r.size.x, r.position.y)   # 控件右上角

	var screen := get_viewport().get_visible_rect().size
	var size := _current.size
	if size == Vector2.ZERO:
		size = _current.get_combined_minimum_size()

	var pos := anchor + placement_offset
	if pos.x + size.x > screen.x:              # 右边放不下 → 翻到左侧
		pos.x = anchor.x - size.x - placement_offset.x
	if pos.y + size.y > screen.y:              # 下边放不下 → 翻到上方
		pos.y = anchor.y - size.y - placement_offset.y

	pos.x = clampf(pos.x, 0.0, maxf(0.0, screen.x - size.x))      # 最后兜底夹住
	pos.y = clampf(pos.y, 0.0, maxf(0.0, screen.y - size.y))
	_current.position = pos


## 内部：把数据灌进卡片。两条路（对应文件头说的 A / B 两种接法）：
##   · 登记时给了属性名 → card.set(属性名, data)（推荐，卡片脚本零改动）；
##   · 没给属性名 → 找卡片的 bind(data) 方法并调用；
##   · 两者都没有 → push_warning（卡片会停在默认/空白状态）。
## 参数 card：卡片实例；data：数据对象；entry：_registry 里那一条 {scene, property}。
## 返回值：无。
## 副作用：写卡片属性或调用卡片方法 —— 卡片的 setter 里通常会去改 Label / RichTextLabel 文本、
##   贴图，以及 add_theme_stylebox_override 换样式（所以这里间接影响了 UI 外观）。
func _bind(card: Control, data: Object, entry: Dictionary) -> void:
	var property: StringName = entry.get("property", &"")
	if property != &"":
		card.set(property, data)
	elif card.has_method("bind"):
		card.call("bind", data)
	else:
		push_warning("TooltipManager: %s 没有 bind() 方法，登记时也没给属性名" % card.name)


## 内部：为一份数据找到它的登记项。
## 参数 data：数据对象（必须带脚本 —— 纯 C++ 内置对象 get_script() 返回 null，循环体一次都不会执行）。
## 返回值：{scene, property} 字典；找不到时返回**空字典**（注意不是 null，调用方用 is_empty() 判断）。
## 副作用：无（纯查表）。
## 实现：从数据自己的脚本开始，不断 get_base_script() 往上爬（子类 → 父类 → … → null），
##   第一个命中的登记项胜出 —— 这就是"只登记 ItemBase 就够用"的原因；
##   反过来，如果给子类也单独登记了一条，子类会优先命中它（覆盖父类效果）。
## 按数据的脚本沿着继承链找登记项（登记 ItemBase，传 ItemWeapon 也能命中）
func _find_entry(data: Object) -> Dictionary:
	var script: Script = data.get_script()
	while script != null:
		if _registry.has(script):
			return _registry[script]
		script = script.get_base_script()
	return {}


## 内部：取卡片实例，带缓存地复用（相当于"一类卡片只实例化一份"）。
## 参数 scene：登记时记下的 PackedScene。
## 返回值：Control —— 缓存命中直接返回；根节点不是 Control 时 push_warning 并返回 null（调用方会放弃显示）。
## 副作用（只在首次实例化时发生）：
##   · 把根节点和整棵子树的 mouse_filter 设为 IGNORE（见 _ignore_mouse_recursive 的说明）；
##   · 先 hide() 再 add_child()，避免入树那一瞬间在 (0,0) 闪一下；
##   · 实例挂到本 CanvasLayer 下（所以它不受任何游戏场景容器/裁剪影响）；
##   · 以 scene.resource_path 为键写入 _instances 缓存。
## 注意：缓存**永不清理** —— 提示卡场景很少，这是刻意的"一次实例化、长期复用"，
##   代价是这些卡片会一直挂在 TooltipManager 下（切场景也不会释放）。
func _get_card(scene: PackedScene) -> Control:
	var key := scene.resource_path
	var cached: Control = _instances.get(key)
	if is_instance_valid(cached):
		return cached

	var card := scene.instantiate() as Control
	if card == null:
		push_warning("TooltipManager: %s 的根节点不是 Control" % key)
		return null
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ignore_mouse_recursive(card)              # 整棵树都不吃鼠标事件
	card.hide()
	add_child(card)
	_instances[key] = card
	return card


## 提示卡必须完全不接收鼠标，否则它一出现就会让下面卡片的 mouse_exited 触发 → 反复闪烁
func _ignore_mouse_recursive(node: Node) -> void:
	for child in node.get_children():
		if child is Control:
			(child as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ignore_mouse_recursive(child)


## 内部：杀掉正在跑的淡入/淡出 tween，防止"上一个还没结束、下一个又叠上来"导致透明度错乱。
## 参数：无。返回值：无。
## 副作用：_tween.kill() 会让**上一次淡出 tween 的 tween_callback 不再执行** ——
##   也就是说那个回调里的 tooltip_closed.emit() 不会发生。这是有意的（避免关闭信号乱序发出），
##   但如果你在监听 tooltip_closed 做清理，要意识到"被新提示打断的旧提示"不会发这个信号。
## 判空顺序：先判 null（从未显示过时它是 null），再 is_valid()（可能已被 kill 过）。
func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
