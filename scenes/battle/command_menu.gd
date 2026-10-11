# ═══════════════════════════════════════════════════════════════════════════════
#  command_menu.gd —— 战斗指令菜单（主菜单 + 技能二级菜单）
# ═══════════════════════════════════════════════════════════════════════════════
#
# 【它在系统里的位置】
#   本脚本挂在战斗场景 UI 层里的 CommandMenu 节点上（battle.tscn 里 UI/CommandMenu 的一个
#   Panel 实例），是"玩家下指令"的唯一入口。
#   它是一个**纯 UI 组件**：只负责显示按钮、把点击翻译成信号，绝不自己决定战斗怎么进行。
#     · 上游：Battle._begin_turn() 在轮到我方时调 open_for(unit) 打开它；
#             Battle._finish_turn() / _finish_battle() / 各指令回调里调 close() 关掉它；
#             Battle 还会在 _on_command_selected / _on_skill_selected 里重新 open_for()
#             （例如点了"道具"或"暂未实现的技能"时回到菜单）。
#     · 下游：向 Battle 发两个信号 —— command_selected（主菜单指令）与 skill_selected（具体技能）。
#             Battle 的信号回调里第一句都会校验 state == COMMAND，所以本菜单"多说几句"是安全的。
#   依赖方向是单向的：本脚本 import 了 BattleUnit / SkillData 的类型，但从不反向调用 Battle；
#   Battle 通过 @onready 引用本节点。这样的好处是菜单可以单独拿去别的战斗系统复用。
#
# 【数据从哪来】
#   · 标题文字、技能列表、蓝耗/冷却/可用性全部来自 open_for(unit) 传进来的那个 BattleUnit；
#   · 菜单自己**不缓存**战斗数据，每次都现场读 unit.available_skills / unit.mp / unit.cooldown_left()，
#     所以战斗中途数值变化后，只要重新 open_for() 或重建按钮就能显示最新值。
#
# 【布局结构与节点】
#   两个互斥的容器：%MainButtons（攻击/法术/道具/防御/逃跑）与 %SkillButtons（动态生成的技能按钮），
#   外加 %BackButton（技能页返回主菜单）和 %TitleLabel（显示当前行动者名字）。
#   %SkillButtons 里的按钮是**每次打开技能页都重建**的（见 _open_skills 的说明）。
#
# 【坑位提示】
#   · _ready() 末尾的 `_show_main(); close();` 顺序是必要的：先摆好内部状态再隐藏，
#     否则菜单第一次打开时可能停在"技能页"而不是主菜单。
#   · item_button.disabled = true 是写死的（道具系统还没做），不随 open_for 变化。
#   · 动态创建的按钮**没有** owner（运行时 add_child 得到 owner = null），
#     所以释放必须用 child.queue_free()，不能走 owner。
# ═══════════════════════════════════════════════════════════════════════════════
extends Panel
class_name CommandMenu

## 指令菜单：主菜单（攻击/法术/道具/防御/逃跑）+ 技能二级菜单
## 只负责"显示 + 发信号"，具体做什么由 Battle 决定。

# ── 对外信号（唯一的下游出口）─────────────────────────────────────────────────
# 两个信号都用"发出去就不管"的方式工作：菜单不关心 Battle 收到后是切换状态、
# 打开子菜单、还是直接收尾回合，也不等待任何返回值。

## 主菜单里点了某个指令按钮时发出。
## 参数 command：指令标识，取值 &"attack" / &"defend" / &"flee" / &"item"（&"skill" 不会从这里走，
##               它走 _open_skills() → 技能页）。
## 谁接：连接在 Battle._ready() 里（command_menu.command_selected.connect(...)），
##       回调是 Battle._on_command_selected()。
signal command_selected(command: StringName)

## 技能页里点了某个具体技能时发出。
## 参数 skill：被点击的技能资源（SkillData）。
## 谁接：Battle._on_skill_selected() —— 它会再做一次 can_use_skill 校验（不信任 UI 状态）。
signal skill_selected(skill: SkillData)

