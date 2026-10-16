# ═══════════════════════════════════════════════════════════════════════════
# MapScreen —— 【已废弃】旧版"点热点换图"的地图界面（保留仅作参考）
# ═══════════════════════════════════════════════════════════════════════════
# 现状（读代码前先看这段，免得白读）：
#   · GameRoot 已经**不再**加载本场景/脚本（main.gd 里没有 MAP_SCREEN 常量、也没有任何引用），
#     现在的地图是可探索的 scenes/world/world_map.tscn（WorldMap），走 NPC 对话传送；
#   · 因此本文件没有任何"运行期影响"：改坏了也不会影响游戏，但它记录的"归一化热点坐标换算"
#     思路仍然值得一看（WorldMap 沿用了同一套"归一化 → 像素"的换算约定）；
#   · ⚠ 它还留着一处**必然报错**的旧字段引用：_render() 与 _create_exit_button() 里的
#     `_map.exit_label` —— 现在的 MapData 上已经没有 exit_label 这个字段了（早先版本有，
#     后来换成了"由 NPC 的 teleport_label 决定按钮措辞"）。所以哪怕你想把这个屏幕接回来，
#     也必须先把那两处改成别的字段（例如 display_name 或 next_id）；这也反过来说明它是彻底的死代码。
#
# 它当年在系统里的位置：
#   旧流程是 GameRoot.show_map() 实例化本屏幕 → 挂到 UIRoot → 玩家点地图上的出口热点 → 传送。
#   接口和 WorldMap 一样：setup() 灌数据、三个信号（battle/travel/back）抛给 GameRoot。
#
# 场景构成（map_screen.tscn）：
#   MapScreen(Control, 本脚本, 全屏锚点)  ← 所有子节点的坐标空间都等于屏幕坐标
#   ├─ BG(Panel)                         纯背景色
#   ├─ MapArea(AspectRatioContainer, 16:9) 把地图贴图按 16:9 居中铺开
#   │   └─ MapImage(TextureRect, %MapImage) 地图图片；expand_mode = 1（忽略图片原始尺寸）
#   ├─ Hotspots(Control, %Hotspots)      热点层（透明、mouse_filter = IGNORE）
#   │   └─ （运行时）出口按钮：由 _create_exit_button() 动态建出来
#   └─ Margin/VBox/...                   顶部地图名/金币、队伍信息、底部三个按钮
#
# 关键坐标约定（本文件唯一"有技术含量"的部分）：
#   传送点位置是**归一化坐标**（MapData.exit_center，0~1，相对地图图片），
#   运行时按 MapImage 的实际显示矩形换算成像素：
#       像素中心 = rect.position + exit_center * rect.size
#       按钮左上 = 像素中心 - 按钮尺寸 / 2
#   于是窗口怎么缩放，热点都跟着贴图走。
#   ⚠ 之所以能用 MapImage 的 rect（它在 MapArea 坐标系里）去给 Hotspots 里的按钮定位置，
#     是因为 MapArea 与 Hotspots 都是**铺满根节点、offset 为 0** 的全屏锚点容器，
#     两者的本地坐标恰好与屏幕坐标重合。若以后给 MapArea/Margin 加了偏移，
#     这个换算就会整体错位（必须先做坐标空间转换）。
#
# 坑：
#   · 第一次排版时机：AspectRatioContainer 要到它自己 _ready/排版之后才有正确尺寸，
#     所以 _ready() 里除了直接调 _layout_exit()，还要 call_deferred("_layout_exit")
#     等一帧（延迟到空闲时执行）再算一次（见 _ready 的注释）；
#   · `call_deferred("_layout_exit")` 用的是**方法名字符串**，写错名字不会编译报错，
#     只会在运行时打印错误（改成 Callable 形式会更安全，这里保持原写法）；
#   · 动态 new 出来的出口按钮 owner 为 null，所以重建时只能 queue_free() 它自己。

extends Control
class_name MapScreen

## ⚠️ 已废弃（2026-10）：地图改成了"可探索世界地图" scenes/world/world_map.tscn
##    —— 玩家能走动、相机跟随、靠跟 NPC 对话传送（且双向）。
##    本文件保留仅作参考，GameRoot 已经不再加载它，可以直接删掉。

## 地图界面：显示当前地图图片 + 可点击的传送点 + 顶部信息 + 底部按钮
##
## 传送点位置来自 MapData.exit_center / exit_size（归一化 0~1，相对地图图片），
## 运行时换算成像素并贴在图片对应位置，所以窗口怎么缩放都跟着走。
##
## 调传送点坐标的小技巧：运行游戏进地图后，把鼠标移到图上的出口处，按 F1，
## 控制台会打印该点的归一化坐标，把 x/y 填进对应 .tres 的 exit_center 即可。

