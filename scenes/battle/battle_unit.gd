# ═══════════════════════════════════════════════════════════════════════════════
#  battle_unit.gd —— 单个战斗单位（一个"人"）
# ═══════════════════════════════════════════════════════════════════════════════
#
# 【它在系统里的位置】
#   挂在本项目战斗单位场景（scenes/battle/battle_unit.tscn）的根节点上，是 Node2D。
#   它只负责两件事：
#     1) 保存"这一场战斗里"的可变状态（当前 HP/MP、技能冷却、是否防御、是否存活）；
#     2) 播放自己的表现（攻击位移、施法起手、受击闪烁、选中/目标高亮、血条刷新）。
#   「谁先出手、打谁、什么时候结束」全部由 Battle（scenes/battle/battle.gd）驱动，
#   本脚本没有任何 AI、不知道回合概念、也从不主动调用 Battle —— 依赖是单向的。
#
# 【数据从哪来、到哪去】
#   Battle._spawn_team() 实例化本节点 → add_child() 进 %Units → 调 setup(UnitStats, is_player)
#   之后：
#     · 数值只读地取自 UnitStats（共享 .tres 资源！绝不就地修改，否则所有引用者一起被改）；
#     · 战斗期的可变值全部落在本脚本自己的普通变量上（max_hp/hp/max_mp/mp/cooldowns/defending）；
#     · available_skills 由 Battle 注入（本脚本不认识 Battle.default_skills）；
#     · 对外只通过信号汇报（clicked / hovered / hp_changed / mp_changed / died）——
#       Battle 收集 clicked 与 died，血条自己连 hp_changed（也可以在外部连）。
#
# 【生命周期与坑位】
#   · @onready 变量（sprite / health_bar / ...）只在 _ready() 执行**之前**那一刻被赋值，
#     所以 setup() 里能安全使用它们的前提是"节点已经 add_child 过"。Battle 遵守了这个顺序，
#     本脚本则刻意把资源读取放在 setup() 而不是 _ready()：因为 _ready() 先于 setup() 执行，
#     那时 stats 还是 null，读 stats.icon 会崩。
#   · 本类没有父类自定义脚本，所以 _ready() 里不需要 super._ready()；
#     但如果将来有人继承本类，子类的 _ready() **必须**调 super._ready()，
#     否则下面的信号连接与 _ignore_mouse 处理会被整个吃掉（表现为"点了没反应"）。
#   · 节点名用 %Xxx（unique_name_in_owner）取，改层级也不会失效；代价是场景里必须勾上唯一名称。
#
# 【扩展点】
#   · 伤害/暴击/格挡公式 → roll_damage() / roll_crit() / try_block()
#   · 技能数值           → skill_damage() / skill_crit()
#   · 动作演出           → play_attack() / play_cast() / play_hit()（现在是最简 Tween，可换成 AnimationPlayer）
#   · 状态效果（Buff/Debuff）→ 现在完全没有，建议加 status 字典 + tick_status() 并在 Battle._next_round 里调
# ═══════════════════════════════════════════════════════════════════════════════
extends Node2D
class_name BattleUnit

## 战斗单位：血量/蓝量状态 + 表现。战斗流程（谁出手、打谁、什么时候结束）由 Battle 驱动。
##
## 数据来源：UnitStats（name / icon / health / mana / damage / speed / block_chance / skills）
## 扩展点：
##   · 伤害公式        → roll_damage() / roll_crit() / try_block()
##   · 技能数值        → skill_damage() / skill_crit()（火球术在 resources/skills/skill_fireball.tres）
##   · 动作演出        → play_attack() / play_cast() / play_hit()（现在是最简 Tween）
##   · 状态效果(Buff)  → 以后在这里加 status 字典 + tick_status()

# ── 对外信号 ──────────────────────────────────────────────────────────────────
# 本脚本只"汇报发生了什么"，从不自己决定流程怎么走 —— 所有决策都在 Battle。

## 鼠标左键点到本单位（由 %ClickArea 的 input_event 转发，见 _on_click_area_input_event）。
## 谁接：Battle._on_unit_clicked()。注意**敌我双方**的单位都会发这个信号，
##       是 Battle 靠 state 判断"现在是不是在选目标"来决定要不要响应。
## 坑：单位阵亡后（_die()）会把 click_area.input_pickable 关掉，所以死人不会再发这个信号。
signal clicked(unit: BattleUnit)

## 鼠标进入/离开本单位。
## 参数 entered：true = 进入，false = 离开。
## 谁接：目前项目内没有消费者；预留给"敌方信息浮窗 / 悬停预览"这类交互。
signal hovered(unit: BattleUnit, entered: bool)

## 血量变化（_refresh_hp() 里发）。参数是本单位自己，方便接收方直接拿数据。
## 谁接：目前内部没有连接（血条是在 _refresh_hp() 里直接调的），留给外部的战斗日志/悬浮卡。
signal hp_changed(unit: BattleUnit)

## 蓝量变化（_refresh_mana() 里发）。
## 谁接：BattleUnit 自己在 start_cooldown() 里会再 emit 一次（见那里的说明），
##       目的是让指令菜单的技能按钮刷新"蓝不够/冷却 N"的显示。
signal mp_changed(unit: BattleUnit)

## 单位阵亡（_die() 里发，此时 alive 已经为 false、点选已关闭、淡出 tween 已启动）。
## 谁接：Battle._on_unit_died() —— 只用来刷新左侧出手顺序条，**不会**从回合队列里移除自己。
## 重要：本信号只发一次（_die() 被 take_damage() 保证只调一次），但接收方不应假设节点已释放 ——
##       单位死后节点仍然存在（只是 visible=false），Battle 靠 alive 过滤而不是靠 is_instance_valid。
signal died(unit: BattleUnit)

# ── 视觉常量（选中/目标/悬停/受击/防御/施法的配色）────────────────────────────
# 全部写死在脚本里而不是 @export：这些是"全局统一的战斗语言"，每个单位都不一样反而会乱。
# 颜色都带 alpha（0.2~0.35），因为它们是铺在 %Selection 这个 Polygon2D 上的半透明圈。