# ── 节点引用（%Xxx = unique_name_in_owner，改层级不会失效）──────────────────────
# 这些 @onready 变量在 _ready() 之前被赋值，而 _ready() 里立刻就要用它们连信号，
# 所以顺序是安全的（@onready 求值 → _ready 体执行）。
# 注意 %TitleLabel 等在场景文件里必须勾了"作为唯一名称访问"，否则这里取不到。
@onready var title_label: Label = %TitleLabel
## 主菜单按钮的容器（VerticalBox）。_show_main() 显示它、_open_skills() 隐藏它。
@onready var main_buttons: VBoxContainer = %MainButtons
## 技能按钮的容器。每次打开技能页都会**清空重建**（见 _open_skills()）。
@onready var skill_buttons: VBoxContainer = %SkillButtons
## 五个主菜单按钮。绑定时用 bind() 把指令标识一起带上（见 _ready()）。
@onready var attack_button: Button = %AttackButton
## "法术"按钮。特殊：它不直接发 command_selected，而是打开技能页（_open_skills）；
## 并且它的 disabled 会在 open_for() 里按"单位有没有技能"动态设置。
@onready var skill_button: Button = %SkillButton
## "道具"按钮。_ready() 里被写死 disabled = true（道具系统未实现）。
@onready var item_button: Button = %ItemButton
@onready var defend_button: Button = %DefendButton
@onready var flee_button: Button = %FleeButton
## 技能页里的"返回"按钮。只在技能页可见，点了调 _show_main() 回到主菜单
## （注意：返回主菜单**不**发任何信号、也**不**通知 Battle，纯本地切换）。
@onready var back_button: Button = %BackButton

# ── 运行时状态 ────────────────────────────────────────────────────────────────

## 当前菜单是为谁打开的。open_for() 写入，close() 清成 null。
## 用途：标题文字、判断"有没有技能"，以及 _open_skills() / _make_skill_button() 里读蓝量与冷却。
## 注意它是**弱引用式**的普通变量：单位节点被释放后这里不会自动变 null，
## 所以 close() 必须在战斗结束时被调用（Battle._finish_battle() 里确实调了）。
var _unit: BattleUnit


## 生命周期入口：节点进树后由引擎调用一次。这里只做"一次性接线"，不碰战斗数据。
## 参数/返回值：无。
## 副作用：
##   · 连接六个按钮的 pressed 信号（其中四个用 bind() 附带指令标识）；
##   · 把"道具"按钮永久禁用；
##   · 调 _show_main() 摆好内部可见性，再调 close() 把整个菜单藏起来。
## bind() 的说明：
##   `attack_button.pressed.connect(_on_main_pressed.bind(&"attack"))`
##   pressed 信号本身不带参数，bind() 会把 &"attack" **追加**在信号参数之后传给回调，
##   所以 _on_main_pressed(command) 能收到它。这样四个按钮共用同一个回调，省掉四个函数。
##   注意 bind 的参数顺序：如果信号本身有参数（pressed() 没有），bind 的值排在后面。
## 为什么末尾是 `_show_main(); close();`：
##   · _show_main() 把容器可见性恢复成"主菜单"（否则第二次打开会停在技能页）；
##   · close() 只是 hide() + 清 _unit，不会重置可见性，两者职责不同，顺序不能换。
## 不需要 super._ready()：父类 Panel 没有自定义脚本逻辑可转发；
##   但若有人继承本类，子类 _ready() **必须**调 super._ready()，否则这些连接全部丢失
##   —— 表现就是"菜单点任何按钮都没反应"。
func _ready() -> void:
	attack_button.pressed.connect(_on_main_pressed.bind(&"attack"))
	# "法术"按钮单独接线：它要打开二级菜单，而不是直接发指令信号。
	skill_button.pressed.connect(_open_skills)
	item_button.pressed.connect(_on_main_pressed.bind(&"item"))
	defend_button.pressed.connect(_on_main_pressed.bind(&"defend"))
	flee_button.pressed.connect(_on_main_pressed.bind(&"flee"))
	back_button.pressed.connect(_show_main)

	# 道具系统还没做，先禁用
	# 注意这只在 _ready() 里设一次，open_for() 不会重新启用它 —— 等道具做完要记得改这里。
	item_button.disabled = true

	_show_main()
	close()


