# ═══════════════════════════════════════════════════════════════════════════════
#  battle.gd —— 回合制战斗场景的「总导演」
# ═══════════════════════════════════════════════════════════════════════════════
#
# 【它在系统里的位置】
#   本脚本挂在本项目战斗场景（scenes/battle/battle.tscn）的根节点上，是一整场战斗的调度中心。
#   它自己不算伤害、不画血条，只做三件事：排流程、连信号、把表现拼起来。
#     · 上游（谁进来打）：地图/关卡层调用 Battle.start_battle(我方 UnitStats 数组, 敌方 UnitStats 数组)；
#                        在编辑器里单独运行本场景时则由 auto_start_demo 用 DEMO_* 自造一场。
#     · 下游（它生成/驱动什么）：
#         BattleUnit        （scenes/battle/battle_unit.tscn）—— 单位状态与演出，由 _spawn_team() 生成；
#         SkillProjectile   （scenes/effects/projectile/skill_projectile.tscn）—— 公共技能弹道，由 _perform_skill()/_cast_aoe() 生成；
#                            元素外观（火球等）由 SkillData.appearance_scene 挂在弹道的 %Appearance 插槽里，弹道本身不含元素语义；
#         FloatingText      （Global.FLOATING_TEXT_SCENE）—— 伤害/防御飘字，由 create_floating_text() 生成；
#         TurnOrder         （scenes/battle/turn_order.gd）—— 左侧出手顺序条，update_order/set_current 驱动；
#         CommandMenu       （scenes/battle/command_menu.gd）—— 指令菜单，open_for/close 驱动。
#     · 出口（打完怎么走）：结束时 emit battle_ended(player_won)，外部接这个信号去做经验/掉落/回地图。
#
# 【数据从哪来、到哪去】
#   .tres(UnitStats) ──start_battle()──▶ _spawn_team() ──▶ BattleUnit.setup()（HP/MP 落地）
#        └─ .tres(SkillData) ──_skills_for()──▶ BattleUnit.available_skills ──CommandMenu 列成按钮──▶
#           _on_skill_selected() ──▶ _perform_skill() ──▶ 扣蓝/进冷却/飞体/伤害/飘字/镜头抖动
#   全程不回写 UnitStats（它是共享 Resource，就地改会污染所有引用者），
#   战斗期的可变状态（hp/mp/冷却/防御）都存在 BattleUnit 自己的普通变量里。
#
# 【流程骨架（状态机 State）】
#   IDLE → INTRO →（每一回合）TURN_START → [我方：COMMAND → TARGET_SELECT] → EXECUTE → TURN_END
#        → 回到 TURN_START 换下一个人 …… 直到一方全灭/逃跑 → FINISHED
#   出手顺序：每回合开始时把所有存活单位按 turn_speed()（speed + 随机扰动）从高到低排序，
#            也就是「每回合重排」，同一个单位不保证每回合都轮流先手。
#
# 【重要约定与坑位提示（改代码前务必看）】
#   1) 本脚本大量使用 await（等 tween、等 SceneTreeTimer）。因此 _next_round / _begin_turn /
#      _perform_attack / _perform_skill 都是「协程式流程函数」：await 期间玩家照样能点击、按 ESC，
#      单位也可能已经阵亡。所以每个函数在 await 之后都要重新校验 actor / target / is_instance_valid，
#      绝不能假设"进来时的上下文还在"。
#   2) 回合推进完全靠手递手：谁来收尾谁就得调 _finish_turn()（或 _check_battle_end()）。
#      任何提前 return 的分支如果忘了收尾，战斗会永远卡在这一步（信息栏停在"某某的回合"）。
#   3) 运行时 add_child() 进来的节点 owner 是 null，所以这里一律 queue_free() 自己，
#      不要写 owner.queue_free()（会直接失败并报错）。
#   4) _spawn_team() 里必须先 add_child() 再 setup()：setup() 内部会碰 sprite / 血条 / 名字这些
#      @onready 节点，而 @onready 变量只有节点进树之后才会被赋值。
#   5) Timer：这里统一用 get_tree().create_timer(...).timeout 做停顿，它的 one_shot 语义天然是
#      一次性的，不会出现"循环计时器让 is_stopped() 永远 false"那类坑。
#   6) Area2D 的鼠标事件依赖物理点选，_ready() 里显式开了 get_viewport().physics_object_picking。
#
# 【扩展点速查】
#   · 新技能       → 加 resources/skills/*.tres + 在 _perform_skill() 里处理新的 target_mode
#   · 道具         → _on_command_selected() 的 &"item" 分支
#   · 伤害/暴击/格挡 → BattleUnit.roll_damage() / roll_crit() / try_block()
#   · 敌方 AI      → _enemy_act()
#   · 结算（经验/掉落/回地图）→ _finish_battle() 里 battle_ended.emit() 之后
# ═══════════════════════════════════════════════════════════════════════════════
extends Node2D
class_name Battle

## 回合制战斗场景（梦幻西游式骨架）
##
## 结构：Node2D 根（舞台 / 镜头 / 世界特效） + CanvasLayer（UI）
## 流程：Battle 用状态机驱动；出手顺序按 speed 排序，每回合重排
##
## 怎么用：
##   1) 直接 F6 运行本场景 → 用 DEMO_* 里的 .tres 起一场示例战斗，方便调表现
##   2) 从地图进战斗时调用：Battle.start_battle(我方 UnitStats 数组, 敌方 UnitStats 数组)
##   3) 结束用 battle_ended(player_won) 接结算（经验/掉落/回地图）
##
## 站位：改 Stage/PlayerSlots、Stage/EnemySlots 下的 Marker2D 即可，不用改代码
## 扩展点：
##   · 技能            → resources/skills/*.tres（数值+素材都在里面）+ _perform_skill()
##   · 道具            → _on_command_selected() 的 &"item" 分支
##   · 伤害 / 暴击 / 防御 → BattleUnit.roll_damage() / roll_crit() / try_block()
##   · 技能数值        → BattleUnit.skill_damage() / skill_crit()
##   · 敌方 AI          → _enemy_act()
##   · 动作演出         → BattleUnit.play_attack() / play_cast() / play_hit()

# ── 对外信号 ──────────────────────────────────────────────────────────────────
# Battle 只发这三个信号，外部系统（地图/结算/教学/自动战斗）靠 connect 挂钩，
# 而不是反过来让 Battle 去引用外部节点 —— 这样 battle.tscn 可以独立 F6 运行。

## 某个单位的回合刚开始时发出。发出时 state 已经是 TURN_START，actor 已确定且存活。
## 谁来接：目前项目内没内部消费者，预留给"回合开始"的外部处理（Buff 结算、开场特效、语音等）。
signal turn_started(unit: BattleUnit)

## 轮到我方单位、指令菜单已经打开时发出（此时 state = COMMAND，菜单已 open_for(actor)）。
## 谁来接：教学引导、自动战斗/挂机 AI 可以在这里替玩家做决定
##         （直接调 Battle._on_command_selected(&"attack") 之类）。
signal command_requested(unit: BattleUnit)

## 战斗分出结果时发出一次（发出前 state 已置为 FINISHED，菜单已关、目标高亮已清）。
## 参数 player_won：true = 我方还有活人（胜利）；false = 我方全灭，或玩家主动选了"逃跑"。
## 谁来接：地图/结算层 —— 用来发经验、算掉落、切回地图。
signal battle_ended(player_won: bool)

# ── 场景预加载 ────────────────────────────────────────────────────────────────
# 用 preload 而不是运行时 load()：路径写死能在编译期就报错，而且资源常驻内存，
# 不会在战斗中第一次攻击/第一次施法时卡一下 IO。这两个资源每场战斗都必然要用。

## 战斗单位场景（根节点挂 battle_unit.gd）。_spawn_team() 每次实例化一个。
const BATTLE_UNIT_SCENE := preload("res://scenes/battle/battle_unit.tscn")
## 技能飞行体场景（根节点挂 skill_projectile.gd）。每次施法每个目标实例化一个，命中爆炸后自毁。
## 已迁到 scenes/effects/fireball/ 下，和它要用的火焰序列帧素材放在一起。
const SKILL_PROJECTILE_SCENE := preload("res://scenes/effects/projectile/skill_projectile.tscn")
## 默认命中爆炸（程序化的闪光/冲击波/火星/浓烟四层）。
## 群体技能要主动给"每个敌人身上补一朵小爆炸"，所以这里也 preload 一份
## （SkillProjectile.burst() 内部用的是同一个场景，那边有它自己的常量）。
const DEFAULT_BURST_EFFECT_SCENE := preload("res://scenes/effects/burst_effect.tscn")
## 群体技能里"每个敌人身上补的小爆炸"相对 skill.burst_scale 的比例。
## 0.55 = 中心那朵的一半多：亮到能看出"他也被炸了"，又不会喧宾夺主。
const AOE_TARGET_BURST_RATIO := 0.55