## 当前行动者（我方回合）的高亮圈：暖黄 30% 透明。
const SELECT_COLOR := Color(1.0, 0.86, 0.35, 0.30)
## 待选目标（敌人）的高亮圈：红色 35% 透明 —— 与 SELECT_COLOR 明显区分，避免误判。
const TARGET_COLOR := Color(1.0, 0.35, 0.35, 0.35)
## 鼠标悬停且既非选中也非目标时的弱高亮：白色 20% 透明，只做"可点"的暗示。
const HOVER_COLOR := Color(1.0, 1.0, 1.0, 0.20)
## 受击闪烁色：偏红。注意 modulate 是**乘法**染色，所以 (1.0,0.45,0.45) 会让红通道保持、绿蓝压暗。
const HIT_TINT := Color(1.0, 0.45, 0.45)
## 防御姿态染色：淡蓝。play_cast() / play_hit() 收尾时都会回到这个色（而不是纯白），
## 所以"防御中"的视觉提示能在攻击演出结束后继续保留。
const DEFEND_TINT := Color(0.75, 0.85, 1.0)
## 施法起手时的过曝暖色：G/B 通道都 .>1.0（1.45 / 1.2）—— 这是刻意的"超白发光"效果，
## modulate 允许超过 1，配合场景里 Sprite2D 的混合模式能做出短暂的自发光感。
const CAST_TINT := Color(1.45, 1.2, 0.9)

# ── 轮廓（描边）配色：同一套 shader，靠颜色区分"谁在行动 / 这一下打谁" ────────────
# 和上面 %Selection 的半透明色块是两套东西：色块铺在脚下，轮廓是贴着剪影描一圈实色边（%Outline）。
# 都不带 alpha（描边就是实色），也不做 @export：这是全局统一的战斗语言，逐单位配反而会乱。

## 我方行动者轮廓：青色。看到这个颜色就知道"现在轮到我这边的谁"。
const OUTLINE_ALLY_COLOR := Color(0.35, 0.85, 1.0)
## 敌方行动者轮廓：橙红。和上面的青色成对，敌我一眼分得开。
const OUTLINE_ENEMY_COLOR := Color(1.0, 0.38, 0.30)
## 键盘光标/鼠标悬停选中的目标轮廓：金色（配合头顶箭头）。
## 三个颜色刻意互不相同：金色 = "这一下要打它"，青/橙红 = "现在轮到谁行动"。
const OUTLINE_TARGET_COLOR := Color(1.0, 0.85, 0.35)

# ── 数据源与运行时数值 ────────────────────────────────────────────────────────

## 单位数据源（UnitStats 资源：图标 / 血量 / 伤害 / 速度 / 格挡率 / 技能表等）。
## 在检查器里也可以直接拖（但正式流程都是 Battle.setup() 注入的）。
## 重要：这是**共享资源**，一个 .tres 可能被多个单位、甚至被场景文件同时引用。
##      所以本脚本从头到尾只读它；任何战斗期的可变值都写在下面的普通变量里。
##      一旦有人写了 stats.health = xxx，所有引用同一资源的单位都会一起变（经典坑）。
@export var stats: UnitStats

## 是否我方单位。由 setup() 写入。用途：贴图翻转、血条/蓝条配色、以及 Battle 的回合分发判断
## （Battle 用的是同一份数据，但读的是它的副本 —— 两边都靠 setup 一次性赋值，不会不同步）。
var is_player := false
## HP 上限。默认 1.0 只是"未初始化"的占位值；真正的值在 setup() 里取 maxf(1.0, stats.health)。
var max_hp := 1.0
## 当前 HP。降到 0 触发 _die()。注意它是 float，飘字时才 int() 取整。
var hp := 1.0
## MP 上限。默认 0.0 表示"没配蓝" → 蓝条隐藏（见 _refresh_visuals）。
var max_mp := 0.0
## 当前 MP。技能消耗走 spend_mana()，不会低于 0。
var mp := 0.0
## 是否存活。_die() 置 false 且**不会**再变回 true（setup() 里才会重置）。
## 所有"能不能行动/能不能被打/能不能被选"的判断都依赖它。
var alive := true
## 是否处于防御姿态。效果在 take_damage() 里：伤害 ×0.5（下限 1）。
## 注意它**不会**自动过期 —— 当前实现是"防御一次之后就永久防御"，
## 因为没有回合结束的钩子来清理它（Battle 目前只调 set_defending(true)，从不调 false）。
var defending := false

## skill_id -> 剩余冷却回合数
## 用技能 id 字符串做键（而不是 SkillData 引用）：
##   · Resource 作字典键依赖引用相等，同一个技能的不同实例会被当成不同键，容易出错；
##   · id 可序列化，将来存档/调试也方便。
## 值减到 <=0 时由 tick_cooldowns() 删掉这个键（而不是留着 0），所以 has() 判断即可代表"冷却中"。
var cooldowns: Dictionary[String, int] = {}
## 这个单位本场能用的技能（Battle 在生成时填：优先 UnitStats.skills，否则用 Battle.default_skills）
## 注意：这里存的可能是 UnitStats.skills 那个数组本身（不是拷贝），所以只读不改。
## 指令菜单靠它决定"法术按钮亮不亮"以及二级菜单列哪几条。
var available_skills: Array[SkillData] = []

# ── 高亮状态（私有，统一由 _update_selection() 消费）─────────────────────────
# 三个布尔分开存，是为了让"取消目标高亮"不会误清掉"当前行动者高亮"；
# 最终显示什么颜色由 _update_selection() 里的优先级决定（目标 > 选中 > 悬停）。
var _selected := false
var _targetable := false
var _hovered := false
## 是不是"键盘光标当前停留的目标"。
## 和 _targetable 的区别：_targetable = "所有候选目标"（红框，鼠标键盘都能点）；
##                       _focused  = "光标停在的那一个"（额外加轮廓 + 头顶箭头）。
var _focused := false
## 箭头静止时的高度。_process 里的上下浮动以它为基准（不浮动时也要精确回到这里）。
var _arrow_base_y := 0.0
## 记录 sprite 的初始缩放（场景里可能不是 1.0）。
## play_cast() 的"涨大再复原"必须回到这个基准值，否则多放几次技能精灵会越来越小/越来越大。
var _base_scale := Vector2.ONE

