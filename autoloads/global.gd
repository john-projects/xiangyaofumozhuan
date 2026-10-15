## ═══════════════════════════════════════════════════════════════════════════
## Global —— 全局状态 + 全局信号总线 + 全局资源表（autoload 单例）
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   project.godot 的 [autoload] 第一行 `Global="*uid://bdjgulsh2dnnk"`（指向本脚本，不是场景），
##   所以它由引擎在启动时自动实例化，任何场景、任何脚本都能直接用 `Global.xxx` 访问。
##   它是全项目共享的"黑板"：金币、玩家引用、暂停标志、抽卡概率、公共资源 preload 全在这里。
##
## 本文件的职责（正好是从上到下的顺序）：
##   1. 全局信号总线：战斗 / 单位事件（飘字、升级、敌人死亡）用信号广播，表现层来订阅
##   2. 公共资源常量：飘字、金币、道具卡、选人卡、生成特效，以及按稀有度分的 StyleBoxFlat
##   3. 概率配置：升级面板与商店面板两套稀有度权重表
##   4. 稀有度枚举与配色：UpgradeTier + TIER_COLORS
##   5. 运行时状态：coins / player / game_paused / 选人结果 / 已装备武器
##   6. 工具函数：概率判定、按名字实例化玩家、稀有度→样式、抽卡
##
## 数据流（谁写谁读）：
##   · coins        写：Coins 拾取、ShopCard 扣款、ShopPanel 卖出返还、Main 通关奖励与 start_new_game 重置
##                  读：CoinsBag 显示、ShopCard 判断买不买得起
##   · player       写：get_selected_player()；读：武器、敌人 AI、摄像机、飘字、StatsContainer 全都靠它
##   · game_paused  写：Spawner 波次结束置 true、Arena 开新波 / 选人完成置 false
##                  读：Player / Weapon / Enemy / Arena 的 _process 开头，用它"冻住"战斗
##   · main_player_selected / main_weapon_selected  写：SelectionPanel 点击；读：Arena 开局实例化
##   · equipped_weapons  写：商店买入 / 合成 / 卖出；读：判断"最多 6 把"和"同名两把可合成"
##
## 坑（改之前务必看）：
##   · 这些字段**跨场景存活**：切场景不会重置。开新档必须像 Main.start_new_game() 那样逐项手动清
##     （coins / equipped_weapons / 两个 selected）—— 注意它并没有清 `player`，所以旧的一局结束后
##     Global.player 可能仍指向一个已被释放的节点，这正是别处到处写 is_instance_valid(Global.player) 的原因。
##   · 本文件里的 print() 是刻意留的调试输出，不是漏删。
##
## 与其他 autoload 的关系：
##   SoundManager（autoloads/sound_manager.gd + 场景）负责音效；TooltipManager 负责悬停提示卡。
##   三者互相独立，都只是"全局可访问"，没有依赖顺序。
extends Node

## ── 全局信号总线 ────────────────────────────────────────────────────────────
## 单位侧只管 emit（甚至不知道自己被谁监听），具体表现（飘字、金币、面板切换）由 Arena 订阅后实现。
## 这样"战斗逻辑"和"UI 表现"不必互相引用，也方便在没有 Arena 的场景里安全地 emit（没人听就什么也不发生）。
## 注意：信号挂在 autoload 上，所以它比任何场景都活得久。
## 订阅方随场景销毁时 Godot 会自动清理它发出的连接；但如果是普通 Object 手动 connect，要自己记着断开，
## 否则切场景再回来会重复连接、事件被处理多次。
signal on_create_block_text(unit: Node2D)                              # 请求为 unit 弹一个 "Blocked!" 飘字；由 Unit 格挡成功时 emit
signal on_create_damage_text(unit: Node2D, hitbox: HitboxComponent)    # 请求为 unit 弹伤害数字；hitbox 里带着 damage 与 critical，Arena 据此选颜色
signal on_create_heal_text(unit: Node2D, heal: float)                  # 请求为 unit 弹 "+N" 回血飘字；玩家 hp_regen 与武器吸血都会 emit

signal on_upgrade_selected                                             # 玩家选完一张升级卡；UpgradeCard 无参 emit，Arena 收到后关升级面板、开商店面板
signal on_enemy_died(enemy: Enemy)                                     # 敌人死亡；Enemy 自己 emit，Arena 收到后 deferred 掉金币（等物理帧结束再 add_child）