# ── 演示队伍（只用于「直接 F6 运行本场景」时调表现）────────────────────────────
# 从地图正式进战斗时不会用到这两个数组：那时由外部把 stats 传进 start_battle()。
# 为什么是 const 存字符串路径而不是 Array[UnitStats]：
#   1) const 只能装编译期常量，装不了 Resource 实例，所以只能先存路径，
#      再由 _load_demo() 用 load() 现场解析成 UnitStats；
#   2) Array[UnitStats] 这种带类型参数的写法只能出现在冒号后（var x: Array[T]），
#      写在等号右边（= Array[T]）会直接解析报错，所以这里也刻意不写类型。
# 直接运行场景时的示例队伍（换成你自己的 .tres 即可）
const DEMO_PLAYERS := [
	"res://resources/units/players/stats_player_knight.tres",
	"res://resources/units/players/stats_player_bunny.tres",
	"res://resources/units/players/stats_player_crazy.tres",
	"res://resources/units/players/stats_player_well_rounded.tres",
	"res://resources/units/players/stats_player_brawler.tres"

]
# 敌方演示队伍：与 DEMO_PLAYERS 一一对应，依次站到 Stage/EnemySlots 的 4 个 Marker2D 上。
# 这四只分别是慢/中/快三种追击者和冲锋兵，刚好覆盖不同 speed，方便观察出手顺序条的重排效果。
const DEMO_ENEMIES := [
	"res://resources/units/enemies/stats_enemy_chaser_slow.tres",
	"res://resources/units/enemies/stats_enemy_chaser_mid.tres",
	"res://resources/units/enemies/stats_enemy_chaser_fast.tres",
	"res://resources/units/enemies/stats_enemy_charger.tres",
	"res://resources/units/enemies/stats_enemy_shooter.tres",
]

# ── 战斗状态机 ────────────────────────────────────────────────────────────────
# 用途：给外部（UI、输入回调、await 之后的续行代码）一个"现在处于哪个阶段"的判断依据。
# 典型用法就是回调第一句 `if state != State.COMMAND: return` —— 把 await 期间涌入的过期输入丢掉。
# 各状态含义与进入时机：
#   IDLE          空闲/未开战。_ready 之前、以及 start_battle() 发现有一方队伍为空时回退到这里。
#   INTRO         已生成双方单位、正在播开场停顿（0.6s），随后进 _next_round()。
#   TURN_START    某个单位的回合刚开始（已 set_current、已 emit turn_started），等 0.15s 小停顿。
#   COMMAND       轮到我方，指令菜单已打开，等玩家点指令。
#   TARGET_SELECT 已选好"攻击"或某个单体技能，敌人已高亮，等玩家点目标（可 ESC/右键取消）。
#   EXECUTE       正在播攻击/施法演出并结算伤害。
#   TURN_END      单人回合收尾（清 actor/_pending_skill、turn_index++），立刻转下一个 _begin_turn()。
#   FINISHED      已分出胜负。_check_battle_end() 会直接返回 true，所有后续流程立刻收敛。
enum State { IDLE, INTRO, TURN_START, COMMAND, TARGET_SELECT, EXECUTE, TURN_END, FINISHED }

# ── 队伍 / 流程（编辑器里可直接配）────────────────────────────────────────────
# 注意 Array[UnitStats] 这种写法：带类型参数的数组类型只能写在冒号后面，
# 写成 `var x = Array[UnitStats]()` 或给 const 加类型都会解析报错（GDScript 限制）。

## 我方队伍（在检查器里把 .tres 拖进来即可，不用改代码）。
## 默认空数组：表示"不预置队伍"，开战时交给 start_battle() 传入，或用 DEMO_PLAYERS 兜底。
## 只有当 auto_start_demo 为 true 且这一项非空时，才会用这里配置的队伍开打（优先级高于 DEMO_*）。
## 数量上限受 Stage/PlayerSlots 下的 Marker2D 个数限制（当前场景是 **5 个：前排 Front1~3 + 后排 Back1~2**），
## 超出部分会被丢掉并 push_warning。
@export var player_team: Array[UnitStats] = []
## 敌方队伍。语义与 player_team 完全对称，站位上限看 Stage/EnemySlots 的 Marker2D 个数（当前也是 5 个：前三后二）。
@export var enemy_team: Array[UnitStats] = []
## 我方单位没在自己的 UnitStats 里配 skills 时，默认给这些技能（火球术）
## 留这个兜底的原因：队伍数值和技能表往往是分两步配的，先有它能立刻跑通整条战斗链路。
## 只在 _skills_for() 里对 is_player 生效 —— 敌人不会被塞默认技能（否则敌人也会放火球）。
## 默认空：什么额外技能都不给（想开箱即用就在编辑器里拖一个 skill_fireball.tres 进来）。
@export var default_skills: Array[SkillData] = []
## 直接运行本场景（F6）时是否自动开一场演示战斗。
## 默认 true：方便在编辑器里反复调表现；等接入正式流程（从地图切场景进战斗）时应改成 false，
## 否则战斗会"自己先打起来"，和地图传进来的队伍打架。注释里说的"编辑器里设的队伍优先"= 见上面两组。
@export var auto_start_demo := true      # 直接运行本场景时自动开打（编辑器里设的队伍优先）
## 每个动作之间的停顿（秒）。作用：让攻击位移、飘字、受击闪红能被看清，不至于一帧打完。
## 取值范围经验上 0.1~0.8：太小（<0.1）演出糊成一团，太大（>0.8）一场战斗会非常拖沓。
## 只影响表现节奏，不影响任何数值结算（伤害在停顿之前就已经算完了）。
@export var action_delay := 0.35         # 每个动作之间的停顿（秒）
## 群体技能里"逐个目标结算"之间的间隔（秒），只在 _cast_aoe() 里用。
## 为什么比 action_delay 小得多：群体技能要的是"同时被炸到"的观感，
## 用 0.35 会变成"一个一个挨打"；0.06 左右飘字和闪红会连成一片，读起来才像 AOE。
## 单体技能和普攻完全不看这个值。
@export var aoe_step_delay := 0.06       # 群体技能里每个目标结算的间隔（秒）

# ── 视觉：飘字配色 ────────────────────────────────────────────────────────────
# 这里的颜色只用于 Battle.create_floating_text() 生成的 FloatingText 的 modulate，
# 与技能资源 SkillData.tint（飞行体/爆炸的染色）无关，两套配色互不影响。
# @export_group 只是把检查器里的字段分组，运行时没有任何作用。
@export_group("飘字颜色")
## 普通伤害数字颜色。默认 (0.98,0.98,0.99)：接近纯白但极轻微偏暖，避免纯白在亮背景上"发死"。
@export var normal_color := Color(0.98, 0.98, 0.99)
## 暴击伤害数字颜色。默认金黄 (1.0,0.80,0.35)：和普通伤害的白形成强对比，一眼能看出暴击。
@export var critical_color := Color(1.0, 0.80, 0.35)
## 格挡（"Blocked!"）与"防御"提示的颜色。默认偏橙红 (1.0,0.55,0.35)：表示"这一下被卸掉了、不疼"。
@export var block_color := Color(1.0, 0.55, 0.35)
## 治疗数字颜色。默认绿色 (0.40,0.90,0.55)。
## 目前流程里暂时用不到（治疗/增益技能还没实现，见 _on_skill_selected() 的 TODO），先备好，等加了直接用。
@export var heal_color := Color(0.40, 0.90, 0.55)

# ── 节点引用 ──────────────────────────────────────────────────────────────────
# @onready 的求值时机：在 _ready() 体执行之前一次性赋值。由此得到两条纪律：
#   · 不要在 _init() 或成员初始化表达式里访问这些变量（那时它们还是 null）；
#   · 节点被 free 之后这些变量会变成"已释放对象"，跨 await 使用前要 is_instance_valid()。
# 前缀的区别：
#   %Name → 走 unique_name_in_owner（场景里勾了"作为唯一名称访问"），节点挪位置/改名都不会失效；
#   $Path → 普通相对路径，节点一旦被改名或挪到别的父节点就取不到（会报 null 访问）。

## Stage/PlayerSlots：我方站位容器，子节点是一串 Marker2D。改站位只需挪 Marker2D，不用动代码。
@onready var player_slots: Node2D = %PlayerSlots
## Stage/EnemySlots：敌方站位容器，语义同上，子节点同样是 Marker2D。
@onready var enemy_slots: Node2D = %EnemySlots
## Stage/Units：所有 BattleUnit 的父节点。放在 2D 舞台层（而非 UI 的 CanvasLayer）里，
## 才能受 Camera2D 的抖动影响 —— 这也是 _shake_camera() 能让整个战场一起晃的前提。
@onready var units_root: Node2D = %Units
## Stage/Fx：一次性特效的父节点（飘字、技能飞行体）。
## 与 units_root 分开是为了保证绘制顺序：Fx 是 Stage 的最后一个子节点，永远盖在所有单位之上。
@onready var fx_root: Node2D = %Fx
## 舞台镜头（普通路径 $Camera2D，没设唯一名称，挪位置就会失效）。
## _shake_camera() 会临时改它的 position 再复原；注意它抖的是镜头，不是节点坐标。
@onready var camera: Camera2D = $Camera2D
## UI 层的出手顺序条（scenes/battle/turn_order.gd）。
## Battle 只调它的三个方法：update_order() / set_current() / clear_current()。
@onready var turn_order: TurnOrder = $UI/TurnOrder
## UI 层的指令菜单（scenes/battle/command_menu.gd）。
## _ready() 里连它的 command_selected / skill_selected 两个信号；这里绝不反向让它引用 Battle。
@onready var command_menu: CommandMenu = $UI/CommandMenu
## UI 层的提示文字（"第 N 回合""某某的回合""某某 → 某某"、伤害播报等）。
## 场景里这个节点其实勾了 unique_name_in_owner，所以写成 %InfoLabel 也等价；
## 这里用 $UI/InfoLabel 只是历史写法，两种都能取到同一个节点。
@onready var info_label: Label = $UI/InfoLabel

# ── 运行时状态（全部由流程函数维护，外部不要直接改）──────────────────────────