# ── 节点引用（%Xxx = unique_name_in_owner，改层级也不会失效）──────────────────
# 这些 @onready 变量在 _ready() 之前被赋值；_refresh_* 系列函数依赖它们，
# 所以 setup() 必须在本节点 add_child() 之后才被调用（Battle 遵守了这一点）。
@onready var sprite: Sprite2D = %Sprite
@onready var health_bar: HealthBar = %HealthBar
@onready var mana_bar: HealthBar = %ManaBar
@onready var name_label: Label = %NameLabel
@onready var selection: Polygon2D = %Selection
@onready var click_area: Area2D = %ClickArea
## 选中轮廓层：Sprite 的子节点（show_behind_parent = true，画在本体后面），
## 用同一张贴图 + 内嵌描边 shader 把剪影往外扩一圈实心色。可见性由 set_focused() 控制。
## 为什么挂成 Sprite 的子节点：这样它自动继承本体的缩放/位置（play_cast() 会 tween sprite.scale，
## 若轮廓是兄弟节点，施法涨大时轮廓就会错位）。
@onready var outline: Sprite2D = %Outline
## 头顶小箭头（Polygon2D，纯几何图形，不需要素材）。只在 set_focused(true) 时显示，并上下浮动。
@onready var target_arrow: Polygon2D = %TargetArrow


# ── 生命周期与初始化 ──────────────────────────────────────────────────────────

## 生命周期入口：节点进树后由引擎调用（在 setup() 之前 —— 但注意 setup() 是 Battle 在
## add_child() 之后立刻手动调的，所以实际顺序是：进树 → _ready() → setup()）。
## 参数/返回值：无。
## 副作用：
##   · 缓存 sprite 的初始缩放（_base_scale），供 play_cast() 做"涨大再复原"；
##   · connect %ClickArea 的 input_event / mouse_entered / mouse_exited 三个信号到本类回调；
##   · 递归把血条/蓝条/名字（以及它们的 Control 子节点）设成不接收鼠标事件。
## 为什么不在这里读 stats：_ready() 执行时 stats 还没被 setup() 写入，仍然是 null，
##   此时 `stats.icon` 会直接崩。所有依赖 stats 的初始化都必须在 setup() 里做。
## 不需要 super._ready()：本类的父类是引擎内建 Node2D，没有可转发的自定义初始化。
##   但如果有人写 `extends BattleUnit` 的子类，子类 _ready() **必须**调 super._ready()，
##   否则上面三条副作用全部丢失 —— 表现为"单位点不动、血条挡住点击"。
func _ready() -> void:
	_base_scale = sprite.scale
	_arrow_base_y = target_arrow.position.y
	# 箭头浮动是"每帧"的事，只对键盘光标所在的目标有意义；默认关掉，set_focused() 里再开。
	set_process(false)
	click_area.input_event.connect(_on_click_area_input_event)
	click_area.mouse_entered.connect(_on_mouse_entered)
	click_area.mouse_exited.connect(_on_mouse_exited)
	# 血条/蓝条/名字都是 Control，默认会吃鼠标事件 → 会让"点单位选目标"点不到
	# （Control 的 mouse_filter 默认是 STOP，会把事件吞掉，Area2D 就收不到 input_event 了）
	_ignore_mouse(health_bar)
	_ignore_mouse(mana_bar)
	_ignore_mouse(name_label)


## 把自身及所有 Control 子节点设成不接收鼠标事件
## 参数 node：起始节点（本项目传的是血条/蓝条/名字 Label）。
## 返回值：无。
## 副作用：就地修改每个 Control 的 mouse_filter 属性。
## 说明：
##   · 递归是因为 Blood 条这类节点内部还嵌着 ProgressBar / Label，只设最外层不够；
##   · 判断 `node is Control` 是必要的 —— 血条根节点是 Control，但它的某些子节点可能是 Node2D；
##   · 用 MOUSE_FILTER_IGNORE（完全穿透，连 hover 都不产生）而不是 MOUSE_FILTER_PASS。
## 注意：这是"就地改属性"，改的是场景实例自己的属性，不会污染 .tscn（每个实例互不影响）。
func _ignore_mouse(node: Node) -> void:
	if node is Control:
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in node.get_children():
		_ignore_mouse(child)


## 由 Battle 在 add_child() 之后调用
## 参数 p_stats：单位的数值/贴图资源（只读，本函数不会改它）；p_is_player：是否我方。
## 返回值：无。
## 副作用：
##   · 覆写 stats / is_player / max_hp / hp / max_mp / mp / alive / defending；
##   · **清空 cooldowns**（同一个节点被复用再 setup 一次时，冷却会归零）；
##   · 调 _refresh_visuals()，进而刷新贴图、名字、血条、蓝条（并 emit hp_changed / mp_changed）。
## 设计要点：
##   · HP/MP 一律"满血满蓝"开局：maxf(1.0, stats.health) 和 maxf(0.0, stats.mana) 里的
##     maxf 是给资源写错值（0 或负数）兜底 —— HP 下限 1 保证不会一开局就判死，
##     MP 下限 0 允许"没法力"的单位存在（此时蓝条会被隐藏）；
##   · 名字区分 p_ 前缀：参数名不能和成员变量 stats / is_player 同名，否则赋值会歧义；
##   · 这个函数是"重新初始化"，所以它是唯一会把 alive 重新置 true 的地方。
func setup(p_stats: UnitStats, p_is_player: bool) -> void:
	stats = p_stats
	is_player = p_is_player
	max_hp = maxf(1.0, stats.health)
	hp = max_hp
	max_mp = maxf(0.0, stats.mana)
	mp = max_mp
	alive = true
	defending = false
	cooldowns.clear()
	_refresh_visuals()


## 依据 stats / is_player / 当前 HP·MP 把界面刷成正确样子。
## 参数/返回值：无。
## 副作用：
##   · 写 sprite.texture / name_label.text / sprite.flip_h / 两条 bar 的 self_modulate 与 visible；
##   · 间接触发 _refresh_hp() 与 _refresh_mana()，因此会 emit hp_changed 和 mp_changed。
## 视觉规则：
##   · 敌人整体水平翻转（flip_h），这样正对镜头/朝向我方，不用做两套素材；
##   · 我方血条/蓝条纯白（原色），敌方偏红/偏蓝 —— 用 self_modulate 做乘法染色，
##     而**不是** modulate：self_modulate 只影响自己不影响子节点，避免把数字文字也一起染红；
##   · MP 上限为 0 的单位直接隐藏整条蓝条（配合 max_mp > 0.0 的判断）。
## 调用时机：只在 setup() 里调一次；战斗中掉血/耗蓝走 _refresh_hp() / _refresh_mana()。
func _refresh_visuals() -> void:
	sprite.texture = stats.icon
	name_label.text = stats.name
	# 敌人翻转：flip_h 只影响绘制，不改坐标/碰撞，所以点击区域不受影响。
	sprite.flip_h = not is_player
	health_bar.self_modulate = Color(1, 1, 1) if is_player else Color(1, 0.72, 0.72)
	# 没蓝的单位（max_mp == 0）不显示蓝条，省得所有敌人都挂着一条空槽。
	mana_bar.visible = max_mp > 0.0
	mana_bar.self_modulate = Color(1, 1, 1) if is_player else Color(0.85, 0.85, 1)
	_refresh_hp()
	_refresh_mana()