## ── 公共资源表 A：场景 / 材质 ───────────────────────────────────────────────
## 这些是"多个场景都要用、又不专属于某一个场景"的对象。全部用 preload 常量持有：
## preload 在脚本加载时就完成，运行期零查找开销，也避免各处重复 load() 同一个路径。
## 想换美术表现（例如换飘字外观）只改这里的 uid 即可，调用方代码不用动。
const FLASH_MATERIAL = preload("uid://beabn3es4m4m7")           # 受击白闪材质。Unit.set_flash_material() 把它贴到 sprite.material 上，FlashTimer 超时后再置 null
const FLOATING_TEXT_SCENE = preload("uid://btdihrlsugqm0")      # 飘字（FloatingText）。Arena.create_floating_text() 与 Battle 都会实例化它
const COINS_SCENE = preload("uid://bn5dp1yci6xun")              # 掉落的金币（Coins）。Arena.spawn_coins() 在敌人死亡时 deferred 生成
const ITEM_CARD_SCENE = preload("uid://cywh7kffjjslc")          # 商店里的道具小卡（ItemCard）。只由 ShopPanel.create_item_card() 统一实例化
const SELECTION_CARD_SCENE = preload("uid://ba1g5c2p6inv6")     # 选人 / 选初始武器用的卡（SelectionCard）。SelectionPanel 用它铺两排
const SPAWN_EFFECT_SCENE = preload("uid://bijtsm4f8ctpl")       # 敌人出场特效（EnemySpawnEffect）。Spawner.spawn_enemy() 先播特效再放敌人

## ── 公共资源表 B：稀有度样式 ────────────────────────────────────────────────
## StyleBoxFlat，配 get_tier_style() 使用，给卡片描边/底色分档。
## 卡片侧统一这样用：add_theme_stylebox_override("panel", Global.get_tier_style(tier))
##   （ItemCard 因为继承 Button，覆盖的是 "normal" 而不是 "panel"，见 item_card.gd）
const COMMON_STYLE = preload("uid://c383vl8xrt17p")             # 普通（无描边）
const EPIC_STYLE = preload("uid://bvy27iuomo6rx")               # 史诗（紫）
const LEGENDARY_STYLE = preload("uid://v4id7ydojihc")           # 传说（红）
const RARE_STYLE = preload("uid://5vcw7m8i2ilu")                # 稀有（蓝）。注意本组顺序是 C/E/L/R，不是按枚举顺序排的，读的时候别被绕到

## ── 抽卡概率配置（"从第几波开始出现 + 每波涨多少"）──────────────────────────
## 结构：{"稀有度": {"start_wave": 起始波数, "base_multi": 每波递增系数}}
## 消费方式见 calculate_tier_probability()：
##   该类概率 = min(1.0, (当前波数 - start_wave + 1) * base_multi) × 幸运系数
## 也就是说"越往后打、好道具越多"是线性增长的；普通档不是独立配置，而是用
##   common = 1 - (稀有 + 史诗 + 传说) 兜底算出来的。
## 两套配置的差别：商店整体比升级池慷慨（稀有档 0.10 vs 0.06）。
const UPGRADE_PROBABILITY_CONFIG = {
	"rare": {"start_wave": 2, "base_multi": 0.06},          # 第 2 波起出现稀有：第 2 波 6%、第 3 波 12%…（还要再乘幸运系数）
	"epic": {"start_wave": 4, "base_multi": 0.02},          # 第 4 波起出现史诗：第 4 波 2%，之后每波 +2%
	"legendary": {"start_wave": 7, "base_multi": 0.0023},   # 第 7 波起出现传说：第 7 波 0.23%，涨得极慢（刻意保持稀有）
}

const SHOP_PROBABILITY_CONFIG = {
	"rare": {"start_wave": 2, "base_multi": 0.10},          # 商店的稀有档比升级池慷慨：第 2 波就 10%
	"epic": {"start_wave": 4, "base_multi": 0.06},          # 第 4 波 6%，之后每波 +6%
	"legendary": {"start_wave": 7, "base_multi": 0.01},     # 第 7 波 1%，之后每波 +1%（约为升级池的 4 倍）
}