## 当前状态机状态，取值见上面的 enum State。几乎所有回调第一句都拿它做准入判断。
var state := State.IDLE
## 当前出手的单位。
## 注意它的生命周期：_finish_turn() 会把它清成 null，而 _begin_turn() 会把它设成下一个人，
## 所以「await 之后再读 actor」很可能已经不是原来那个人 —— _on_unit_clicked() 里就特意先
## 存了一份局部 caster，正是为了避开这个坑。
var actor: BattleUnit
## 本回合的出手队列：_next_round() 里筛出活人、按速度排好序后填进来，_begin_turn() 靠 turn_index 逐个取。
## 它只保存"排序那一刻还活着"的单位；中途死掉的会在 _begin_turn() 里被检测并跳过。
var turn_queue: Array[BattleUnit] = []
## turn_queue 的游标。每次 _finish_turn() 里 +1；超过队列长度说明本回合走完，切 _next_round()。
var turn_index := 0
## 回合计数，从 1 开始（start_battle() 里置 1，_next_round() 拿它显示"第 N 回合"之后自增）。
var round_count := 0

# 双方成员列表。注意语义：保存的是"本场生成过的全部单位"，包含已经阵亡的
# （阵亡只是 alive=false + 淡出 + 关掉点选，节点并没有被 free），
# 所以任何需要"活人"的地方都必须过一遍 _alive() 过滤，不要直接用这两个数组。
# 存节点引用而不是索引，是为了配合 is_instance_valid() 安全处理"节点已被外部释放"的情况。
var _players: Array[BattleUnit] = []
var _enemies: Array[BattleUnit] = []
## 当前正在高亮、等待玩家点选的候选目标。
## 由 _begin_target_select() 填充（只会填敌人），由 _highlight_targets() 清空。
## _on_unit_clicked() 用 `_targets.has(unit)` 来判断"玩家点的这个是不是合法目标"。
var _targets: Array[BattleUnit] = []
## 键盘目标光标的当前位置（_targets 的下标）。鼠标点击/悬停也会同步它，两套操作共用同一个"当前目标"。
var _target_index := 0
var _pending_skill: SkillData = null      # 已经选了技能、正在等玩家点目标


# ── 生命周期 ──────────────────────────────────────────────────────────────────

## 生命周期入口：节点进树后由引擎自动调用一次（早于第一帧 _process）。
## 参数：无。返回值：无。
## 副作用（三件）：
##   1) 打开本 Viewport 的物理点选 —— 这是全局开关，影响整个视口；
##   2) connect command_menu 的 command_selected / skill_selected 两个信号到本类的回调；
##   3) auto_start_demo 为 true 时调用 start_battle() 起一场演示战斗。
## 注意事项：
##   · start_battle() 内部有 await，所以 _ready() 不会等战斗跑完就返回了 —— 这是刻意的：
##     场景初始化不能被战斗流程拖住。反过来说，_ready() 返回时战斗其实还在"战斗开始"的停顿里。
##   · 这里不调 super._ready()：Battle 的父类是引擎内建的 Node2D，没有需要转发的自定义初始化。
##     （但如果是继承本类的子类，就**必须**调 super._ready()，否则这一段初始化会被整个吃掉。）
func _ready() -> void:
	# Area2D 的 input_event / mouse_entered 需要开启物理点选（也可以去项目设置里开）
	# 不开的话 BattleUnit 的 %ClickArea 收不到 input_event，"点敌人选目标"会彻底失灵。
	# 本场景既没有物理体也不做碰撞，开它纯粹是为了 Area2D 的鼠标拾取。
	get_viewport().physics_object_picking = true
	# 菜单只负责"显示 + 发信号"，具体做什么由 Battle 决定；用 connect 保持单向依赖（菜单不引用 Battle）。
	command_menu.command_selected.connect(_on_command_selected)
	command_menu.skill_selected.connect(_on_skill_selected)

	if auto_start_demo:
		# 三元表达式两侧返回的都是 Array[UnitStats]（_load_demo 有显式返回类型标注），
		# 所以 := 能正确推断出类型；如果写成 Array[...]() 之类的形式反而会解析报错。
		# 优先级：检查器里配置的队伍 > DEMO_* 示例路径。
		var players := player_team if not player_team.is_empty() else _load_demo(DEMO_PLAYERS)
		var enemies := enemy_team if not enemy_team.is_empty() else _load_demo(DEMO_ENEMIES)
		start_battle(players, enemies)


## 把一组资源路径解析成 UnitStats 数组（只服务于"直接运行场景"的演示流程）。
## 参数 paths：形如 "res://resources/units/.../xxx.tres" 的路径数组（类型是弱类型 Array，
##             因为 const 数组推不出 Array[String] 之类的具体类型）。
## 返回值：成功解析出来的 UnitStats 列表（可能比 paths 短 —— 失败的会被跳过，不会中断）。
## 副作用：失败的路径会 push_warning（只进编辑器/控制台的警告，不影响运行）。
## 坑：用 load() 而不是 preload()，所以路径写错只会在运行时报 warning，编辑器静态检查发现不了。
func _load_demo(paths: Array) -> Array[UnitStats]:
	var out: Array[UnitStats] = []
	for path in paths:
		# load() 返回 Resource（找不到时返回 null）；这里用 is 做运行时类型校验。
		var res := load(path)
		if res is UnitStats:
			out.append(res)
		else:
			push_warning("Battle: 载入失败或类型不对 -> %s" % path)
	return out


# ══════════════════════════════════════════════════════════
#  开战
# ══════════════════════════════════════════════════════════

## 开战：清场 → 生成双方单位 → 播开场停顿 → 进入第一回合。
## 参数 players / enemies：双方队伍数据（UnitStats 资源）。允许传空数组，但要"两边都非空"才打得起来。
## 返回值：无（本函数是协程，会 await 0.6 秒开场停顿；调用方不 await 也能正常工作）。
## 副作用（很重，务必了解）：
##   · 会 queue_free() 掉场上所有旧 BattleUnit（经由 _clear_units()）—— 重复调用等于重开一场；
##   · 会关掉指令菜单、清空出手顺序条 UI；
##   · 会创建新的 BattleUnit 节点挂到 %Units 下，并把它们的 clicked/died 信号连到本类；
##   · 会改写 state / round_count / _players / _enemies / turn_queue（通过 _spawn_team 与 _next_round）；
##   · 队伍有一方为空时：push_warning + state 回到 IDLE 并直接 return，**不会**发 battle_ended
##     （所以外部接不到"开战失败"的通知，只能靠这里的警告排查）。
## 时机：await 之后的 _next_round() 有可能在"场景已经被切走"后才回来执行 ——
##       目前依赖调用方保证本节点还活着，没做 is_inside_tree() 之类的兜底。
func start_battle(players: Array[UnitStats], enemies: Array[UnitStats]) -> void:
	# 先清干净上一场的残留（重开战斗、或从编辑器里连点两次都会走到这里）。
	_clear_units()
	command_menu.close()
	turn_order.update_order([])
	state = State.INTRO
	round_count = 1

	# 参数名与成员变量同名（players/enemies vs _players/_enemies），靠下划线区分，别弄混。
	_players = _spawn_team(players, player_slots, true)
	_enemies = _spawn_team(enemies, enemy_slots, false)

	if _players.is_empty() or _enemies.is_empty():
		# 有一方没人（空数组、全是 null、或者站位 Marker2D 一个都没有）→ 放弃开战。
		push_warning("Battle: 有一方队伍是空的，检查 player_team / enemy_team 或传进来的参数")
		state = State.IDLE
		return

	info_label.text = "战斗开始"
	turn_order.update_order(_alive(_all_units()))
	# 开场停顿：让玩家看清战场布置再开始。create_timer 的计时器由 SceneTree 持有，
	# 这里只等它的 timeout 信号，计时器自己会被回收，不用手动 free。
	await get_tree().create_timer(0.6).timeout
	_next_round()


## 按站位把一队 UnitStats 实例化成 BattleUnit 节点。
## 参数 stats_list：队伍数据；slots_root：站位容器（Stage/PlayerSlots 或 Stage/EnemySlots，
##                  其子节点必须都是 Node2D/Marker2D）；is_player：这一队是不是我方。
## 返回值：成功生成的 BattleUnit 数组（顺序与 stats_list 的前 N 个一一对应）。
## 副作用：
##   · 每个单位都会 add_child 到 %Units（所以下面这些单位节点的 owner 是 null）；
##   · 连接每个单位的 clicked → _on_unit_clicked、died → _on_unit_died；
##   · 队伍人数多于站位数量时 push_warning（多出来的人直接不生成，不会报错）。
## 关键顺序（改代码时千万别调换）：
##   必须 add_child() 之后才能 setup()：setup() 里会摸 sprite / 血条 / 名字这些 @onready 变量，
##   而 @onready 只在节点进树那一刻被赋值 —— 反过来写会直接 null 访问崩溃。
func _spawn_team(stats_list: Array[UnitStats], slots_root: Node2D, is_player: bool) -> Array[BattleUnit]:
	var result: Array[BattleUnit] = []
	var slots := slots_root.get_children()
	# mini() = 取两个 int 中较小的那个。人数和站位数谁少听谁的，避免越界访问 slots[i]。
	var count: int = mini(stats_list.size(), slots.size())
	if stats_list.size() > slots.size():
		push_warning("Battle: %s 的站位不够（%d 个队伍 / %d 个 Marker2D）" % [slots_root.name, stats_list.size(), slots.size()])

	for i in count:
		# 队伍数组里允许留空位（null），这样"3 人队"也能站在第 1/3/4 号位。
		if stats_list[i] == null:
			continue
		var unit := BATTLE_UNIT_SCENE.instantiate() as BattleUnit
		units_root.add_child(unit)
		unit.setup(stats_list[i], is_player)          # 必须在 add_child 之后
		# 技能表由 Battle 注入（BattleUnit 自己不认识 Battle.default_skills 的存在）。
		unit.available_skills = _skills_for(unit, is_player)
		# 用 global_position 赋值而不是 position：站位 Marker2D 的坐标是相对 Stage 的，
		# 而单位挂在 Stage/Units 下，两边父节点不同，只有世界坐标才对得上。
		unit.global_position = (slots[i] as Node2D).global_position
		unit.clicked.connect(_on_unit_clicked)
		# 悬停用来同步键盘光标（选目标时鼠标指谁，箭头就跟着到谁）
		unit.hovered.connect(_on_unit_hovered)
		unit.died.connect(_on_unit_died)
		result.append(unit)
	return result