# ══════════════════════════════════════════════════════════
#  数值（想改公式只动这里）
# ══════════════════════════════════════════════════════════

# ══════════════════════════════════════════════════════════
#  数值（想改公式只动这里）
# ══════════════════════════════════════════════════════════
# 这一节是 damage / crit / block / speed 的**唯一口径**，战斗平衡调整基本都在这里。
# 注意所有随机判定都走 Global.get_chance_success()，它会推进全局随机数序列 ——
# 也就是说"多打一次暴击判定"会间接影响之后掉落/抽卡的随机结果（不是 bug，但调平衡时会困惑）。

## 计算普通攻击的伤害。
## 参数/返回值：float，伤害值，带 1.0 下限（保证任何攻击至少掉 1 血，不会出现"打不动"的死局）。
## 副作用：无（纯函数，不碰随机数）。
## 现状：直接返回 stats.damage —— 没有攻防差、没有随机浮动、没有等级修正。
##   想做浮动伤害就在这里改成 stats.damage * randf_range(0.9, 1.1)。
func roll_damage() -> float:
	return maxf(1.0, stats.damage)


## 判定本次攻击是否暴击。
## 参数 crit_bonus：额外暴击率（技能用 SkillData.crit_bonus 传进来，普攻用默认值 0.0）。
## 返回值：bool。
## 副作用：**推进全局随机数序列**（内部调 Global.get_chance_success）。
## 公式：基础 10% + **角色自己的暴击率**（stats.crit_rate，百分数 /100）+ 技能加成。
##   crit_rate 主要来自门派被动（例如太虚剑宗的「剑心通明」），敌人默认 0 所以行为不变。
##   注意单位是**小数**（0.10 = 10%）而不是百分数 —— get_chance_success 要的也是 0~1。
## 默认参数 0.0 让普攻可以直接 `attacker.roll_crit()` 调用。
func roll_crit(crit_bonus := 0.0) -> bool:
	return Global.get_chance_success(0.10 + stats.crit_rate / 100.0 + crit_bonus)


## 判定目标是否格挡成功（格挡 = 本次攻击完全免伤，只飘 "Blocked!"）。
## 参数/返回值：bool。
## 副作用：**推进全局随机数序列**。
## 公式：stats.block_chance / 100.0 —— **注意这里要除 100**：
##   UnitStats.block_chance 在资源里是按百分数填的（例如 15 表示 15%），
##   而 get_chance_success 要的是 0~1，所以必须除。这是本项目里最容易搞错的口径之一
##   （装备属性 ItemEquipment.block_chance 也是同一套百分数口径，以后接加成时别重复除 100）。
## 坑：资源没填这个字段时默认 0.0 → 永远不格挡（不是 100%）。
func try_block() -> bool:
	return Global.get_chance_success(stats.block_chance / 100.0)


## 本回合缓存的出手速度（由 Battle._next_round() 在排序前调 roll_turn_speed() 写入）。
## ⚠ 为什么必须缓存，不能直接在 sort_custom 的比较函数里调 turn_speed()：
##   Godot 的排序会反复调用比较函数，而 turn_speed() 每次都重新 randf_range，
##   于是"a > b"和"b > a"可能同时为真 —— 引擎会直接报
##     ERROR: bad comparison function; sorting will be broken
##   并且此时的排序结果是**未定义**的（不只是"乱敏"，可能真的乱），控制台还会一直红。
##   缓存之后：每个单位每回合只 roll 一次（乱敏的手感不变），比较函数变成严格全序。
var round_speed := 0.0


## 本次出手的速度值（用于 Battle._next_round 的出手排序）。
## 参数/返回值：float。
## 副作用：**推进全局随机数序列**（randf_range）。
## 公式：stats.speed + randf_range(-4.0, 4.0)，即"乱敏"：±4 的随机扰动。
## 为什么这么设计：
##   · 不做扰动的话，速度相同的单位每回合顺序完全固定，观感很机械；
##   · 所以每回合开始 roll 一次，结果写进 round_speed 供排序使用（见上面那段注释）。
##   · speed 在 UnitStats 里默认 300（单位与像素/秒复用同一个字段），这里只当作大小比较用。
func turn_speed() -> float:
	return float(stats.speed) + randf_range(-4.0, 4.0)


## 每回合开始调一次：roll 出本回合的出手速度并缓存。由 Battle._next_round() 在排序前调用。
## 参数/返回值：返回 roll 出来的值（顺便方便调试打印）。
## 副作用：写 round_speed，并推进随机数序列。
func roll_turn_speed() -> float:
	round_speed = turn_speed()
	return round_speed


## 扣血（战斗里唯一的伤害入口，普攻和技能最后都会走到这里）。
## 参数 amount：伤害值（已包含暴击 ×1.5 等修正）。
## 返回值：无。
## 副作用：
##   · 修改 hp；调 _refresh_hp()（刷新血条 + emit hp_changed）；
##   · hp 归零时调 _die()（关点选、淡出、emit died）。
## 减伤规则：defending 为 true 时伤害 ×0.5，且下限 1.0（防御不能完全免伤）。
## 幂等/防御：已死单位再被打直接 return —— 防止"鞭尸"把 hp 算成负数、或重复触发 _die()。
## 注意 hp 用 maxf(0.0, ...) 夹住下限，所以血条不会出现负值。
func take_damage(amount: float) -> void:
	if not alive:
		return
	var final := amount
	if defending:
		final = maxf(1.0, final * 0.5)
	hp = maxf(0.0, hp - final)
	_refresh_hp()
	if hp <= 0.0:
		_die()