## ── 稀有度配色 ──────────────────────────────────────────────────────────────
## 稀有度 → 描边颜色。目前唯一的使用者是 Weapon.apply_tier_outline()：
## 它把颜色传给武器 sprite 上 outline shader 的 "color" 参数（武器档次一眼可见）。
## 注意：
##   · 故意**没有** COMMON 项 —— 普通武器走的是"material = null（不要描边）"那条分支；
##     直接写 TIER_COLORS[COMMON] 会因为键不存在而报错；
##   · 颜色是 0~1 的浮点 RGB（不是 0~255），A(alpha) 省略即 1.0；
##   · UpgradeTier 枚举虽然声明在下面，但 GDScript 的顶层符号在解析阶段统一收集，
##     所以这里能直接引用 UpgradeTier.*；把两者的先后顺序调换也不会报错。
const TIER_COLORS: Dictionary[UpgradeTier, Color] = {
	UpgradeTier.RARE: Color(0.0, 0.557, 0.741),        # 蓝（约 #008EBD）
	UpgradeTier.EPIC: Color(0.478, 0.251, 0.71),       # 紫（约 #7A40B5）
	UpgradeTier.LEGENDARY: Color(0.906, 0.212, 0.212), # 红（约 #E73636）
}

## ── 稀有度枚举 ──────────────────────────────────────────────────────────────
## 道具 / 升级的稀有度。数值必须与 .tres 里存的整数一致（item_tier = 1 就等于 RARE），
## 所以**只能在末尾追加**成员；顺序同时也是 UI 上由低到高的展示顺序。
enum UpgradeTier{
	COMMON,     # 0：普通。没有专属配色，get_tier_style() 返回 COMMON_STYLE
	RARE,       # 1：稀有（蓝）
	EPIC,       # 2：史诗（紫）
	LEGENDARY   # 3：传说（红）。它同时是 get_tier_style() 的 _ 兜底分支，所以非法值看起来会"像传说"
}

## ── 可选主角表：显示名 → 玩家场景 ──────────────────────────────────────────
## 键必须等于对应 UnitStats.name 的值 —— get_selected_player() 就是拿 main_player_selected.name
## 到这张表里查场景的。改了 .tres 里的 name 却忘了改这里，会在开局那一刻报"键不存在"。
## 这 5 个名字同时也是 SelectionPanel 上显示的角色名（那边读的是 .tres 的 name）。
var available_players: Dictionary[String, PackedScene] = {
	"Brawler": preload("uid://dycg0gsn33qsb"),        # 近战莽夫：血厚、速度慢
	"Bunny": preload("uid://bcy0iisq7ckb7"),          # 兔子：速度快
	"Crazy": preload("uid://6xp7dfopqtpd"),           # 疯子：高伤低血
	"Knight": preload("uid://pgxw3yef5keu"),          # 骑士：格挡率高
	"Well Rounded": preload("uid://xrgsu4ju3us0"),    # 均衡型；键里带空格，用中括号取值时别忘了引号
}

## ── 运行时状态（跨场景存活，切场景/重开一局时不会自动清空）──────────────────
var coins: int = 500                                  # 金币（单位：枚，整数）。默认 500 与 Main.starting_coins 一致；开新档时会被 Main.start_new_game() 重置回那个值
var player: Player                                    # 当前玩家**节点**的引用（不是 UnitStats）。由 get_selected_player() 赋值、Arena 负责 add_child 进场；因为是跨场景存活的旧引用，用之前务必 is_instance_valid()
var game_paused := false                              # 全局暂停开关。true 时 Player / Weapon / Enemy / Arena 的 _process 会各自提前 return（注意这是"冻结游戏逻辑"，不是 SceneTree.paused —— Timer 和 tween 照跑）

var main_player_selected: UnitStats                   # 选人界面选中的角色数据（SelectionPanel 写入）。此时还只是 Resource，没有实例化成节点
var main_weapon_selected: ItemWeapon                  # 选人界面选中的初始武器数据（SelectionPanel 写入）。同样还只是 Resource

var equipped_weapons: Array[ItemWeapon]               # 已装备武器的**数据**列表（不是场上的 Weapon 节点），商店买入 / 合成 / 卖出都在增删它；上限 6 由 ShopCard._on_buy_button_pressed() 检查。声明时没写 = []，类型化数组默认就是空数组

## 波次结算：把玩家的"采集（harvesting）"属性折算成金币发放。
## 谁调用：Spawner._on_wave_timer_timeout()，每波计时结束时调用一次（它同时也是把 game_paused 置 true 的地方）。
## 参数：无 —— 数值取自 Global.player.stats.harvesting（UnitStats 上的字段，单位是"每波金币"，可以是小数）。
## 返回值：无。
## 副作用：
##   · 直接修改 Global.coins（因此 CoinsBag 下一个 _process 就会显示新金额，不需要通知）；
##   · int() 是**截断**不是四舍五入，所以 harvesting = 1.9 也只发 1 枚；
##   · 不 emit 信号。
## 坑：
##   · 函数名叫 get_ 却既不返回也不"只读"，实际是个加钱操作，别被名字骗了；
##   · `player` 没有做有效性检查 —— 必须在玩家已实例化之后调用（波次计时器保证了这个前提），
##     否则会直接报 "Invalid access to property on a null instance"。
func get_harvesting_coins() -> void:
	coins += int(player.stats.harvesting)