## 清空场上所有战斗单位，并把双方列表、目标列表、当前出手者、待选技能全部复位。
## 参数/返回值：无。
## 副作用：
##   · 对每个单位调 queue_free()（**延迟**到本帧末释放，所以函数返回后这些节点仍然短暂存在，
##     只是被标记了待释放 —— 这正是下面能安全 clear 数组的原因）；
##   · 会清空 _players / _enemies / _targets 并把 actor、_pending_skill 置 null。
## 坑：这里用 unit.queue_free() 而不是 owner.queue_free()。运行时 add_child 进来的节点 owner 是 null，
##     用 owner 会直接失败（而 %Units 的子节点在场景文件里没有存进 owner，所以也不该用 owner）。
func _clear_units() -> void:
	for unit in _all_units():
		# 防御性检查：节点可能已经被别处释放（例如场景切换时父节点先没了）。
		if is_instance_valid(unit):
			unit.queue_free()
	_players.clear()
	_enemies.clear()
	_targets.clear()
	actor = null
	_pending_skill = null


# ══════════════════════════════════════════════════════════
#  回合流程
# ══════════════════════════════════════════════════════════

## 开一个新回合：判胜负 → 刷新冷却 → 按速度重排出手顺序 → 更新 UI → 进第一个人的回合。
## 参数/返回值：无（协程，末尾 await 0.3 秒让玩家看清"第 N 回合"）。
## 副作用：
##   · 会改写 turn_queue / turn_index / round_count / info_label.text；
##   · 会对全体存活单位调 tick_cooldowns()（这是**每回合一次**的技能冷却递减，见 BattleUnit）；
##   · 会调 turn_order.update_order() 刷新左侧顺序条；随后进 _begin_turn()。
## 坑：本函数只在"上一个回合的 _begin_turn() 发现队列走完"或"start_battle 开场"时被调用，
##     没有重入保护；如果外部乱调导致两个 _next_round 叠在一起，回合会双倍推进。
func _next_round() -> void:
	if _check_battle_end():
		return
	# 只把"这一刻还活着"的单位放进出手队列（阵亡的从本回合起就不再行动）。
	turn_queue = _alive(_all_units())
	# 每回合开始时：刷冷却 + roll 本回合的出手速度（**必须先 roll 再排序**）。
	for unit in turn_queue:
		unit.tick_cooldowns()                        # 每回合开始时刷新技能冷却
		unit.roll_turn_speed()                       # 乱敏：±4 随机扰动，每单位每回合只 roll 一次
	# sort_custom 的比较函数是"a 是否应排在 b 前面"：速度大的排前面（降序 = 先手）。
	# ⚠ 比较函数里**不能**再调 turn_speed()：那样每次比较都取新随机数，比较结果自相矛盾，
	#   引擎会报 "bad comparison function; sorting will be broken" 且排序结果未定义。
	#   现在的写法读的是上面缓存的 round_speed，所以是严格全序，"乱敏"的手感保持不变。
	turn_queue.sort_custom(func(a: BattleUnit, b: BattleUnit) -> bool:
		return a.round_speed > b.round_speed)
	turn_index = 0
	turn_order.update_order(turn_queue)
	info_label.text = "第 %d 回合" % round_count
	round_count += 1
	await get_tree().create_timer(0.3).timeout
	_begin_turn()


## 进入 turn_queue[turn_index] 这个单位的回合；如果是敌方则顺带把它的行动也跑完。
## 参数/返回值：无（协程）。这是整个流程的核心分发点，绝大部分时间都停在这里等待玩家输入。
## 副作用：
##   · 改写 actor / state / turn_index / info_label.text；
##   · 会 emit turn_started（此时 state=TURN_START）；我方回合还会 emit command_requested；
##   · 会打开指令菜单（我方）或执行敌方 AI（_enemy_act）；
##   · 队列走完时会把控制权交给 _next_round()，形成回合循环。
## 递归说明：跳过阵亡/空位时用 `turn_index += 1` 后直接自调用 _begin_turn()。
##   因为 GDScript 不保证尾调用优化，理论上"一整队全死光"时会压出同样层数的调用栈；
##   队伍规模只有个位数，所以这里选择可读性而不是改成 while 循环。
func _begin_turn() -> void:
	if _check_battle_end():
		return

	# 队列走完 = 本回合结束，小停顿一下再开新回合（停顿是为了让"回合切换"看得出来）。
	if turn_index >= turn_queue.size():
		await get_tree().create_timer(0.25).timeout
		_next_round()
		return

	actor = turn_queue[turn_index]
	# 排序之后才死的单位（本回合内被打死）会被这里跳过；actor 也可能是已释放对象，所以先判 null。
	if actor == null or not actor.alive:
		turn_index += 1
		_begin_turn()
		return

	# 点亮"行动者轮廓"：我方青色 / 敌方橙红（颜色见 BattleUnit.OUTLINE_* 常量）。
	# 放在这里而不是 start_battle 里，是因为每个单位轮到时都要点亮一次。
	actor.set_selected(true)
	state = State.TURN_START
	turn_order.set_current(actor)
	turn_started.emit(actor)
	info_label.text = "%s 的回合" % actor.stats.name
	await get_tree().create_timer(0.15).timeout

	if actor.is_player:
		# 我方：开菜单 + 发信号，然后**什么都不做**，静静等玩家点按钮
		# （由 CommandMenu.command_selected → _on_command_selected 接手流程）。
		state = State.COMMAND
		command_menu.open_for(actor)
		command_requested.emit(actor)
	else:
		# 敌方：多等 0.4 秒做"思考感"，再 await AI 行动；
		# await 是为了确保 AI 的整段演出（含伤害结算）跑完才继续，否则会立刻进下一个人。
		await get_tree().create_timer(0.4).timeout
		await _enemy_act()


## 收尾一个单位的回合：清状态 → 游标 +1 → 立刻进下一个人的回合。
## 参数/返回值：无（**注意这不是协程**，它同步调用 _begin_turn()，而后者内部的 await 会让
##             调用栈在"下一个回合等待期间"挂起，所以调用方不需要 await 本函数）。
## 副作用：
##   · state 置 TURN_END；actor、_pending_skill 清空（这就是"await 后 actor 可能已经不是原来那个"的根源）；
##   · turn_index += 1（唯一的推进点，任何地方漏调都会导致战斗卡死）；
##   · 间接触发 _begin_turn()，进而可能开菜单 / 跑 AI / 开新回合。
func _finish_turn() -> void:
	state = State.TURN_END
	# 熄灭刚行动完那个人的轮廓（要在 actor 置 null 之前做，不然就找不到它了）
	if actor != null and is_instance_valid(actor):
		actor.set_selected(false)
	actor = null
	_pending_skill = null
	turn_index += 1
	_begin_turn()


## 敌方 AI：从存活的我方单位里随机挑一个，走一次普通攻击。
## 参数/返回值：无（协程，内部 await 完整场攻击演出）。
## 副作用：会调 _perform_attack()，后者负责位移、伤害、飘字、镜头与回合收尾。
## 说明：
##   · 这里没有"技能 AI"——敌人只有普攻；也没做残血优先、集火等策略。
##   · randi() % size 是经典的取随机下标写法（randi() 可能为负？不会，randi() 返回 0..2^32-1）。
##   · 目标列表为空说明我方已经全灭，此时只做一次胜负判定就返回，**不**调 _finish_turn()：
##     因为 _check_battle_end() 会在判定出结果时把 state 置 FINISHED 并停掉整个流程。
func _enemy_act() -> void:
	var targets := _alive(_players)
	if targets.is_empty():
		_check_battle_end()
		return
	# TODO: 更聪明的 AI（优先残血、优先给己方加血/护盾）在这里替换
	await _perform_attack(actor, targets[randi() % targets.size()])


# ══════════════════════════════════════════════════════════
#  指令 → 目标 → 结算
# ══════════════════════════════════════════════════════════