## 回血（当前流程里还没人调用 —— 治疗技能尚未实现，属于"预留但可用"的接口）。
## 参数 amount：回复量（正数）。
## 返回值：无。
## 副作用：修改 hp、调 _refresh_hp()（刷新血条 + emit hp_changed）。
## 规则：用 minf(max_hp, ...) 夹住上限，不会溢出；已死单位不能靠回血复活（直接 return）。
## 注意：传负数会变成扣血（没有校验），但那样不会触发 _die()，所以别这么用。
func heal(amount: float) -> void:
	if not alive:
		return
	hp = minf(max_hp, hp + amount)
	_refresh_hp()


## 刷新血条显示并广播血量变化。
## 参数/返回值：无。
## 副作用：调 health_bar.update_bar(比例, 数值)，然后 emit hp_changed(self)。
## 注意 update_bar 的第二个参数是**原始数值**（不是比例），血条内部直接 str() 显示
## —— 所以血条上会看到 "37" 这种整数文本（hp 本身是 float，会显示成 "37.0" 之类的原始字符串）。
## 除法 max_hp 不会除零：max_hp 在 setup() 里被 maxf(1.0, ...) 保证 >= 1。
func _refresh_hp() -> void:
	health_bar.update_bar(hp / max_hp, hp)
	hp_changed.emit(self)


## 刷新蓝条显示并广播蓝量变化。
## 参数/返回值：无。
## 副作用：调 mana_bar.update_bar(比例, 数值)，然后 emit mp_changed(self)。
## 为什么 if max_mp > 0.0 才更新：max_mp 为 0 的单位蓝条是隐藏的，
##   更新它没有意义，更重要的是避免 0/0 得到 NaN 写进 ProgressBar（会污染显示）。
## 注意：**mp_changed 任何情况下都会 emit**（在 if 之外）—— 因为指令菜单靠这个信号刷新
##   "蓝不够 / 冷却 N" 的按钮文字，即使这个单位没有蓝条也必须收到通知。
func _refresh_mana() -> void:
	if max_mp > 0.0:
		mana_bar.update_bar(mp / max_mp, mp)
	mp_changed.emit(self)


## 死亡处理（hp 归零时由 take_damage() 调用，内部不再校验 alive）。
## 参数/返回值：无。
## 副作用（一次性、不可逆）：
##   · alive = false、defending = false（死了就没有防御姿态）；
##   · 取消选中与目标高亮（set_selected/set_targetable(false)）；
##   · click_area.input_pickable = false（关掉鼠标拾取，死人点不到了）；
##   · name_label 变半透明，并用 Tween 把整个节点淡出到 alpha 0，最后 visible = false；
##   · **emit died(self)**。
## 重要：**不 queue_free()**。节点会留在场上（只是不可见、不可点），
##   原因是 Battle 的成员列表、顺序条、以及跨 await 的引用都还指着这些对象，
##   真正释放统一由 Battle._clear_units() 在重开/切场时负责。
## 表现细节：
##   · 淡出用 `modulate:a` 这个属性路径（Tween 支持子属性），tween_callback 在淡出结束后隐藏；
##   · name_label 单独调暗是因为它是 Control，不随 Node2D 的 modulate 一起被正确混合（视觉分层考虑）；
##   · died 信号在最后发出，保证接收方收到时"节点已经处于最终状态"。
func _die() -> void:
	alive = false
	defending = false
	set_selected(false)
	set_targetable(false)
	set_focused(false)
	click_area.input_pickable = false
	name_label.modulate = Color(1, 1, 1, 0.35)
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, 0.45)
	tween.tween_callback(func() -> void: visible = false)
	died.emit(self)


# ══════════════════════════════════════════════════════════
#  技能：蓝量 / 冷却 / 数值
# ══════════════════════════════════════════════════════════
# 本节的职责边界：
#   · 本脚本负责"蓝够不够、在不在冷却、数值怎么算"；
#   · "什么时候扣蓝、什么时候进冷却、往谁身上打"由 Battle 决定（Battle._perform_skill）。
# 冷却用**回合数**而非引擎 Timer 计时（见 tick_cooldowns 的说明）。

## 本单位是否有可用技能（有没有技能表，不看蓝量和冷却）。
## 参数/返回值：bool。
## 副作用：无。
## 谁用：Battle 把它间接反映到指令菜单 —— CommandMenu.open_for() 会用它决定"法术"按钮的 disabled。
## 注意语义边界：有技能 ≠ 现在放得出来（蓝不够/冷却中仍然返回 true）。能不能放要看 can_use_skill()。
func has_skills() -> bool:
	return not available_skills.is_empty()


## 判断某个技能"现在能不能放"（蓝够 + 不在冷却 + 自己活着）。
## 参数 skill：技能资源，允许传 null。
## 返回值：bool。
## 副作用：无（纯查询，不扣蓝不进冷却）。
## 三重条件：
##   · skill == null 或 not alive → false（死人不能施法，也避免下面读 skill.mana_cost 崩）；
##   · mp < skill.mana_cost → false（**严格小于**：蓝刚好等于消耗时是允许的）；
##   · cooldown_left(skill) > 0 → false。
## 谁用：Battle._on_skill_selected() 的准入判断、CommandMenu._make_skill_button() 的 disabled。
func can_use_skill(skill: SkillData) -> bool:
	if skill == null or not alive:
		return false
	if mp < skill.mana_cost:
		return false
	if cooldown_left(skill) > 0:
		return false
	return true


## 查询某个技能还剩几回合冷却。
## 参数 skill：技能资源，允许传 null。
## 返回值：int，剩余回合数；0 表示可用（**不存在的键也返回 0**，这是本函数的默认语义）。
## 副作用：无。
## 用 skill.id 而不是 skill 对象本身做键：Resource 作字典键按引用比较，
##   同一个技能的不同实例会被当成不同技能，用 id 字符串更稳、也便于序列化。
## 注意：skill 为 null 时也返回 0（而不是报错），调用方省一次判空。
func cooldown_left(skill: SkillData) -> int:
	if skill == null or not cooldowns.has(skill.id):
		return 0
	return cooldowns[skill.id]