## 概率判定工具：以 chance 的概率返回 true。
## 参数 chance：0~1 的概率（不是百分数！调用方自己先除 100，例如 Unit 里传 stats.block_chance / 100）。
##   传 1.0 或更大 = 必定成功；传 0.0 = 必定失败（判定用的是严格小于 random < chance）。
## 返回值：bool。
## 副作用：**推进了全局随机数生成器的状态**。
##   这点值得记住：本函数调用一次就会改变接下来所有随机数的序列，
##   所以"多打一次暴击判定"会间接影响掉落 / 抽卡的随机结果（不是 bug，但调平衡时会让人困惑）。
## 为什么不用 randf() < chance 一行了事：
##   保留成函数是为了让判定口径统一（暴击、格挡、吸血、命中全走这里），也方便在这里加日志/保底。
func get_chance_success(chance: float) -> bool:
	var random := randf_range(0, 1.0)
	if random < chance:
		return true
	return false

## 按选人结果实例化出玩家节点（**不**入树，由调用方负责 add_child）。
## 谁调用：Arena._on_selection_panel_on_selection_completed()，拿到后 add_child(player) 再发初始武器。
# ───────────────────────────────────────────────────────────────────────────
#  ── 可招募队友（队伍系统）──
# ───────────────────────────────────────────────────────────────────────────

## 可招募队友的默认目录：里面每个 UnitStats（.tres / .res）都是一个能加入队伍的角色。
## MapNPC.recruit_pool 留空时，WorldMap 会调下面的 get_recruitable_players() 扫这个目录。
## 当前内容 = 选人界面那 5 个角色（stats_player_*.tres），和 selection_panel.tscn 的 players 是同一批。
const RECRUIT_DIR := "res://resources/units/players/"

## 上一次扫描的缓存。角色的 .tres 在运行期不会变，反复开招募面板没必要反复读盘。
var _recruit_cache: Array[UnitStats] = []


## 扫描 RECRUIT_DIR，返回里面所有 UnitStats，按资源路径排序（顺序稳定，UI 不会每次乱跳）。
## 参数 refresh：true = 忽略缓存重新扫（改完目录想立刻看到效果时用）。
## 返回值：Array[UnitStats]；目录打不开时返回缓存（可能是空数组）并 push_warning。
## 副作用：写 _recruit_cache；只读磁盘，不改任何资源、不发信号。
## 坑：
##   · 两种扩展名都收 —— 打包导出后文本资源可能变成 .res，只认 .tres 会扫不到；
##   · 目录里混进非 UnitStats 的资源会被静默跳过（不报错，因为目录是给人放的）；
##   · 这条路是"方便"，不是"绝对可靠"：显式填 MapNPC.recruit_pool 才是导出万无一失的做法。
func get_recruitable_players(refresh := false) -> Array[UnitStats]:
	if not refresh and not _recruit_cache.is_empty():
		return _recruit_cache
	var dir := DirAccess.open(RECRUIT_DIR)
	if dir == null:
		push_warning("Global: 打不开可招募队友目录 %s" % RECRUIT_DIR)
		return _recruit_cache
	var found: Array[UnitStats] = []
	for file_name in dir.get_files():
		if not (file_name.ends_with(".tres") or file_name.ends_with(".res")):
			continue
		var res := ResourceLoader.load(RECRUIT_DIR + file_name)
		if res is UnitStats:
			found.append(res)
	found.sort_custom(func(a: UnitStats, b: UnitStats) -> bool:
		return a.resource_path < b.resource_path)
	_recruit_cache = found
	return _recruit_cache

# ───────────────────────────────────────────────────────────────────────────
#  ── UI 文本工具 ──
# ───────────────────────────────────────────────────────────────────────────

## 把属性数值转成界面上显示的短字符串：整数不带小数点（25 而不是 25.0），真小数保留原样（12.5）。
## 存在的原因：UnitStats 里有些字段是 float（例如 health = 15.0），直接 str() 会在 UI 上
##   出现 "15.0" 这种噪音；而让每处 UI 各写一遍格式化，迟早会出现两处不一致。
## 谁在用：WorldMap 的招募按钮/悬停提示、PartyPanel 的成员属性行。
static func format_stat(value) -> String:
	var f := float(value)
	return str(int(f)) if is_equal_approx(f, roundf(f)) else str(f)