## 指令菜单回调：玩家点了主菜单的某个按钮（信号 CommandMenu.command_selected）。
## 参数 command：指令标识（StringName 字面量，用 &"xxx" 比较，比字符串更省一次哈希）。
##               当前取值：&"attack" / &"defend" / &"flee" / &"skill" / &"item"。
## 返回值：无（协程 —— &"defend" 分支里有 await 停顿）。
## 副作用：按分支走 —— 可能关菜单、可能改 actor 的防御状态、可能直接结束战斗、可能进目标选择。
##         任何"彻底结束本回合"的分支都必须走到 _finish_turn()，否则战斗不会继续。
## 准入判断：`state != State.COMMAND` 时直接丢弃。这一句很关键 ——
##   await 期间玩家可能连点、或者菜单被重新打开，靠它把过期输入挡掉。
func _on_command_selected(command: StringName) -> void:
	if state != State.COMMAND or actor == null:
		return
	command_menu.close()

	match command:
		&"attack":
			# 普攻：不在这里结算，先切到"选目标"阶段（_on_unit_clicked 才真正出手）。
			# _pending_skill 保持为 null 就是"这次是普攻"的标记。
			_begin_target_select()

		&"defend":
			# 防御：立刻生效（不需要选目标），减伤效果在 BattleUnit.take_damage() 里
			# 表现为伤害 ×0.5（且有 1 点下限），身上会染一层淡蓝。
			actor.set_defending(true)
			create_floating_text(actor, "防御", block_color)
			info_label.text = "%s 进入防御" % actor.stats.name
			# await 之后 actor 理论上可能已被清空，所以这里在 await 之前就把该做的都做完了。
			await get_tree().create_timer(action_delay).timeout
			_finish_turn()

		&"flee":
			# TODO: 做成有成功率的逃跑（速度/等级差决定概率）
			# 现在是无条件逃跑：直接判负结束战斗（player_won = false）。
			_finish_battle(false, "撤退")

		&"skill":
			# 法术走 CommandMenu 的二级菜单（列表 → skill_selected），不会进到这里
			pass

		&"item":
			# TODO: 道具系统（二级菜单 → 选目标 → 使用）
			# 注意这里是"重新打开菜单"，而不是 _finish_turn()：玩家还能改选别的指令。
			# 前提是 state 仍为 COMMAND（没被改成别的状态），否则菜单开了也收不到有效回调。
			info_label.text = "道具系统还没做"
			command_menu.open_for(actor)

		_:
			# 兜底：收到未知指令就当成"放弃本次行动"处理，避免战斗卡住。
			_finish_turn()


## CommandMenu 里点了某个技能
## 参数 skill：玩家点的技能资源。
## 返回值：无（协程 —— 全体技能分支会 await 完整段施法演出）。
## 副作用：
##   · 蓝不够 / 冷却中 → 只改 info_label 并 return，**菜单保持关闭**（玩家需要重新点一次法术，
##     这是一个已知的体验小瑕疵）；
##   · 全体敌方技能（ENEMY_ALL）→ 直接对全部存活敌人施放；
##   · 单体技能（ENEMY_SINGLE / 默认分支）→ 写入 _pending_skill 并进目标选择阶段；
##   · SELF / ALLY_SINGLE → 未实现，只提示并重新打开菜单（不会消耗回合）。
## 准入判断同上：state 必须是 COMMAND，且技能要 can_use_skill（蓝够 + 冷却归零 + 自己活着）。
func _on_skill_selected(skill: SkillData) -> void:
	if state != State.COMMAND or actor == null or skill == null:
		return
	if not actor.can_use_skill(skill):
		info_label.text = "%s 现在用不了（蓝不够或冷却中）" % skill.display_name
		return
	command_menu.close()

	match skill.target_mode:
		SkillData.TargetMode.ENEMY_ALL:
			# 群体技能不需要选目标，直接把"当前还活着的敌人"整组交出去。
			# 这里显式把 _pending_skill 置 null，保证"群体施法"不会被误当成"单体待选"。
			_pending_skill = null
			await _perform_skill(actor, skill, _alive(_enemies))
		SkillData.TargetMode.SELF, SkillData.TargetMode.ALLY_SINGLE:
			# TODO: 治疗/增益效果（等 BattleUnit 加了 status 系统再做）
			info_label.text = "%s 的效果还没实现（先把单体伤害做好了）" % skill.display_name
			command_menu.open_for(actor)
		_:
			# 剩下的就是 ENEMY_SINGLE（以及未来新增、需要选目标的模式）：
			# 把技能暂存到 _pending_skill，等玩家在战场上点一个敌人再真正执行。
			_pending_skill = skill
			_begin_target_select(skill)


## 进入"选目标"阶段：把所有存活敌人标成可点选，并改提示文字。
## 参数 skill：本次要施放的技能；为 null 表示这是普通攻击（默认值就是 null，
##             所以 _on_command_selected 里可以直接写 _begin_target_select()）。
## 返回值：无（同步函数，不 await）。
## 副作用：
##   · _targets 被覆盖为"当前存活的敌人"；state 置 TARGET_SELECT；info_label.text 被改写；
##   · 会对每个候选目标调 set_targetable(true)，让它们显示红色高亮圈。
## 特例：如果敌人已经全灭（例如群体技能刚把最后一人打死），这里只做一次胜负判定并返回 ——
##       此时 state 仍停在 COMMAND，但紧接着的战斗结束流程会把它改成 FINISHED，不会卡住。
func _begin_target_select(skill: SkillData = null) -> void:
	_targets = _alive(_enemies)
	if _targets.is_empty():
		_check_battle_end()
		return
	state = State.TARGET_SELECT
	# 键盘光标默认停在第一个敌人上；鼠标点/悬停会同步它（见 _on_unit_clicked / _on_unit_hovered）
	_target_index = 0
	if skill != null:
		info_label.text = "选择「%s」的目标（↑↓←→ 切换 · Enter/空格 确认 · 右键/ESC 取消）" % skill.display_name
	else:
		info_label.text = "选择攻击目标（↑↓←→ 切换 · Enter/空格 确认 · 右键/ESC 取消）"
	for target in _targets:
		target.set_targetable(true)
	_refresh_target_focus()


## 统一关掉目标高亮并清空候选列表。
## 参数 value：要高亮还是取消（目前所有调用处传的都是 false；参数留着是为了将来支持"只刷新高亮"）。
## 返回值：无。
## 副作用：遍历 _targets 调 set_targetable(value)，然后 **_targets.clear()**。
## 坑：不管传什么值它都会清空 _targets —— 所以这个函数不能被用来"重新高亮同样一批目标"，
##     它是一次性的收尾动作（取消高亮 → 列表作废）。
##     is_instance_valid 检查是必要的：目标可能在这几帧内已经阵亡/被释放。
func _highlight_targets(value: bool) -> void:
	for target in _targets:
		if is_instance_valid(target):
			target.set_targetable(value)
			# 顺手收掉键盘光标的外观（轮廓 + 箭头）：否则取消选目标后还会有一个单位顶着箭头
			target.set_focused(false)
	_targets.clear()
	_target_index = 0


# ══════════════════════════════════════════════════════════
#  键盘选目标（与鼠标并存，共用同一个"当前目标"）
# ══════════════════════════════════════════════════════════

## 只把"轮廓 + 头顶箭头"给键盘光标停的那一个，其余候选保持普通的红色高亮框。
## 参数/返回值：无。副作用：对 _targets 里每个单位调 set_focused(i == _target_index)。
## 为什么要区分两种高亮：候选可能有 4 个，全加轮廓+箭头就分不清"这一下到底打谁"。
func _refresh_target_focus() -> void:
	for i in _targets.size():
		if is_instance_valid(_targets[i]):
			_targets[i].set_focused(i == _target_index)


## 移动键盘光标（首尾循环）并刷新高亮。
## 参数 step：-1 = 上一个 / +1 = 下一个。
## 返回值：无。副作用：改 _target_index、刷新高亮、播一次 UI 音效。
## 只有一个目标时直接返回（避免原地"空转"的提示音）。
func _move_target_cursor(step: int) -> void:
	if _targets.size() <= 1:
		return
	_target_index = wrapi(_target_index + step, 0, _targets.size())
	_refresh_target_focus()
	SoundManager.play_sound(SoundManager.Sound.UI)


## 用键盘确认当前光标选中的目标（完全等价于鼠标点它）。
## 参数/返回值：无（内部复用 _on_unit_clicked 那条已有路径：清高亮 → 取 _pending_skill → 执行）。
## 副作用：与鼠标点击完全一致。
func _confirm_focused_target() -> void:
	if _target_index < 0 or _target_index >= _targets.size():
		return
	var target := _targets[_target_index]
	if target != null and is_instance_valid(target):
		_on_unit_clicked(target)


## 鼠标悬停到某个候选敌人时，把键盘光标也挪过去。
## 参数 unit：被悬停的单位；entered：true = 进入（false = 离开，不处理）。
## 返回值：无。副作用：改 _target_index 并刷新高亮。
## 为什么要有它：两套操作共享同一个"当前目标"，视觉上才不会出现"鼠标指着一个、箭头指着另一个"的割裂感。
func _on_unit_hovered(unit: BattleUnit, entered: bool) -> void:
	if not entered or state != State.TARGET_SELECT:
		return
	var index := _targets.find(unit)
	if index < 0 or index == _target_index:
		return
	_target_index = index
	_refresh_target_focus()