## 为某个单位打开菜单（Battle 在我方回合开始时调用）。
## 参数 unit：当前行动的我方单位；允许传 null（此时标题显示"指令"、法术按钮禁用，
##            算是给"没有行动者却误开菜单"留的兜底，不会崩）。
## 返回值：无。
## 副作用：
##   · 写 _unit；改写 title_label.text；按 unit 是否有技能设置 skill_button.disabled；
##   · 调 _show_main() 把容器切回主菜单视图，再 show() 显示整个 Panel。
##   · **不**发任何信号（打开菜单是纯 UI 行为）。
## 为什么要重置成主菜单：单位行动结束后菜单会 close()，下次 open_for 时如果还停在技能页，
##   玩家会看到一个没有"返回"上下文的界面，体验很怪。所以每次都从主菜单开始。
## 注意 skill_button.disabled 是"有没有技能"，不是"现在能不能放某个技能"——
##   具体某个技能能不能放，是在 _make_skill_button() 里逐个按钮判断的。
func open_for(unit: BattleUnit) -> void:
	_unit = unit
	# 双层判空：unit 本身可能是 null，unit.stats 也可能是 null（资源没配）。
	if unit != null and unit.stats != null:
		title_label.text = unit.stats.name
	else:
		title_label.text = "指令"
	# `unit == null or not unit.has_skills()`：先判空再调方法，靠 or 的短路求值避免 null 访问。
	skill_button.disabled = unit == null or not unit.has_skills()
	_show_main()
	show()


## 关闭菜单。
## 参数/返回值：无。
## 副作用：hide() + 把 _unit 置 null（释放对单位的引用，避免战斗结束后菜单还攥着一个旧对象）。
## 注意：它**不重置可见性**（不清 main/skill 页面的显示状态）、也不发信号 ——
##   所以调用方要自己保证下次 open_for() 会重新 _show_main()（open_for 确实这么做了）。
## 谁调：Battle._ready 以外的几乎所有流程节点：start_battle / _on_command_selected /
##   _on_skill_selected / _finish_battle。
func close() -> void:
	hide()
	_unit = null


# ══════════════════════════════════════════════════════════
#  主菜单 / 技能菜单
# ══════════════════════════════════════════════════════════

## 切到主菜单视图（隐藏技能页与返回按钮）。
## 参数/返回值：无。
## 副作用：改三个可见性开关（main_buttons / skill_buttons / back_button）。**不显示/隐藏整个 Panel** ——
##         整个菜单的显隐由 open_for() 的 show() 与 close() 的 hide() 负责，两件事分开管。
## 谁调：_ready()（初始化）、open_for()（每次打开都归位）、back_button 的 pressed 信号（从技能页返回）。
## 关键：从技能页返回时**不发信号**，Battle 完全不知道玩家点过返回 —— 这是对的，
##       因为 state 仍然是 COMMAND，玩家接着点主菜单按钮即可。
func _show_main() -> void:
	main_buttons.visible = true
	skill_buttons.visible = false
	back_button.visible = false


## 打开技能二级菜单：清空旧按钮 → 按当前单位的技能表重建 → 切视图。
## 参数/返回值：无。
## 副作用：
##   · 播一次 UI 音效（SoundManager.play_sound(SoundManager.Sound.UI)）；
##   · **销毁 %SkillButtons 下所有旧子节点**（先 remove_child 再 queue_free，见下方说明）；
##   · 动态创建 Button（或一个"（没有可用技能）"Label）并 add_child 进 %SkillButtons；
##   · 改三个可见性开关（主菜单藏、技能页与返回按钮显示）。
##   · **不发任何信号**（点具体技能才发）。
## 为什么要先 remove_child 再 queue_free：
##   queue_free() 只是"标记本帧末释放"，节点在**本帧剩余时间里仍然留在父节点下**；
##   如果直接 add_child 新按钮，本帧内会出现"旧按钮 + 新按钮"同时存在（可见重叠、布局错乱）。
##   先 remove_child 立刻解绑父子关系，再 queue_free 延迟释放，视觉上就很干净。
##   （turn_order.gd 的 _rebuild() 里是同一个套路，理由一样。）
## 为什么每次重建而不是复用按钮：
##   不同单位的技能数量/内容完全不同，判断"要复用几个、改哪些文字"比直接重建更复杂且更易错；
##   单位数量级的按钮（通常 1~4 个）重建开销可以忽略，按钮多了再改成对象池。
## 空列表兜底：count 为 0 时放一个居中的 Label 提示，而不是让技能页空着（空白页看起来像 bug）。
## 坑：这里读的是 _unit.available_skills（Battle 在生成单位时注入的），不是 UnitStats.skills。
func _open_skills() -> void:
	# 防御性判断：菜单理论上只在 open_for() 之后才会显示，但这里再挡一次 null。
	if _unit == null:
		return
	SoundManager.play_sound(SoundManager.Sound.UI)

	for child in skill_buttons.get_children():
		skill_buttons.remove_child(child)
		child.queue_free()

	var count := 0
	for skill in _unit.available_skills:
		# 技能表里可能有 null 空位（编辑器里拖漏了），跳过而不是崩。
		if skill == null:
			continue
		skill_buttons.add_child(_make_skill_button(skill))
		count += 1
	if count == 0:
		# 纯代码建 Label：horizontal_alignment 设成居中，保证提示文字在按钮栏宽里居中显示。
		var empty := Label.new()
		empty.text = "（没有可用技能）"
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		skill_buttons.add_child(empty)

	main_buttons.visible = false
	skill_buttons.visible = true
	back_button.visible = true