# ───────────────────────────────────────────────────────────────────────────
#  ── 对外信号（旧流程里由 GameRoot 订阅；现在已无人订阅）──
# ───────────────────────────────────────────────────────────────────────────
## 「进入战斗」按钮 → GameRoot.enter_battle()。
signal battle_requested
## 传送/前往下一处 → GameRoot.travel_to(next_id)。
## 参数 next_id：目标地图 id（旧版直接取 MapData.next_id，是"单向下一点"，
## 不像 WorldMap 那样由 NPC 的 destinations 决定）。
signal travel_requested(next_id: String)
## 「返回主菜单」→ GameRoot.show_title()。
signal back_to_title_requested

# ───────────────────────────────────────────────────────────────────────────
#  ── 数据（由 setup() 在 add_child 之前灌入）──
# ───────────────────────────────────────────────────────────────────────────
## 本屏要显示的地图配置。setup() 注入；_ready() → _render() 里若为 null 会警告并放弃渲染。
var _map: MapData
## 出战队伍（只用于在 PartyLabel 上显示 HP/ATK/SPD，不参与任何计算）。
var _party: Array[UnitStats] = []
## 进入本屏时的金币数快照，仅用于显示（真值始终是 Global.coins）。
var _coins := 0
## 顶部结算文案（上一场战斗的胜/负），空串 = 不显示。
var _result := ""
## 本图是否已通关（决定地图名后面的"（已通关）"）。
var _cleared := false

## 运行时动态创建的出口热点按钮。没有出口（next_id 为空）时为 null。
## 每次调 _render() 都会把它重建一次（旧的 queue_free 掉），所以它在树上的实例会换；
## 外部不要长期持有它的引用（这正是 _layout_exit() 每次都要判 is_instance_valid 的原因）。
var _exit_button: Button

# ── 节点引用（% = unique_name_in_owner）──────────────────────────────────────
## 地图贴图（TextureRect，位于 MapArea 这个 16:9 的 AspectRatioContainer 里）。
## 「热点该贴在图片哪个位置」就是靠它的 get_rect() 算出来的。
@onready var map_image: TextureRect = %MapImage
## 热点层（全屏 Control，mouse_filter = IGNORE 所以自身不吃事件）。
## 出口按钮被 add_child 到这里；因为它是全屏无偏移的，所以能直接吃屏幕坐标。
@onready var hotspots: Control = %Hotspots
## 顶部左侧地图名（通关后追加"（已通关）"）。
@onready var map_name_label: Label = %MapNameLabel
## 顶部右侧金币显示（进入本屏那一刻的快照）。
@onready var coins_label: Label = %CoinsLabel
## 队伍信息面板：_render() 里按 _party 拼出多行文本。
@onready var party_label: Label = %PartyLabel
## 顶部结算文案标签。
@onready var result_label: Label = %ResultLabel
## 底部「进入战斗」按钮（_map.battle_enabled 为 false 时置灰）。
@onready var battle_button: Button = %BattleButton
## 底部「前往下一处」按钮（_map.next_id 为空时置灰 = 本图是终点）。
@onready var next_button: Button = %NextButton
## 底部「返回主菜单」按钮。
@onready var back_button: Button = %BackButton


## 只存数据；渲染放到 _ready（GameRoot 是先 setup 再 add_child）
## 参数：
##   map         —— 本图配置（MapData）。
##   party       —— 出战队伍（只读，用于显示）。
##   coins       —— 进入本屏的金币数（只用于显示）。
##   result_text —— 顶部要飘的结算文案，空串 = 不显示。
##   cleared     —— 本图是否已通关。
## 返回值：无。
## 副作用：只写本对象的私有字段（不 emit、不碰 Global、不建节点）。
## 为什么必须与 _ready() 分开：GameRoot 是"先 setup 再 add_child"，
##   此刻本节点还没进树，@onready 变量（%MapImage 等）全是 null —— 在这里渲染会直接报错。
func setup(map: MapData, party: Array[UnitStats], coins: int, result_text: String, cleared: bool) -> void:
	_map = map
	_party = party
	_coins = coins
	_result = result_text
	_cleared = cleared