## 玩家点了某个战斗单位（信号 BattleUnit.clicked —— 注意敌我双方的单位都连到这里）。
## 参数 unit：被点到的单位。
## 返回值：无（协程 —— 命中目标时会 await 整段攻击/施法的演出与结算）。
## 副作用（两条分支完全不同）：
##   · 处于 TARGET_SELECT 且点的是合法目标 → 关高亮、清 _pending_skill，然后走
##     _perform_skill（有技能）或 _perform_attack（普攻），最终由它们收尾回合；
##   · 其他情况 → 只把该单位的 HP/MP 写进 info_label，算是一个简易"查看"功能，不改任何状态。
## 关键点/坑：
##   · 这里先把 actor 和 _pending_skill 各存了一份局部变量（caster / skill），
##     因为 _perform_* 内部或玩家后续操作会把成员变量清掉；用局部变量能保证"发起这次攻击的人"
##     就是当初选指令的那个人，不会串到下一个回合的单位身上。
##   · `_targets.has(unit)` 是唯一的目标合法性校验：非候选目标（比如自己人、或已经取消高亮的）
##     点了也只会走 else 分支显示信息。这同时也兜住了"敌方单位被点击"的情况 ——
##     敌方不是玩家，但敌方单位的 clicked 信号同样连着这里，靠 state 判断挡住。
##   · var one: Array[BattleUnit] = [unit]：_perform_skill 要求 Array[BattleUnit]，
##     不能直接把 unit 传进去（类型不匹配），所以包一层单元素数组。类型标注不能省。
func _on_unit_clicked(unit: BattleUnit) -> void:
	if state == State.TARGET_SELECT and _targets.has(unit) and actor != null:
		var caster := actor
		var skill := _pending_skill
		_pending_skill = null
		_highlight_targets(false)
		if skill != null:
			var one: Array[BattleUnit] = [unit]
			await _perform_skill(caster, skill, one)
		else:
			await _perform_attack(caster, unit)
	else:
		# 非选目标阶段点单位：以后可以在这里弹"查看单位信息"面板
		info_label.text = "%s  HP %.0f/%.0f   MP %.0f/%.0f" % [unit.stats.name, unit.hp, unit.max_hp, unit.mp, unit.max_mp]


## 执行一次普通攻击并完成本回合收尾。
## 参数 attacker：出手方；target：被打方。
## 返回值：无（协程，依次 await 位移演出、受击闪烁、动作间隔）。
## 副作用：
##   · state 置 EXECUTE；info_label.text 被改写；
##   · 可能通过 target.take_damage() 把目标打死（进而触发 BattleUnit.died → _on_unit_died → 刷新顺序条）；
##   · 会创建飘字（FloatingText，自毁）—— 挂在 %Fx 下；
##   · 末尾要么调 _finish_turn() 交棒，要么由 _check_battle_end() 把战斗判死。
## 数值口径（想改公式只动这几行）：
##   · 先判格挡 try_block()（命中就完全免伤，只飘 "Blocked!"）；
##   · 否则伤害 = attacker.roll_damage()，暴击再 ×1.5 并向上取整（ceilf）；
##   · 防御中的减伤不在这里做，而是在 BattleUnit.take_damage() 内部 ×0.5（职责分离）。
## 顺序讲究：create_floating_text 在 take_damage 之后调用，因为飘字位置读取的是
##   目标当前坐标；而 play_hit() 放在最后 await，是为了让闪红和飘字同时被看见。
func _perform_attack(attacker: BattleUnit, target: BattleUnit) -> void:
	# 三重校验：两个节点都还得有效、目标还得活着。
	# 命中任一条件就直接收尾（这里必须 _finish_turn()，否则当前单位的回合永远结束不了）。
	if not is_instance_valid(attacker) or not is_instance_valid(target) or not target.alive:
		_finish_turn()
		return

	state = State.EXECUTE
	info_label.text = "%s → %s" % [attacker.stats.name, target.stats.name]
	# 位移演出：冲过去再退回来。await 到 tween.finished 才继续，保证"先冲再打"。
	await attacker.play_attack(target)

	if target.try_block():
		create_floating_text(target, "Blocked!", block_color)
	else:
		var damage := attacker.roll_damage()
		var is_crit := attacker.roll_crit()
		if is_crit:
			damage = ceilf(damage * 1.5)
		target.take_damage(damage)
		# str(int(damage))：飘字只显示整数部分（伤害是 float），避免出现 "12.000000"。
		# 三目运算符决定颜色：暴击用金黄，普通用近白。
		create_floating_text(target, str(int(damage)), critical_color if is_crit else normal_color)
		await target.play_hit()

	# 统一节奏停顿。注意这一句在两者之外 —— 无论格挡还是命中都要等，
	# 这样"打空了"和"打中了"的节奏一致，观感不会忽快忽慢。
	await get_tree().create_timer(action_delay).timeout
	# 先判胜负：如果这一下把某方打光了，_check_battle_end() 内部已经处理完收尾（state=FINISHED），
	# 此时**不能**再调 _finish_turn()，否则会把已经结束的战斗继续往下推，出现"死人之后还能打"的怪象。
	if not _check_battle_end():
		_finish_turn()


# ══════════════════════════════════════════════════════════
#  技能
# ══════════════════════════════════════════════════════════

## 单位本场能用的技能：优先用 UnitStats.skills，否则我方用 default_skills
## 参数 unit：刚生成、setup() 完的 BattleUnit（这里读它的 stats）；is_player：是否我方。
## 返回值：技能数组。注意**返回的是 UnitStats.skills 里那个数组对象本身，不是拷贝** ——
##         Battle 拿到后只是读，不会就地改；一旦将来有人往返回值里 append，
##         就会污染共享的 UnitStats 资源，所有引用它的单位都会"多出技能"。
## 副作用：无（纯查询）。
## 判断顺序的意义：单位自己配了技能就完全覆盖默认表（不会"默认 + 自有"叠加），
##                 这样想给某个角色临时禁用法术时，只要给他配一个空表以外的技能即可。
func _skills_for(unit: BattleUnit, is_player: bool) -> Array[SkillData]:
	if unit.stats != null and not unit.stats.skills.is_empty():
		return unit.stats.skills
	if is_player:
		return default_skills
	return []


## 火球术这类单体/群体伤害技能的执行流程：起手 → 飞行 → 命中结算 → 收尾
## 参数 caster：施法者；skill：技能资源；targets：**候选**目标列表（单体传单元素数组，群体传全敌）。
## 返回值：无（协程，整段约 0.3s×目标数 + 飞行时间）。
## 副作用：
##   · state 置 EXECUTE；info_label.text 改写；
##   · caster.spend_mana()（扣蓝）与 caster.start_cooldown()（进冷却）—— 都在起手阶段一次扣完，
##     不会因为目标死了就"退钱"；
##   · 每个目标生成一个 SkillProjectile 挂在 %Fx 下（它命中爆炸后自己 queue_free）；
##   · 会创建飘字、播 cast_sfx / hit_sfx、按 skill.screen_shake 抖镜头；
##   · 末尾交棒给 _finish_turn()，或由 _check_battle_end() 结束战斗。
## 顺序讲究：
##   1) 先扣蓝进冷却再播演出：演出中途如果玩家读 UI（技能菜单的蓝量/冷却显示），数据必须已经是新的；
##   2) 单体技能（ENEMY_SINGLE）逐个目标串行处理（for + await）；
##      群体技能（ENEMY_ALL）不在这里循环 —— 它走 _cast_aoe()：只生成一颗飞行体飞到敌阵中心炸开，
##      再按 aoe_step_delay 逐个结算（观感是"同时被炸到"）；
##   3) fly_to() 返回的那一刻才结算伤害（飞体自己负责飞行动画）；
##   4) projectile.burst() 放在伤害结算之后，画面上是"先飘字再爆炸"，看起来才不脱节。
## 坑：
##   · victims 是进入循环前算好的快照，循环里每个目标都重新判 alive，
##     所以"前一个目标被同伴误伤打死"这种极端情况不会重复结算；
##   · 施法者自己可能在这段 await 里被打死（反击/毒等机制以后加），当前没做中途打断。
func _perform_skill(caster: BattleUnit, skill: SkillData, targets: Array[BattleUnit]) -> void:
	if not is_instance_valid(caster) or skill == null:
		_finish_turn()
		return
	# 只对"这一刻还活着"的目标施法；群体技能传进来的可能包含死人，这里一并滤掉。
	var victims := _alive(targets)
	if victims.is_empty():
		# 没有有效目标：先判胜负（可能敌人刚好已经全灭），没结束就正常收尾回合。
		if not _check_battle_end():
			_finish_turn()
		return

	state = State.EXECUTE
	info_label.text = "%s 施放「%s」" % [caster.stats.name, skill.display_name]
	caster.spend_mana(skill.mana_cost)
	caster.start_cooldown(skill)
	_play_sfx(skill.cast_sfx)
	await caster.play_cast()

	# 群体技能走另一条演出路径：一颗火球 → 敌阵中心 → 中心大爆炸 + 全体结算。
	# victims 是上面算好的存活快照，这里不再重新取一次 _alive(_enemies)。
	if skill.target_mode == SkillData.TargetMode.ENEMY_ALL:
		await _cast_aoe(caster, skill, victims)
		if not _check_battle_end():
			_finish_turn()
		return

	for target in victims:
		# 逐目标重判：串行演出期间目标可能已经死了/节点被释放，跳过即可（不要 break，
		# 因为后面的目标仍然应该被打到）。
		if not is_instance_valid(target) or not target.alive:
			continue

		var projectile: SkillProjectile = SKILL_PROJECTILE_SCENE.instantiate() as SkillProjectile
		fx_root.add_child(projectile)
		# setup 接收"起点"，用 caster.global_position 而不是局部坐标 —— 双方可能挂在不同的父节点下。
		projectile.setup(skill, caster.global_position)
		# await 到飞体抵达目标坐标那一刻，再开始结算伤害。
		await projectile.fly_to(target.global_position)

		if target.try_block():
			create_floating_text(target, "Blocked!", block_color)
		else:
			# 技能伤害口径与普攻不同：走 caster.skill_damage()（power × stats.damage），
			# 暴击率也走 skill_crit()（基础 10% + skill.crit_bonus），同样 ×1.5 上取整。
			var damage := caster.skill_damage(skill)
			var is_crit := caster.skill_crit(skill)
			if is_crit:
				damage = ceilf(damage * 1.5)
			target.take_damage(damage)
			# 技能飘字的普通色用 skill.tint（火球就是橙色），而不是 Battle.normal_color ——
			# 这样"火系伤害"自带属性色，是刻意的表现差异。
			create_floating_text(target, str(int(damage)), critical_color if is_crit else skill.tint)
			await target.play_hit()

		# burst() 内部会 queue_free 掉飞体本身，所以后面不能再碰 projectile。
		projectile.burst()
		_play_sfx(skill.hit_sfx)
		# screen_shake 为 0 表示这个技能不抖镜头（避免小技能把画面晃得难受）。
		if skill.screen_shake > 0.0:
			_shake_camera(skill.screen_shake)
		# 每个目标之间也留一个 action_delay，群体技能才不会"一口气全炸完"看不清。
		await get_tree().create_timer(action_delay).timeout

	# 与 _perform_attack 同理：先判胜负，没结束才收尾回合。
	if not _check_battle_end():
		_finish_turn()