## 为一条技能动态创建一个按钮（含蓝耗、冷却/蓝不够提示、可用性禁用）。
## 参数 skill：技能资源（调用方保证非 null）。
## 返回值：新建的 Button（尚未入树，由 _open_skills() 负责 add_child）。
## 副作用：
##   · 连接新按钮的 pressed → _on_skill_pressed.bind(skill)（bind 把技能带进回调）；
##   · 读 _unit 的当前蓝量与冷却（**不修改任何战斗数据**）。
## 视觉规范：
##   · 尺寸固定 180x46（custom_minimum_size），保证多个技能按钮宽度一致、菜单不跳；
##   · add_theme_font_size_override("font_size", 20) 是"只改这一个实例"的字号覆盖，
##     不会污染全局主题（对比 add_theme_font_size_override vs 主题资源里的字号）。
## 文字组装：`技能名  蓝N  [后缀]`，后缀二选一（互斥，因为冷却中时"蓝够不够"已经不重要了）：
##   · 冷却中 → "  冷却%d"；
##   · 否则蓝不够 → "  蓝不够"；
##   · 否则空串。
## 禁用逻辑：button.disabled = not _unit.can_use_skill(skill) —— 与 Battle._on_skill_selected()
##   里的准入判断用的是同一个函数，保证"能点的必然能用、不能点的点不了"，不会出现两者口径不一致。
##   注意 disabled 只挡 UI 点击；Battle 那边仍然会再校验一次（不信任 UI）。
## 坑：本函数依赖 _unit 非 null（_open_skills 已经保证），且**必须在 _unit 还有效时调用** ——
##   它在 _open_skills() 的循环里同步执行，所以安全。
func _make_skill_button(skill: SkillData) -> Button:
	var button := Button.new()
	var suffix := ""
	var cd := _unit.cooldown_left(skill)
	if cd > 0:
		suffix = "  冷却%d" % cd
	elif _unit.mp < skill.mana_cost:
		suffix = "  蓝不够"
	# int(skill.mana_cost)：蓝耗是 float，显示成 "蓝6" 而不是 "蓝6.0"。
	button.text = "%s  蓝%d%s" % [skill.display_name, int(skill.mana_cost), suffix]
	button.custom_minimum_size = Vector2(180, 46)
	button.add_theme_font_size_override("font_size", 20)
	button.disabled = not _unit.can_use_skill(skill)
	# bind(skill)：pressed 信号无参数，bind 的值会作为第一个参数传给 _on_skill_pressed。
	button.pressed.connect(_on_skill_pressed.bind(skill))
	return button


# ══════════════════════════════════════════════════════════
#  按钮回调（把 UI 事件翻译成信号）
# ══════════════════════════════════════════════════════════

## 主菜单按钮的共用回调（四个按钮通过 bind() 把各自的指令标识传进来）。
## 参数 command：指令标识（&"attack" / &"defend" / &"flee" / &"item"）。
## 返回值：无（**不发 await** —— 发完信号就结束，后续流程完全交给 Battle，
##         所以菜单不会因为 Battle 的演出而卡住，甚至能立刻被 hide()）。
## 副作用：播一次 UI 音效；emit command_selected(command)。
## 注意这里**不**关菜单：关菜单是 Battle._on_command_selected() 的职责，
##   因为有些分支（道具未实现、技能未实现）需要保持菜单打开让玩家重选。
##   本组件刻意不做任何"自以为聪明"的状态处理，保持纯粹。
func _on_main_pressed(command: StringName) -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	command_selected.emit(command)


## 技能按钮的回调（每个按钮通过 bind() 带上自己的 SkillData）。
## 参数 skill：被点击的技能。
## 返回值：无（同步）。
## 副作用：播一次 UI 音效；emit skill_selected(skill)。
## 注意：这里也**不做**蓝量/冷却校验 —— 按钮虽已 disabled，但那只是 UI 层；
##   真正的准入由 Battle._on_skill_selected() 里的 can_use_skill() 负责（不信任 UI 是原则）。
## 另外这里也不关菜单，同样由 Battle 决定（它会先 close() 再进目标选择）。
func _on_skill_pressed(skill: SkillData) -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	skill_selected.emit(skill)