# ───────────────────────────────────────────────────────────────────────────
#  ── UI 键盘焦点工具（主菜单 / 世界地图共用）──
# ───────────────────────────────────────────────────────────────────────────
#  为什么放在 Global 里：这几段逻辑本来只在世界地图里（_collect_focusable / _step_focus /
#  _activate_focused / _is_interact_event）。主菜单也要键盘操作之后，它们就成了"两处要维护
#  同一套规则"的东西 —— 抽到这里一份，两边都调，行为不会分叉
#  （最容易分叉的正是"置灰按钮不进焦点环"这条）。
#
#  三处 UI 共同遵守的键盘约定：
#    · ↑↓ / Enter / 空格 —— 交给 Godot 内置的 ui_* 动作 + GUI 焦点系统，不用写代码；
#    · W S / E —— 工程自己的动作（move_up/move_down 与交互键），GUI 不认，
#      由各屏幕的 _unhandled_input 调下面的工具函数补上；
#    · E 之所以不能靠 Input 模拟 ui_accept：ui_accept 是 Enter/空格，GUI 会自己按；
#      E 不在其中，所以这里直接把按钮的 pressed 信号发出去（效果与点一下完全一样）。

## 这个控件现在能不能被键盘选中：可见、没被禁用、且自己允许获得焦点。
## 参数 control：任意 Control（可以为 null，返回 false）。
static func can_focus(control: Control) -> bool:
	if control == null or not control.visible:
		return false
	if control is Button and (control as Button).disabled:
		return false
	return control.focus_mode != Control.FOCUS_NONE


## 收集一个容器里所有"可点"的按钮（按树的顺序 = 视觉顺序；会递归进子容器）。
## 参数 root：容器节点（例如队伍面板的行容器、主菜单的 Center）。
## 只认 Button 是有意的：Label / 各种容器默认不该成为键盘停留点；万一某个容器
##   把 focus_mode 设成了 ALL（主题里有可能），也不该混进环里让 W/S 白停一格。
static func collect_focusable(root: Node) -> Array[Control]:
	var out: Array[Control] = []
	for child in root.get_children():
		if child is Button and can_focus(child as Control):
			out.append(child as Control)
		out.append_array(collect_focusable(child))
	return out


## 在焦点环里前后循环移动焦点。
## 参数 context：树里的任意节点（只用它拿 viewport → 问"当前焦点是谁"）。
## 参数 ring：按视觉顺序排列的可聚焦控件（调用方维护，通常由 collect_focusable 得到）。
## 参数 step：+1 = 下一个，-1 = 上一个。
## 细节：当前焦点不在环里（例如玩家刚用鼠标点了别处、或环刚被重建）时从环的第一个开始 ——
##   这样 W/S 永远能"接手"焦点，不会出现"按了没反应"。
static func step_focus(context: Node, ring: Array[Control], step: int) -> void:
	if ring.is_empty():
		return
	var current := context.get_viewport().gui_get_focus_owner()
	var index := ring.find(current)
	index = 0 if index < 0 else wrapi(index + step, 0, ring.size())
	ring[index].grab_focus()


## 按下"当前焦点上的那个按钮"（给 E 键用）。
## 参数 context：树里的任意节点（用它拿 viewport）。
## 返回值：true = 确实按下去了；false = 当前没有聚焦的按钮（或它是置灰的）。
static func activate_focused(context: Node) -> bool:
	var current := context.get_viewport().gui_get_focus_owner()
	if current is Button and not (current as Button).disabled:
		(current as Button).pressed.emit()
		return true
	return false


## 这个事件是不是"想确认/交互"（E 或 Enter）。
## 参数 event：待判定的输入事件。
## 返回值：true = 是交互事件。
## 两套并存的原因：InputMap.has_action 先判项目里有没有配 interact 动作，
##   没配时返回 false 且不报错，于是自然回落到硬编码的 E / Enter —— 配了动作用动作，
##   没配也能用（&"interact" 是 StringName 字面量，InputMap 的键就是 StringName）。
## 注意：Enter 同时也是内置 ui_accept，会被 GUI 焦点系统先消费掉；所以实际落到调用方手里的
##   主要是 E —— 这也正是"Enter 不会触发两次"的原因。
static func is_interact_event(event: InputEvent) -> bool:
	if InputMap.has_action(&"interact") and event.is_action_pressed(&"interact"):
		return true
	return event is InputEventKey and event.pressed and not event.echo \
		and (event.keycode == KEY_E or event.keycode == KEY_ENTER)