## 扣除法力值。
## 参数 amount：消耗量（SkillData.mana_cost）。
## 返回值：无。
## 副作用：修改 mp → 调 _refresh_mana() → 刷新蓝条并 emit mp_changed（指令菜单据此刷新按钮）。
## 注意：用 maxf(0.0, ...) 夹住下限；调用方（Battle._perform_skill）会先用 can_use_skill 校验，
##   所以正常情况下不会出现"蓝不够还硬扣"。
func spend_mana(amount: float) -> void:
	mp = maxf(0.0, mp - amount)
	_refresh_mana()


## 让某个技能进入冷却。
## 参数 skill：技能资源（为 null 直接 return，防止写进一个 "null" 键）。
## 返回值：无。
## 副作用：
##   · 写入 cooldowns[skill.id]；
##   · **额外 emit mp_changed(self)** —— 这是刻意的"借用"：
##     扣蓝走 _refresh_mana() 时已经发过一次 mp_changed，这里再发一次是为了让指令菜单
##     在"蓝没变但冷却变了"的情况下也能刷新按钮上的"冷却 N"文字。
##     语义上有点脏（蓝量信号表示冷却变化），但省了一个专用信号。
## 公式：cooldowns[id] = maxi(剩余, skill.cooldown) —— 取较大值。
##   为什么不是直接赋值：如果同一回合内先被别的效果加了长冷却，再放一次短冷却的技能，
##   直接赋值会把长冷却改短（相当于"卡冷却"）。取 max 更保守。
##   反过来说，重复施放同一技能不会叠加冷却（不会变成 2×cooldown）。
func start_cooldown(skill: SkillData) -> void:
	if skill == null:
		return
	var left := cooldown_left(skill)
	cooldowns[skill.id] = maxi(left, skill.cooldown)
	mp_changed.emit(self)          # 顺便刷新技能菜单的显示


## 每回合开始时调用（Battle._next_round 里对全体单位调一次）
## 参数/返回值：无。
## 副作用：把 cooldowns 里每个技能的剩余回合数 -1，并把减到 <=0 的键**删除**。
## 实现说明（为什么要两趟）：
##   · 第一趟只做递减 + 记录待删键，第二趟才 erase —— 因为在 `for key in cooldowns.keys()` 的
##     迭代过程中直接 erase 会破坏迭代（Godot 的字典迭代器不允许边遍历边改），
##     这是个很容易踩的坑，所以专门用 expired 数组暂存。
## 与 Timer 的区别（重要）：
##   冷却用的是"回合数"而不是引擎 Timer，因为它是回合制逻辑时间，和真实时间无关 ——
##   玩家在指令菜单停留多久都不影响冷却。如果用 Timer，暂停/加速/切场景都会出问题。
## is_empty() 提前返回只是个小优化（大多数单位大多数时候没有冷却）。
func tick_cooldowns() -> void:
	if cooldowns.is_empty():
		return
	var expired: Array[String] = []
	# 显式写 `for key: String in cooldowns.keys()` 是为了让 key 有明确类型
	# （Dictionary[String, int] 的 keys() 返回弱类型 Array，加类型标注可避免隐式转换告警）。
	for key: String in cooldowns.keys():
		cooldowns[key] = cooldowns[key] - 1
		if cooldowns[key] <= 0:
			expired.append(key)
	for key in expired:
		cooldowns.erase(key)


## 计算技能伤害。
## 参数 skill：技能资源（允许 null —— 这时退化成普通攻击的 roll_damage()）。
## 返回值：float，带 1.0 下限。
## 副作用：传 null 时会走 roll_damage()（纯函数）；正常情况下本函数自身不碰随机数。
## 公式：skill.power × stats.damage。power 是"倍率"（火球默认 2.2），
##   所以技能伤害完全跟着施法者的 damage 缩放 —— 想让技能不随装备成长，就把公式改成加法。
func skill_damage(skill: SkillData) -> float:
	if skill == null:
		return roll_damage()
	return maxf(1.0, skill.power * stats.damage)


## 判定技能是否暴击。
## 参数 skill：技能资源（允许 null）。
## 返回值：bool（走 roll_crit()，即基础 10% + skill.crit_bonus）。
## 副作用：**推进全局随机数序列**（内部调 Global.get_chance_success）。
## 用三目表达式而不是提前 return，是因为这里只有"加成取值"一处差异，写成一行更清楚。
func skill_crit(skill: SkillData) -> bool:
	return roll_crit(skill.crit_bonus if skill != null else 0.0)


# ══════════════════════════════════════════════════════════
#  选中 / 目标高亮
# ══════════════════════════════════════════════════════════
# 这里只是"标记 + 重算颜色"，不动任何战斗数值。
# 三个标记（_selected / _targetable / _hovered）分开存、统一在 _update_selection() 里合成，
# 好处是取消其中一种高亮时不会误伤另外两种。

## 设置"当前行动者"高亮。
## 参数 value：true 开 / false 关。
## 返回值：无。
## 副作用：
##   · 写 _selected 并调 _update_selection()（改 %Selection 的 visible / color）；
##   · 再调 _refresh_outline()：顺带点亮/熄灭"行动者轮廓"（我方青色、敌方橙红）。
##   · 不改任何战斗数据。
## 谁用：Battle._begin_turn() 给当前行动者点亮、_finish_turn() / _finish_battle() 熄灭。
func set_selected(value: bool) -> void:
	_selected = value
	_update_selection()
	_refresh_outline()


## 设置"可被选为目标"高亮（红圈）。
## 参数 value：true 开 / false 关。
## 返回值：无。
## 副作用：写 _targetable 并调 _update_selection()。
## 谁用：Battle._begin_target_select() 对每个候选敌人调 true，_highlight_targets() 调 false 取消。
## 注意：这个标记只管**视觉**，不影响点击能不能被接收 ——
##   真正决定"点了有没有用"的是 Battle 的 state 与 _targets.has(unit) 判断。
func set_targetable(value: bool) -> void:
	_targetable = value
	_update_selection()