## 生命周期：渲染内容、连按钮、把"热点重排"挂到各种尺寸变化事件上。
## 参数：无。返回值：无。
## 副作用：
##   · 调 _render()（贴图/文字/按钮启用状态，并建出出口按钮）；
##   · connect 三个按钮的 pressed（各一次，节点销毁时随连接一起消失）；
##   · connect 两处 resized：自身的（窗口/全屏尺寸变了）和 map_image 的
##     （AspectRatioContainer 重新排版导致图片矩形变了）—— 两处都连才覆盖所有缩放情形；
##   · _layout_exit() 立即算一次；
##   · call_deferred("_layout_exit") 再排一次到帧末空闲时执行。
## 为什么要 call_deferred 那一次（本文件最关键的时序点）：
##   AspectRatioContainer 的尺寸是在它自己的 _ready/首次排版时才确定的，
##   本节点 _ready() 里立刻取 map_image.get_rect() 拿到的可能是**还没排版**的 0 尺寸矩形
##   （_layout_exit 里会因 size <= 0 直接 return）。call_deferred 把第二次计算推迟到
##   本帧空闲阶段 —— 那时容器已完成首次排版，rect 才有真实值。
##   之后任何尺寸变化都由上面那两条 resized 连接负责，不需要每帧重算。
func _ready() -> void:
	_render()
	battle_button.pressed.connect(_on_battle_pressed)
	next_button.pressed.connect(_on_next_pressed)
	back_button.pressed.connect(_on_back_pressed)
	resized.connect(_layout_exit)
	map_image.resized.connect(_layout_exit)      # 容器排版变化时也要跟着挪
	_layout_exit()
	call_deferred("_layout_exit")                # 等 AspectRatioContainer 完成第一次排版


## 把 MapData 与队伍信息画到界面上（纯粹的"数据 → 控件文本"填充）。
## 参数：无（读 setup 灌进来的字段）。
## 返回值：无。
## 副作用：改若干 Label 的 text/visible、两个按钮的 disabled/text、
##   调用 _create_exit_button() 建立出口热点。
## 细节：
##   · _map 为 null 时警告并 return（其余控件保持场景里的默认文本，不会崩）；
##   · 队伍文本用 Array[String] 收集再 join —— 空队伍时显示"（还没选角色）"而不是空白；
##   · `"%s%s" % [显示名, "（已通关）" if _cleared else ""]` 是刻意用拼接而不是条件分支，
##     这样两种情况下都只有一条格式化语句；
##   · speed 用 int() 转换是因为 UnitStats.speed 是 float，直接 %d 会报类型错。
func _render() -> void:
	if _map == null:
		push_warning("MapScreen: 没有拿到 MapData")
		return

	map_image.texture = _map.texture
	map_name_label.text = "%s%s" % [_map.display_name, "（已通关）" if _cleared else ""]
	coins_label.text = "金币：%d" % _coins
	result_label.text = _result
	result_label.visible = not _result.is_empty()

	var lines: Array[String] = []
	for stats in _party:
		if stats != null:
			lines.append("%s    HP %.0f    ATK %.0f    SPD %d" % [stats.name, stats.health, stats.damage, int(stats.speed)])
	party_label.text = "出战队伍：\n" + ("\n".join(lines) if not lines.is_empty() else "（还没选角色）")

	battle_button.disabled = not _map.battle_enabled
	next_button.disabled = _map.next_id.is_empty()
	if not _map.next_id.is_empty():
		# ⚠ 旧字段已不存在：MapData 上现在没有 exit_label（见文件头"现状"）。
		#   这行一旦被执行就会报"无效属性/不存在的成员"，是判断"本文件已死"的另一个证据。
		next_button.text = _map.exit_label
	_create_exit_button()


## 在地图上重建"出口热点按钮"（贴在 MapData.exit_center 处）。
## 参数：无。返回值：无。
## 副作用：
##   · 旧按钮 queue_free()（并置 _exit_button = null）；
##   · 新建一个 Button、设文案/字体/鼠标指针样式、connect pressed → _on_next_pressed、
##     add_child 到 hotspots。
## 细节：
##   · 判空用 `_exit_button != null and is_instance_valid(_exit_button)`：
##     前半个条件挡住"从没建过"（null），后半个挡住"已经 queue_free 但引用还在"；
##   · next_id 为空（本图是终点）时直接 return，于是没有热点按钮，玩家只能打或返回；
##   · 新按钮的 owner 是 null（运行时 add_child），所以重建时只能 queue_free() 自己；
##   · 位置不在这里设置 —— 由 _layout_exit() 负责（因为位置依赖排版后的实际尺寸）。
func _create_exit_button() -> void:
	if _exit_button != null and is_instance_valid(_exit_button):
		_exit_button.queue_free()
		_exit_button = null
	if _map.next_id.is_empty():
		return

	_exit_button = Button.new()
	# ⚠ 同上：_map.exit_label 这个字段已经从 MapData 里删掉了（现在按钮措辞由 MapNPC.teleport_label 决定）。
	_exit_button.text = _map.exit_label
	_exit_button.add_theme_font_size_override("font_size", 22)
	_exit_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_exit_button.pressed.connect(_on_next_pressed)
	hotspots.add_child(_exit_button)