## 参数：无 —— 用 main_player_selected（SelectionPanel 写入的 UnitStats）。
## 返回值：新建的 Player 节点实例（同一个对象也已经写进了 Global.player）。
## 副作用（比较重，注意）：
##   · **覆盖 Global.player**，把上一局的旧引用直接顶掉（旧节点若属于上一场景，此刻可能已被释放）；
##   · 每次调用都 new 一个新节点 —— 重复调用会多出几个玩家，不会复用旧实例。
## 坑：
##   · main_player_selected 为 null 时，`main_player_selected.name` 直接报错，没有兜底；
##   · name 不在 available_players 的键里时，字典查找报错（见 available_players 的说明）；
##   · instantiate() 返回的是 Node，赋给类型为 Player 的成员变量时会做运行时类型检查 ——
##     若场景根节点挂的不是 Player 脚本（或它的子类），这里会抛类型错误；
##   · 局部变量 player_instance 故意没写类型标注，靠的就是上面那次隐式转换。
func get_selected_player() -> Player:
	var player_scene := available_players[main_player_selected.name]
	var player_instance := player_scene.instantiate()
	player = player_instance
	return player


## 稀有度 → 卡片样式（StyleBoxFlat），给卡片的主题覆盖用。
## 调用方（ShopCard / UpgradeCard / HoverCard / HoverItemCard 等）都是这么用：
##   add_theme_stylebox_override("panel", Global.get_tier_style(道具的 item_tier))
##   —— ItemCard 因为继承 Button，覆盖的键是 "normal" 而不是 "panel"。
## 参数 tier：UpgradeTier 枚举值（通常直接来自 ItemBase.item_tier）。
## 返回值：对应稀有度的 StyleBoxFlat 常量。
## 副作用：无。但要注意返回的是**共享的 const 资源本体**，不是副本 ——
##   调用方只能读它（挂到主题覆盖上）；谁要是改了它的 border_width 之类属性，
##   会一次性污染全局所有同稀有度的卡片。
## 兜底：match 带 `_` 分支，任何没匹配上的值（含非法整数）都会拿到传说样式，而不是报错。
func get_tier_style(tier: UpgradeTier) -> StyleBoxFlat:
	match tier:
		UpgradeTier.COMMON:
			return COMMON_STYLE
		UpgradeTier.RARE:
			return RARE_STYLE
		UpgradeTier.EPIC:
			return EPIC_STYLE
		_:
			return LEGENDARY_STYLE