## 群体技能（target_mode = ENEMY_ALL）的演出与结算。
## 参数 caster：施法者；skill：技能资源；victims：**已过滤存活**的敌人列表（由 _perform_skill 传入）。
## 返回值：无（协程：飞行 → 中心爆炸 → 逐个结算 → 收尾停顿）。
## 副作用：和单体技能一样会飘字、播受击表现 —— 但有三处刻意不同：
##   · 蓝与冷却不在这里扣（_perform_skill 的起手阶段已经扣完了）；
##   · hit_sfx 与 _shake_camera 只做一次：四个目标各来一次的话会叠四层音效、抖四下；
##   · 会额外在 fx_root 下为每个敌人生成一朵小爆炸（各自播完自毁）。
## 与单体技能的三点关键差别（这个函数存在的理由）：
##   1) 只生成**一颗**飞行体，目标是"敌阵中心"（_group_center）而不是某个具体敌人 —— 视觉上才是炸一片；
##   2) 伤害仍然是逐个独立算的（各自判暴击/格挡），只是间隔极短（aoe_step_delay）；
##   3) 中心爆炸**先于**伤害结算，"先看到火炸开、再看到每个人掉血"，读起来更清楚。
## 坑：
##   · victims 里的单位可能在 await 期间死掉/被释放，所以循环里每个目标都重判
##     is_instance_valid / alive（不要 break，后面的目标仍该被打到）；
##   · target.play_hit() **故意不 await** —— await 会变成排队闪红，同时感就没了。
func _cast_aoe(caster: BattleUnit, skill: SkillData, victims: Array[BattleUnit]) -> void:
	var center := _group_center(victims)

	# ① 一颗火球飞向敌阵中心（沿途的序列帧/粒子全部来自 SkillData）
	var projectile: SkillProjectile = SKILL_PROJECTILE_SCENE.instantiate() as SkillProjectile
	fx_root.add_child(projectile)
	projectile.setup(skill, caster.global_position)
	await projectile.fly_to(center)

	# ② 中心大爆炸：burst() 内部会读 skill.hit_effect_scene / skill.burst_scale，并自毁
	projectile.burst()
	_play_sfx(skill.hit_sfx)
	if skill.screen_shake > 0.0:
		_shake_camera(skill.screen_shake)

	# ③ 逐个结算（间隔很短，观感是"同时被炸到"）
	for target in victims:
		if not is_instance_valid(target) or not target.alive:
			continue

		if target.try_block():
			create_floating_text(target, "Blocked!", block_color)
		else:
			var damage := caster.skill_damage(skill)
			var is_crit := caster.skill_crit(skill)
			if is_crit:
				damage = ceilf(damage * 1.5)
			target.take_damage(damage)
			create_floating_text(target, str(int(damage)), critical_color if is_crit else skill.tint)
			# 中心那朵爆炸盖不到斜排的角落，所以每个敌人身上再补一朵小的
			_spawn_hit_burst(skill, target.global_position, AOE_TARGET_BURST_RATIO)
			target.play_hit()          # 故意不 await：要的是"同时闪红"
		await get_tree().create_timer(aoe_step_delay).timeout

	await get_tree().create_timer(action_delay).timeout


## 计算一组单位的几何中心（世界坐标）。群体技能把火球飞到这儿再炸。
## 参数 units：单位列表（调用方应传存活目标）。
## 返回值：中心点；列表为空时返回 Vector2.ZERO（调用方已保证非空，这里只是兜底不炸）。
## 副作用：无（纯计算）。用 global_position 而不是 position：敌我可能挂在不同父节点下。
func _group_center(units: Array[BattleUnit]) -> Vector2:
	var sum := Vector2.ZERO
	var count := 0
	for unit in units:
		if is_instance_valid(unit):
			sum += unit.global_position
			count += 1
	if count == 0:
		return Vector2.ZERO
	return sum / float(count)


## 在指定位置播一朵（缩小版）命中爆炸，用来补"这个敌人也被炸到了"的画面。
## 参数 skill：技能资源（提供 hit_effect_scene / tint / hit_particles / burst_scale）；
##        pos：世界坐标；scale_ratio：相对 skill.burst_scale 的额外缩放
##        （中心那朵是 1.0，敌人身上用 Battle.AOE_TARGET_BURST_RATIO = 0.55）。
## 返回值：无（同步生成，特效自己播完自毁）。
## 副作用：在 fx_root 下 new 一个特效节点，挂世界坐标（不随单位移动）。
## 用哪个场景：优先 skill.hit_effect_scene，留空则用 DEFAULT_BURST_EFFECT_SCENE。
## 坑：纯序列帧素材（effect_fireball_hit.tscn）**没有 play()**，要走
##     SkillProjectile.play_sequence_once()；这里用 has_method 判断而不是类型判断，
##     就是为了让"程序化爆炸"和"纯序列帧"两种命中层都能用同一个函数。
func _spawn_hit_burst(skill: SkillData, pos: Vector2, scale_ratio: float) -> void:
	var scene: PackedScene = skill.hit_effect_scene if skill.hit_effect_scene != null else DEFAULT_BURST_EFFECT_SCENE
	if scene == null:
		return
	var boom = scene.instantiate()
	fx_root.add_child(boom)
	boom.global_position = pos
	boom.scale = Vector2.ONE * maxf(0.05, skill.burst_scale * scale_ratio)
	if boom.has_method("play"):
		@warning_ignore("integer_division")
		boom.play(skill.tint, maxi(8, skill.hit_particles / 2))
	else:
		SkillProjectile.play_sequence_once(boom)


## 播一个一次性音效（不需要动 SoundManager）
## 参数 stream：音频流（来自 SkillData.cast_sfx / hit_sfx 等）。
## 返回值：无（同步，不等待播放结束）。
## 副作用：
##   · 会 new 一个 AudioStreamPlayer 并 add_child 到 **Battle 根节点**（不是 %Fx，因为音效是 2D 无关的）；
##   · 连接 player.finished → player.queue_free，所以播放完毕自动销毁，调用方不需要管；
##   · AudioStreamPlayer 是"非定位"音效（全局等响），要做左右声像得换 AudioStreamPlayer2D。
## 为什么不用 SoundManager：SoundManager 管的是 UI/常驻音效，这里需要"一次性、并发多个、
##   播完即毁"的语义；直接 new 更简单，也避免污染 SoundManager 的音量分组。
## 坑：volume_db 写死 -6.0（约一半音量），技能音效没有独立音量字段可配。
func _play_sfx(stream: AudioStream) -> void:
	if stream == null:
		return
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.volume_db = -6.0
	add_child(player)
	# 用 Callable(player.queue_free) 而不是 lambda：节点被释放后再回调也不会持有无效引用。
	player.finished.connect(player.queue_free)
	player.play()


## 命中时抖一下镜头（纯代码，不需要素材）
## 参数 amount：抖动幅度（像素），来自 SkillData.screen_shake（默认 7.0）。
## 返回值：无（**不 await** —— 抖动是"后台播放"的，不会阻塞战斗节奏）。
## 副作用：创建一个 Tween，反复修改 camera.position；结束时把镜头精确复位到 base。
## 实现细节：
##   · 先记下 base = camera.position，收尾一定要动画回到 base，否则镜头会永久偏移；
##   · 4 次随机偏移各 0.04s（共 0.16s 的抖动）+ 0.06s 回正；
##   · 用 randf_range(-amount, amount) 而不是只往一个方向抖，保证是"震"而不是"推"；
##   · 每次 tween_property 都是顺序执行的（没有 parallel()），所以是"抖-抖-抖-抖-回正"的短促节奏。
## 坑：抖的是 Camera2D 的 position（节点自身坐标），如果 Camera2D 上挂了跟随逻辑，
##     两处都会写 position，可能互相打架（当前战斗场景没有跟随脚本，所以安全）。
func _shake_camera(amount: float) -> void:
	if camera == null:
		return
	var base := camera.position
	var tween := create_tween()
	for i in 4:
		tween.tween_property(camera, "position",
			base + Vector2(randf_range(-amount, amount), randf_range(-amount, amount)), 0.04)
	tween.tween_property(camera, "position", base, 0.06)


## 有单位阵亡（信号 BattleUnit.died）时刷新出手顺序条。
## 参数 _unit：阵亡的单位。带下划线前缀 = 故意不使用它（顺序条只关心"还有谁活着"，
##              不关心死的是谁），同时避免 GDScript 的"未使用参数"警告。
## 返回值：无。
## 副作用：调 turn_order.update_order() 重建顺序条图标；**不动 turn_queue / turn_index** ——
##         当前的出手队列保持原样，死掉的那个会在 _begin_turn() 轮到时被跳过，
##         所以本回合内不会出现"下标错位、有人被跳过一次"的问题。
## 注意：update_order 收到的是"活人列表"，所以顺序条上的队形会实时缩短；已死单位不再显示。
func _on_unit_died(_unit: BattleUnit) -> void:
	turn_order.update_order(_alive(_all_units()))