## 把"键盘目标光标"放到这个单位身上：显示选中轮廓 + 头顶箭头，并让箭头上下浮动。
## 参数 value：true = 光标停在这里；false = 光标离开。
## 返回值：无。
## 副作用：
##   · 写 _focused；开关 %Outline / %TargetArrow 的 visible；
##   · 开关 _process（只有光标所在的单位每帧跑浮动动画，其余单位零开销）；
##   · 显示时把本体贴图与翻转同步给轮廓层（轮廓是 Sprite 的子节点，这两项不会自动继承）。
## 谁用：Battle._refresh_target_focus()（键盘选目标时）/ 鼠标悬停同步（Battle._on_unit_hovered）。
## 死人一律不显示：value 为 true 但 alive 为 false 时也会隐藏，避免尸体顶着箭头。
func set_focused(value: bool) -> void:
	_focused = value
	var show_it := value and alive
	target_arrow.visible = show_it
	set_process(show_it)
	if not show_it:
		target_arrow.position.y = _arrow_base_y
	_refresh_outline()


## 底层接口：直接开/关轮廓并指定颜色（不参与优先级判断，一般不用直接调）。
## 参数 active：true 显示；color：描边颜色。
## 返回值：无。
## 副作用：
##   · 改 %Outline 的 visible；显示时同步本体贴图与翻转（轮廓是 Sprite 的子节点，这两项不会自动继承）；
##   · 写**自己那份** ShaderMaterial 的 outline_color —— battle_unit.tscn 里该材质设了
##     resource_local_to_scene = true，所以每个单位一份副本，改颜色不会串到别的单位身上。
func set_outline(active: bool, color: Color) -> void:
	var show_it := active and alive
	if show_it:
		outline.texture = sprite.texture
		outline.flip_h = sprite.flip_h
		var mat := outline.material as ShaderMaterial
		if mat != null:
			mat.set_shader_parameter("outline_color", color)
	outline.visible = show_it


## 轮廓的唯一"真相出口"：按优先级决定显示哪个颜色（分工和 _update_selection() 一致）。
## 参数/返回值：无。
## 优先级：键盘光标（金色 + 箭头）> 行动者（我方青 / 敌方橙红）> 不显示。
## 为什么不叠加：轮廓只有一圈，两种状态同时成立时"这一下要打谁"比"谁在行动"更重要；
##   而且玩家的单位在当前的选目标逻辑里不会成为目标，所以实际几乎不会撞在一起。
## 谁调：set_focused() / set_selected()。
func _refresh_outline() -> void:
	if _focused and alive:
		set_outline(true, OUTLINE_TARGET_COLOR)
	elif _selected and alive:
		set_outline(true, OUTLINE_ALLY_COLOR if is_player else OUTLINE_ENEMY_COLOR)
	else:
		set_outline(false, Color.WHITE)


## 每帧：让头顶箭头上下浮动（只在 set_focused(true) 期间运行，见 _ready 里的 set_process(false)）。
## 为什么用 _process 而不是 Tween：Tween 需要管生命周期（换目标时得 kill 掉、还要防重复），
##   而这里只是一个连续的正弦位移，用开关 _process 来省开销最简单也最不容易出错。
func _process(_delta: float) -> void:
	target_arrow.position.y = _arrow_base_y + sin(float(Time.get_ticks_msec()) / 260.0) * 7.0


## 根据三个高亮标记重算 %Selection 的显示与颜色（唯一的"高亮真相"出口）。
## 参数/返回值：无。
## 副作用：写 selection.visible 与 selection.color。
## 优先级（决定颜色）：
##   1) _targetable（待选目标，红）—— 最高，因为它代表"玩家现在应该点这里"；
##   2) _selected（当前行动者，暖黄）；
##   3) 兜底 hover（白，弱）。
## 可见性公式：alive and (_selected or _targetable or _hovered) ——
##   **死了就永远不显示**，即使外层忘了取消高亮（_die() 里也会主动清一次，双保险）。
func _update_selection() -> void:
	selection.visible = alive and (_selected or _targetable or _hovered)
	if _targetable:
		selection.color = TARGET_COLOR
	elif _selected:
		selection.color = SELECT_COLOR
	else:
		selection.color = HOVER_COLOR


## 设置/取消防御姿态（视觉 + 逻辑）。
## 参数 value：true = 进入防御，false = 解除。
## 返回值：无。
## 副作用：
##   · 写 defending（真正生效的是 take_damage() 里的 ×0.5 减伤）；
##   · value 为 true 时创建一个 Tween 把 sprite.modulate 渐变到 DEFEND_TINT（0.15s）；
##   · value 为 false 时**立即**把 sprite.modulate 设回纯白（没有渐变，瞬间恢复）。
## 坑/注意：
##   · 这里 tween 的是 sprite.modulate，而 play_hit()/play_cast() 收尾时也写 sprite.modulate，
##     两处会互相覆盖 —— 所以 play_* 的收尾色特意写成 `DEFEND_TINT if defending else Color.WHITE`，
##     保证"防御中的单位被打一下"之后仍然保持淡蓝。
##   · 防御**不会自动过期**：没有回合结束钩子去调 set_defending(false)，
##     所以当前实现里"防一次 = 永久半伤"。要修的话应该在 Battle._finish_turn() 里解除。
func set_defending(value: bool) -> void:
	defending = value
	if value:
		var tween := create_tween()
		tween.tween_property(sprite, "modulate", DEFEND_TINT, 0.15)
	else:
		sprite.modulate = Color.WHITE


# ══════════════════════════════════════════════════════════
#  表现（演出）—— 都可以换成 AnimationPlayer
# ══════════════════════════════════════════════════════════
# 本节所有 play_* 都是 async（带 await），返回时机就是"演出播完"那一刻，
# 调用方（Battle）靠 await 它们来保证节奏顺序。

## 普攻位移演出：朝目标方向冲出去 80 像素再原路退回。
## 参数 target：被打的目标（只用来取方向，不做伤害 —— 伤害由 Battle._perform_attack 负责）。
## 返回值：无（协程，await 到整个 tween 结束，总时长 0.12 + 0.04 + 0.16 = 0.32s）。
## 副作用：反复写自己的 position；**不 emit 任何信号、不改血量**。
## 坐标换算说明：
##   · `(target.global_position - global_position).normalized()` 得到单位方向向量；
##   · 用 global_position 相减再把位移加到**局部** position 上 —— 只有在"本单位与父节点没有旋转/缩放"时
##     才等价；本项目舞台是纯平移的 Node2D，所以是安全的。若将来父节点带了缩放，这里会走样。
##   · 乘 80.0 是固定的冲刺距离（不按距离比例），保证远近目标的出手幅度一致。
## 坑：如果目标在演出期间被释放，is_instance_valid 判断会直接 return ——
##   但那样 tween 就没跑、函数立刻返回，调用方会以为"演出结束了"，这是刻意的降级（避免卡死）。
func play_attack(target: BattleUnit) -> void:
	if not is_instance_valid(target):
		return
	var from := position
	var dir := (target.global_position - global_position).normalized()
	var to := from + dir * 80.0
	var tween := create_tween()
	tween.tween_property(self, "position", to, 0.12)
	# tween_interval：在 tween 序列里插入一段"什么都不做"的等待，用来让"撞上去"那一瞬间有顿挫感，
	# 也让 Battle 那边紧接着播的受击闪烁不至于和位移重叠得太糊。
	tween.tween_interval(0.04)
	tween.tween_property(self, "position", from, 0.16)
	await tween.finished