## 把归一化坐标换算成像素，贴在图片上（窗口缩放时会重算）
## 参数：无。返回值：无。
## 副作用：改 _exit_button 的 size 与 position。
## 三条提前返回（都必要）：
##   · 按钮不存在 / 已被释放 —— 没有东西可摆；
##   · _map 为 null —— 后面要读 _map.exit_center；
##   · rect 尺寸 <= 0 —— 容器还没排版，此时算出来的位置是错的（宁可不动，等下一次 resized）。
## 换算过程：
##   rect = map_image.get_rect()  —— 图片在**父容器(MapArea)坐标**里的矩形。
##   size = Vector2(0.16, 0.12) * rect.size —— 热点按钮尺寸取图片的 16%×12%
##     （写死在这里：MapData.exit_size 字段已被移除，所以不再可由 .tres 配置）。
##   center = rect.position + _map.exit_center * rect.size —— 归一化坐标乘图片尺寸得到像素中心。
##   position = center - size * 0.5 —— Control 的 position 是**左上角**，所以要减去半尺寸居中。
func _layout_exit() -> void:
	if _exit_button == null or not is_instance_valid(_exit_button) or _map == null:
		return
	var rect := map_image.get_rect()                     # 图片实际显示区域（MapArea 里那块 16:9）
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	var hotspot_size := Vector2(0.16, 0.12) * rect.size          # 旧版热点大小（MapData.exit_size 已移除）
	var center := rect.position + _map.exit_center * rect.size
	_exit_button.size = hotspot_size
	_exit_button.position = center - hotspot_size * 0.5


# ══════════════════════════════════════════════════════════
#  按钮
# ══════════════════════════════════════════════════════════

## 「进入战斗」按钮回调 → 播 UI 音效 + emit battle_requested。
## 参数：无。返回值：无。
func _on_battle_pressed() -> void:
	_click()
	battle_requested.emit()


## 「前往下一处」/出口热点回调 → 播 UI 音效 + emit travel_requested(_map.next_id)。
## 参数：无。返回值：无。
## 副作用：额外做了双保险判断（_map 为 null 或 next_id 为空时直接 return 不发音效）——
##   因为热点按钮和底部按钮共用本回调，热点层理论上可能残留旧按钮。
func _on_next_pressed() -> void:
	if _map == null or _map.next_id.is_empty():
		return
	_click()
	travel_requested.emit(_map.next_id)


## 「返回主菜单」按钮回调 → 播 UI 音效 + emit back_to_title_requested。
## 参数：无。返回值：无。
func _on_back_pressed() -> void:
	_click()
	back_to_title_requested.emit()


## 统一的按钮点击音效（三处调用）。
## 参数：无。返回值：无。副作用：占用 SoundManager 播放器池里的一个播放器播 UI 音。
func _click() -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)


## 调试：把鼠标所在位置换算成地图归一化坐标打出来，方便填 exit_center
## 参数 event：引擎派发的输入事件（只有 F1 键会触发打印）。
## 返回值：无。副作用：print 一行；命中时把事件标记为已处理（不再向下传递）。
## 换算与 _layout_exit 相反：
##   n = (鼠标本地坐标 - 图片矩形左上角) / 图片矩形尺寸。
##   用的是 get_local_mouse_position()（本控件坐标）+ map_image.get_rect()（MapArea 坐标）——
##   两者能直接相减，同样依赖"MapArea 与根控件都铺满全屏、偏移为 0"这个前提。
## 坑：这里访问 _map.display_name **没有判空**，如果 _map 为 null（例如没经过 setup 就
##   直接 F6 运行本场景）按 F1 会在这一行报错 —— 保留原样，仅供调试参考。
## 过滤条件 event.pressed and not event.echo 是为了忽略按键的自动重复事件。
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F1:
		var rect := map_image.get_rect()
		if rect.size.x <= 0.0:
			return
		var n := (get_local_mouse_position() - rect.position) / rect.size
		print("[MapScreen] %s 鼠标归一化坐标: Vector2(%.3f, %.3f)" % [_map.display_name, n.x, n.y])
		get_viewport().set_input_as_handled()