## 算出当前波数下四个稀有度各自的出现概率。
## 参数 current_wave：当前波数（Arena 传的是 spawner.wave_index，从 1 开始）。
## 参数 config：概率配置表 —— Global.UPGRADE_PROBABILITY_CONFIG 或 SHOP_PROBABILITY_CONFIG。
##   注意这里用 `config.rare.start_wave` 这种"点号读字典"的写法：GDScript 允许 dict.key，
##   但它只在键是 String 时可用（这里的键确实是 "rare"/"epic"/"legendary"）。
## 返回值：Array[float]，固定四元组，顺序 = [普通, 稀有, 史诗, 传说]，四项之和约为 1.0。
##   ⚠ 顺序和下面做判定时用的区间顺序**相反**，取值时别搞反（select_items_for_offer 里就是用下标 3/2/1 取的）。
##
## 算法（三段）：
##   1) 每个非普通档 = min(1.0, (当前波 - 起始波 + 1) × 每波系数)：随波数线性增长、封顶 1.0；
##      当前波还没到 start_wave 时该档保持 0.0（这就是"第 7 波才有传说"的实现方式）。
##   2) 乘幸运系数 luck_factor = 1 + (玩家幸运值 / 100)：幸运是"百分数"语义，
##      所以 luck = 100 等于把所有非普通概率翻倍。三档各自乘，且**不在此时归一化**。
##   3) 归一化：如果三者之和 > 1.0，就整体按 1/总和 缩放，让它们正好和为 1.0；
##      普通档 = 1 - 三者之和（上一步若缩放过，这里恰好得 0.0）。
##      代码里那句 total_non_common_chances = 1.0 就是为了这个（避免浮点残差让普通档变成 1e-16 这种数）。
##
## 副作用：
##   · 只读状态：**读取 Global.player.stats.luck** —— 所以调用它之前 Global.player 必须已经存在
##     （升级/商店界面是在开局选人之后才弹的，满足前提）；
##   · 会 print() 一行调试信息，每波两次（升级一次、商店一次），这是刻意留的观察手段；
##   · 不使用随机数（真正的随机发生在 select_items_for_offer 里），所以本函数可以放心重复调用。
##
## 实现细节：返回值声明是 Array[float]，写的是普通数组字面量 —— GDScript 会按返回类型做一次隐式转换，
## 元素都经过 max(0.0, x) 保证是 float 且非负（负概率在数学上不会出现，这里是纯防御）。
func calculate_tier_probability(current_wave: int, config: Dictionary) -> Array[float]:
	var common_chance := 0.0
	var rare_chance := 0.0
	var epic_chance := 0.0
	var legendary_chance := 0.0
	
	if current_wave >= config.rare.start_wave:
		rare_chance = min(1.0, (current_wave - config.rare.start_wave + 1) * config.rare.base_multi)          # 刚好到 start_wave 那波时是 base_multi × 1，之后每多一波再多一个 base_multi
	if current_wave >= config.epic.start_wave:
		epic_chance = min(1.0, (current_wave - config.epic.start_wave + 1) * config.epic.base_multi)          # 同上，封顶 1.0 防止后期概率溢出
	if current_wave >= config.legendary.start_wave:
		legendary_chance = min(1.0, (current_wave - config.legendary.start_wave + 1) * config.legendary.base_multi)   # 系数极小（0.0023），封顶实际上永远不会触发
	
	var luck_factor := 1.0 + (Global.player.stats.luck / 100.0)   # 幸运是"百分数"：luck=100 → ×2；luck=0 → ×1（不会削弱）
	rare_chance *= luck_factor
	epic_chance *= luck_factor
	legendary_chance *= luck_factor
	
	var total_non_common_chances := rare_chance + epic_chance + legendary_chance   # 三档之和；被幸运加成后这里可能超过 1.0
	if total_non_common_chances > 1.0:
		var scale_down := 1.0 / total_non_common_chances                          # 例：三档合计 1.6 → 每项乘 0.625，合计回到 1.0
		rare_chance *= scale_down
		epic_chance *= scale_down
		legendary_chance *= scale_down
		total_non_common_chances = 1.0                                            # 只为让下面 common = 1 - 1 精确得 0.0，避免浮点残差
	
	common_chance = 1.0 - total_non_common_chances   # 普通档永远等于"剩下的份额"，所以配置表里没有 common 项
	
	# 调试输出：每波会打两行（升级池一次、商店一次），用来核对概率曲线；正式发布可以摘掉
	print("Wave: %d, Luck: %.1f => Chances: C: %.2f R: %.2f E: %.2f L: %.2f" %
	[current_wave, Global.player.stats.luck, common_chance, rare_chance, epic_chance, legendary_chance])   # 续行：依次是波数、幸运值、普通/稀有/史诗/传说四档概率
	
	# 返回顺序固定为 [普通, 稀有, 史诗, 传说]；select_items_for_offer() 就是按下标 3/2/1 去取非普通档的
	return [
		max(0.0, common_chance),        # [0] 普通
		max(0.0, rare_chance),          # [1] 稀有
		max(0.0, epic_chance),          # [2] 史诗
		max(0.0, legendary_chance),     # [3] 传说
	]
	