# ══════════════════════════════════════════════════════════
#  胜负 / 飘字 / 工具
# ══════════════════════════════════════════════════════════

## 胜负判定。流程里被反复调用（每个回合开始、每次攻击/技能结算之后），所以必须"幂等"。
## 参数/返回值：bool —— true 表示"战斗已经结束（或刚刚结束）"，调用方应当立刻 return 不再推进流程；
##                   false 表示双方都还有活人，可以继续。
## 副作用（只在判定出结果的那一次）：
##   · 调 _finish_battle() —— 会把 state 置 FINISHED、清 actor/_pending_skill、关菜单、
##     取消目标高亮、清顺序条当前标记、写提示文字、并 emit battle_ended(player_won)。
## 判定口径：**只看"我方是否还有人活着"**（players_alive），敌方是否还有人活着只用来决定"要不要继续"。
##   所以"我方死光"= 失败，"敌方死光"= 胜利，同时死光算失败（因为 players_alive 为 false）。
## 幂等性来自第一句：state 已经是 FINISHED 就直接 return true，
##   保证 battle_ended 只发一次（重复发信号会让外部反复结算经验/掉落）。
func _check_battle_end() -> bool:
	if state == State.FINISHED:
		return true
	# 这里用 _alive(...).is_empty() 而不是遍历计数 —— _alive 会顺带做 is_instance_valid 过滤，
	# 能顺带处理"节点已被外部释放"的情况。
	var players_alive := not _alive(_players).is_empty()
	var enemies_alive := not _alive(_enemies).is_empty()
	if players_alive and enemies_alive:
		return false
	# 传 players_alive 作为胜负：我方还有人 = 胜。reason 只是信息栏文案，不影响逻辑。
	_finish_battle(players_alive, "胜利！" if players_alive else "战斗失败…")
	return true


## 结束战斗：把所有"进行中"的状态清干净，然后对外广播结果。这是整场战斗唯一的收口点。
## 参数 player_won：胜负（true = 我方胜）；reason：显示在信息栏的结束语（"胜利！""撤退"等）。
## 返回值：无。
## 副作用（顺序敏感）：
##   · state = FINISHED（**第一件事**，让所有 await 续行代码在之后的每个 _check_battle_end() 里立刻收敛）；
##   · actor / _pending_skill 置 null；
##   · command_menu.close() + _highlight_targets(false) + turn_order.clear_current()（把 UI 复位，
##     注意 _highlight_targets 同时会清空 _targets）；
##   · 改写 info_label.text；
##   · **emit battle_ended(player_won)** —— 外部结算入口（经验/掉落/回地图）。
## 为什么第一句要判 FINISHED：这个函数有多个调用点（一方全灭、玩家点逃跑），
##   没有幂等保护就会出现"逃跑时同时触发全灭判定 → battle_ended 发两次 → 经验发两份"。
## 注意：这里不 queue_free 任何单位、也不切场景 —— 战场会保持原样停在结算画面，
##   由接 battle_ended 的外部决定什么时候离开。
func _finish_battle(player_won: bool, reason: String) -> void:
	if state == State.FINISHED:
		return
	state = State.FINISHED
	actor = null
	_pending_skill = null
	command_menu.close()
	_highlight_targets(false)
	# 收掉所有行动者轮廓：战斗都结束了不该还有人亮着
	for unit in _all_units():
		if is_instance_valid(unit):
			unit.set_selected(false)
	turn_order.clear_current()
	info_label.text = reason
	battle_ended.emit(player_won)
	# TODO: 结算（经验 / 掉落 / 回地图）接在这里


## 在某个单位头顶生成一个飘字（伤害数字 / "Blocked!" / "防御"）。
## 参数 unit：飘在谁头上（只用来取坐标，不修改该单位）；text：显示内容；color：文字颜色。
## 返回值：无（飘字自己播完动画后 queue_free，调用方不用管）。
## 副作用：从 Global.FLOATING_TEXT_SCENE 实例化一个 FloatingText 并挂到 %Fx 下。
## 坐标换算说明：unit.global_position 是单位的**中心**（脚底在下方），
##   所以 y 再 -70 把它抬到头顶上方；x 加 ±18 的随机抖动，
##   这样连续多次伤害（群体技能连炸）时飘字不会完全重叠成一条竖线。
## 顺序讲究：必须先 add_child() 再 setup() —— setup() 内部会访问 FloatingText 的
##   @onready value_label，节点没进树时那个引用还是 null（和 BattleUnit.setup() 同一个坑）。
##   另外 global_position 要在 add_child 之后设置才直观（进树前设的位置也是生效的，
##   但父节点未定之前 global_position 没有明确的参照系）。
## 注意：这里用的是 Global 单例里的 preload 常量，而不是本地 const —— 与 Arena 的飘字共用同一个场景。
func create_floating_text(unit: BattleUnit, text: String, color: Color) -> void:
	var fx := Global.FLOATING_TEXT_SCENE.instantiate() as FloatingText
	fx_root.add_child(fx)
	fx.global_position = unit.global_position + Vector2(randf_range(-18.0, 18.0), -70.0)
	fx.setup(text, color)


## 返回"我方 + 敌方"的全部单位（含已阵亡）。
## 参数/返回值：新构造的 Array[BattleUnit] —— 注意是**新数组**，对它的增删不会影响 _players/_enemies。
## 副作用：无。
## 用途：只给 _alive() 当输入用（_clear_units、_next_round、_on_unit_died、_check_battle_end 里的判别）。
## 为什么每次新建而不是缓存：成员列表会随生成/清场变化，缓存容易和 _players/_enemies 不同步；
##   单位数量只有个位数，这点分配开销可以忽略。
func _all_units() -> Array[BattleUnit]:
	var out: Array[BattleUnit] = []
	out.append_array(_players)
	out.append_array(_enemies)
	return out


## 过滤出"还活着的单位"（这是本项目里唯一可靠的存活判断入口）。
## 参数 list：任意单位数组，允许包含已释放的节点。
## 返回值：新数组。**不是就地过滤** —— 原数组保持不变。
## 副作用：无。
## 双重判断的意义：
##   · is_instance_valid(unit) —— 节点可能已经被 queue_free 并真正释放（例如切场景/重开战斗之后），
##     此时访问 unit.alive 会直接报错，所以必须先验证；
##   · unit.alive —— BattleUnit 自己的存活标记（hp<=0 时由 _die() 置 false），
##     节点还在但已经死了的情况全靠它。
## 注意：创建单位时数组里可能塞进 null（队伍配置留空位），is_instance_valid(null) 返回 false，
##   所以这里天然把 null 也过滤掉了，不需要额外判空。
func _alive(list: Array[BattleUnit]) -> Array[BattleUnit]:
	var out: Array[BattleUnit] = []
	for unit in list:
		if is_instance_valid(unit) and unit.alive:
			out.append(unit)
	return out


## 全局输入兜底：选目标阶段按 ESC / 右键 → 退回指令菜单（取消本次选目标）。
## 参数 event：引擎分发过来的未处理输入事件。
## 返回值：无。
## 副作用：
##   · 取消所有目标高亮并清空 _targets（_highlight_targets(false)）；
##   · 清掉待选技能（下次"攻击"不会被误当成"用上次那个技能"）；
##   · state 退回 COMMAND 并重新 open_for(actor) 打开指令菜单；
##   · **调 get_viewport().set_input_as_handled() 把事件吃掉** —— 否则同一个 ESC 会继续往上传，
##     可能被别的 UI（暂停菜单之类）再次消费，一次按键关两层界面。
## 为什么用 _unhandled_input 而不是 _input：_unhandled_input 在 Control/Button 处理完之后才跑，
##   所以玩家点按钮、按 UI 焦点操作时不会误触发这里；只有"没人处理"的 ESC 才走到这。
## "ui_cancel" 是引擎内建的动作（默认绑 ESC、部分平台也绑右键），所以右键取消是白送的。
## 坑：这里没判 actor 是否为 null 就直接 open_for(actor) —— 能走到这个分支时
##     state 还是 TARGET_SELECT，而进入该状态必然有 actor，所以当前是安全的；
##     但如果将来有别的代码在 TARGET_SELECT 期间清空 actor，这里会打开一个空菜单。
func _unhandled_input(event: InputEvent) -> void:
	if state != State.TARGET_SELECT:
		return

	# 选目标阶段的键盘操作：方向键（四个方向都行）切换目标 / Enter·空格 确认 / 右键·ESC 退回。
	# 鼠标那条路完全不受影响 —— 单位被点击照样走 _on_unit_clicked（信号在 _spawn_team 里连的）。
	# 注意 ui_accept（Enter / 空格）在指令菜单有焦点时会被 Button 先吃掉，所以不会跑到这里来。
	if event.is_action_pressed("ui_cancel"):
		_highlight_targets(false)
		_pending_skill = null
		state = State.COMMAND
		command_menu.open_for(actor)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("ui_left") or event.is_action_pressed("ui_up"):
		_move_target_cursor(-1)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("ui_right") or event.is_action_pressed("ui_down"):
		_move_target_cursor(1)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("ui_accept"):
		_confirm_focused_target()
		get_viewport().set_input_as_handled()