## 施法起手：微微涨大 + 染色一下（没有施法动画素材时也有反馈）
## 参数/返回值：无（协程，await 到 tween 结束，总时长约 0.14 + 0.16 = 0.3s）。
## 副作用：写 sprite.scale 与 sprite.modulate。
## 数值说明：
##   · 先设 modulate = Color.WHITE 是为了"清掉上一次残留的受击红/防御蓝"，从干净状态起手；
##   · 放大到 _base_scale * 1.14（+14%）再回落到 _base_scale ——
##     用缓存的 _base_scale 而不是硬写 Vector2.ONE，这样场景里精灵本来有缩放也不会被改坏；
##   · parallel() 让"缩放"和"染色"在**同一段时间**内进行（否则会串行变成 0.28s）；
##   · 收尾色是 DEFEND_TINT if defending else Color.WHITE —— 防御中的单位施法后要保持淡蓝。
## 注意 is_defending 状态下 sprite.scale 不会被 set_defending() 影响，两处不冲突。
func play_cast() -> void:
	sprite.modulate = Color.WHITE
	var tween := create_tween()
	tween.tween_property(sprite, "scale", _base_scale * 1.14, 0.14)
	tween.parallel().tween_property(sprite, "modulate", CAST_TINT, 0.14)
	tween.tween_property(sprite, "scale", _base_scale, 0.16)
	tween.parallel().tween_property(sprite, "modulate", DEFEND_TINT if defending else Color.WHITE, 0.16)
	await tween.finished


## 受击闪烁：快速染红 0.05s，再用 0.15s 恢复。
## 参数/返回值：无（协程，await 到 tween 结束，共 0.2s）。
## 副作用：写 sprite.modulate。
## 恢复色同样是 `DEFEND_TINT if defending else Color.WHITE` —— 这一句是"防御中受击仍然保持淡蓝"的关键，
## 否则被打一下防御的视觉提示就没了（逻辑上的减伤仍在，但玩家看不出来）。
## 注意：闪红用的是 modulate **乘法**染色，所以如果单位本身是暗色贴图，闪红会不明显。
## 本函数不做任何数值结算（伤害在调用方已经扣完），纯粹是表现。
func play_hit() -> void:
	var tween := create_tween()
	tween.tween_property(sprite, "modulate", HIT_TINT, 0.05)
	tween.tween_property(sprite, "modulate", DEFEND_TINT if defending else Color.WHITE, 0.15)
	await tween.finished


# ══════════════════════════════════════════════════════════
#  点击 / 悬停
# ══════════════════════════════════════════════════════════

# ══════════════════════════════════════════════════════════
#  点击 / 悬停
# ══════════════════════════════════════════════════════════
# 这三个回调都来自 %ClickArea（Area2D）。它们能收到鼠标事件的前提有两个，
# 缺一不可：
#   1) 场景根（Battle）里开了 get_viewport().physics_object_picking = true；
#   2) 覆盖在单位上的 Control（血条/蓝条/名字）被设成 MOUSE_FILTER_IGNORE（见 _ignore_mouse）。

## %ClickArea 的 input_event 回调：把左键点击翻译成本类的 clicked 信号。
## 参数：_viewport / _shape_idx 用不到（下划线前缀表示刻意忽略，同时避免未使用参数告警）；
##       event 是原始输入事件。
## 返回值：无。
## 副作用：满足条件时 emit clicked(self)。
## 过滤条件（三个都要满足）：
##   · not alive 直接 return —— 死人点不动（_die() 里也已把 input_pickable 关掉，双保险）；
##   · event is InputEventMouseButton —— 排除鼠标移动/键盘事件；
##   · button_index == MOUSE_BUTTON_LEFT and event.pressed —— 只认左键按下（抬起不触发，
##     否则一次点击会发两次信号）。
## 注意：这里**不**改任何状态、也**不** set_input_as_handled()，
##   所以点击会继续传播（这也是为什么 Battle._unhandled_input 里的 ESC 逻辑不受影响）。
func _on_click_area_input_event(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if not alive:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		clicked.emit(self)


## 鼠标移入：点亮悬停高亮 + 广播 hovered(true)。
## 参数/返回值：无。
## 副作用：
##   · _hovered = true 并调 _update_selection()（白圈）；
##   · emit hovered(self, true)；
##   · 若当前是可选目标（_targetable），把鼠标指针换成"手型"作为额外提示。
## 注意：_update_selection() 里的优先级是 目标 > 选中 > 悬停，
##   所以悬停到一个已高亮的目标上不会把它从红圈改回白圈。
## Input.set_default_cursor_shape 是**全局默认指针**，不是本控件局部设置 ——
##   所以必须在 _on_mouse_exited 里还原成 CURSOR_ARROW，否则鼠标移开后指针会一直停在小手。
func _on_mouse_entered() -> void:
	_hovered = true
	_update_selection()
	hovered.emit(self, true)
	if _targetable:
		Input.set_default_cursor_shape(Input.CURSOR_POINTING_HAND)


## 鼠标移出：取消悬停高亮 + 广播 hovered(false) + 还原鼠标指针。
## 参数/返回值：无。
## 副作用：
##   · _hovered = false 并调 _update_selection()；
##   · emit hovered(self, false)；
##   · 把全局默认指针还原成 CURSOR_ARROW。
## 坑：这里还原指针是无条件的（没判断"当初是不是我改成手型的"）。
##   如果将来有别人也改指针，会互相踩；目前只有本类在改，所以安全。
func _on_mouse_exited() -> void:
	_hovered = false
	_update_selection()
	hovered.emit(self, false)
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)