## 从道具池里按稀有度权重随机抽 4 件，用于升级面板 / 商店面板的"四选一"。
## 谁调用：UpgradePanel.load_upgrade() 与 ShopPanel.load_shop()，各自传入自己的池和概率配置。
## 参数 item_pool：候选道具数组（商店传 Array[ItemBase]，升级传 Array[ItemUpgrade]）。
##   形参声明是弱类型 Array，但内部 lambda 把元素标注成了 ItemBase —— 池里混进非 ItemBase 会在 filter 处报错。
## 参数 current_wave：当前波数，决定稀有度权重（哪些档已经"解锁"）。
## 参数 config：概率配置表（Global.UPGRADE_PROBABILITY_CONFIG 或 SHOP_PROBABILITY_CONFIG）。
## 返回值：抽中的道具数组，正常情况长度正好 4。
##   ⚠ 类型是弱类型 Array（不是 Array[ItemBase]），调用方要自己标注循环变量（ShopPanel 里就是这么写的）。
##
## 算法（两层循环）：
##   外层一直抽，直到凑满 4 件。每轮：
##     1) 把四档概率换算成三个**累积上限**（注意方向是反的）：
##          legendary_limit = P(传说)
##          epic_limit      = P(传说) + P(史诗)
##          rare_limit      = P(传说) + P(史诗) + P(稀有)
##        于是 roll 落点 → 档次：< legendary_limit 传说；< epic_limit 史诗；< rare_limit 稀有；否则普通。
##        对照上面的返回数组：下标 3 对应 [0, L)，下标 2 对应 [L, L+E)，下标 1 对应 [L+E, …) —— 顺序相反，别搞混。
##     2) 档次定好后，若池里该档一件都没有，就**逐级往下**找（史诗→稀有→普通）；
##        这就是"第 3 波还没配史诗道具时也不会抽空"的降级逻辑。
##     3) 找到候选后 pick_random() 随机取一件，再用 has() 去重 —— 同一屏里不会出现两件相同道具。
##
## 副作用：
##   · 推进全局随机数（randf 与 pick_random），会改变后续所有随机结果；
##   · 不修改 item_pool（filter 返回新数组），不 emit 信号，不碰 UI。
##
## 坑（很重要）：
##   · 外层 while 只在"成功 append 了一件新道具"时才有进展。若池子里**不同**道具少于 4 件，
##     后期每轮都命中"已抽过"分支，offered_items 永远长不大 → 这个 while 会**死循环卡死游戏**。
##     池子是空数组时同理。往池子里加/删道具时，务必保证 ≥ 4 件不同道具。
##   · lambda 参数标注为 `item: ItemBase`，用 Array[ItemUpgrade] 调用没问题（子类），
##     但池元素若不属于 ItemBase 体系，会在 filter 处报错。
##   · config.rare.start_wave 这种"点号读字典"要求键是 String；item_tier 与下标的整数比较则依赖枚举、.tres 两端一致。
func select_items_for_offer(item_pool: Array, current_wave: int, config: Dictionary) -> Array:
	var tier_chances := calculate_tier_probability(current_wave, config)   # [普通, 稀有, 史诗, 传说]，和下面的取值下标一一对应
	
	var legendary_limit = tier_chances[3]                        # 传说的累积上限（区间从 0 开始，所以它同时就是"传说的概率"）
	var epic_limit = legendary_limit + tier_chances[2]           # 传说 + 史诗 的累积上限
	var rare_limit = epic_limit + tier_chances[1]                # 到这里为止非普通档全部用完，剩下的 [rare_limit, 1) 就是普通档
	
	var offered_items: Array = []                                # 已抽中的道具（去重靠它）。类型是弱类型 Array，因为池子可能是 ItemBase 也可能是 ItemUpgrade
	while offered_items.size() < 4:                              # 目标：正好 4 件。⚠ 池里不同道具 < 4 件时这里会死循环
		var roll := randf()                                      # 0~1 的随机落点，用来决定这一件抽哪个稀有度
		var chosen_tier_index := 0                               # 默认 0 = 普通档（对应 UpgradeTier.COMMON）
		if roll < legendary_limit:                            # 落点在最靠前的窄区间 → 传说（3）
			chosen_tier_index = 3
		elif roll < epic_limit:                               # 落在传说区间之后、其中还剩史诗的那段 → 史诗（2）
			chosen_tier_index = 2
		elif roll < rare_limit:                               # 再往后 → 稀有（1）
			chosen_tier_index = 1
			
		# 在"当前档次及以下"里找候选：先按选中的档次筛，空了就往下降一级再筛
		var postential_items: Array = []                      # 变量名里的 postential 是原作者的拼写，保留不动；它就是"本轮的候选集合"
		var current_search_iter_index := chosen_tier_index     # 从选中档次开始往下试，最小到 0（普通档）
		
		while postential_items.is_empty() and current_search_iter_index >= 0:   # 循环条件：还没筛到东西、并且还没退到 0 以下
			postential_items = item_pool.filter(func(item: ItemBase): return item.item_tier == current_search_iter_index)   # filter 返回新数组，不改原池；lambda 里 item_tier 是 int，正好和下标比较
			if postential_items.is_empty():
				current_search_iter_index -= 1                                  # 该档没有道具 → 降一级，这就是"未解锁的档不会抽空"的兜底
			else:
				break                                                           # 找到了就跳出（这个 break 是为了语义清晰，其实外层 while 条件也会结束）
		if not postential_items.is_empty():                       # 退到 0 档还是空（池子整体为空）时跳过本轮 —— ⚠ 这种情况下外层 while 会一直空转
			var selected_item = postential_items.pick_random()    # 等价于 候选[randi() % 候选.size()]；会推进全局随机数
			if not offered_items.has(selected_item):              # 去重：已经给过的不再给（也因此池子太小会抽不满 4 件）
				offered_items.append(selected_item)
	return offered_items                                          # 长度通常为 4；池子不同道具不足时可能永远返回不了（死循环）
