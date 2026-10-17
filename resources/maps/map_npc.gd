extends Resource
class_name MapNPC

## 地图上的固定 NPC：负责对话 + 传送
##
## position 是归一化坐标（0~1，相对地图图片），运行时换算成世界坐标。
## destinations 里填"这个 NPC 能把玩家送去哪几张图"（填地图 id），
## 双向传送就是两边地图的 NPC 互相把对方写进 destinations。
##
## ── 在系统里的位置 ──
##   纯数据 Resource，本身没有任何逻辑：由 MapData.npcs 持有，运行时被 WorldMap._add_npc()
##   实例化成场景 world_npc.tscn（WorldNPC.setup(data) 把这个 Resource 整个塞给它）。
##   WorldNPC 负责画贴图、显示名字、判断玩家是否走进 interact_radius，
##   而对话内容与可去的地图 id 全部从本 Resource 读，所以改 .tres 就能改 NPC，不用碰代码。
##
## ── 数据流向 ──
##   resources/maps/*.tres 里的 MapNPC 子资源
##     → MapData.npcs（数组）
##       → WorldMap.setup() → WorldMap._add_npc() → WorldNPC.setup(本 Resource)
##         → interact 时读 dialogue 显示台词、读 destinations 生成传送按钮
##           → 玩家点按钮 → WorldMap 发出 travel_requested(map_id) → GameRoot 换地图
##
## ── 归一化坐标的坑 ──
##   position 是 0~1 的归一化值，**不是像素**。换算公式见 MapData 顶部：
##   world = position * (地图图片像素尺寸 × MapData.map_scale)。
##   好处：同一份 NPC 配置换任意分辨率的地图图片都相对位置不变；
##   坏处：在编辑器里看不出 NPC 落在画面哪儿，必须靠运行游戏按 F1 打印坐标来调（见 world_map.gd 的调试函数）。

## NPC 的唯一标识（在本图范围内唯一即可）。当前代码并不用它做查找，
## 只作为调试/以后做存档与任务系统时的稳定引用 —— 所以别随便改已发布的 id。
@export var id: String = ""
## 交互面板与提示上显示的 NPC 名字。默认 "路人"：没写名字时不至于显示空白。
@export var display_name: String = "路人"
## NPC 的贴图。留空时 WorldNPC 会退化成一块方形色块占位（先把流程跑通的兜底方案），
## 所以给 NPC 配美术素材是可选的，不是必填。
@export var texture: Texture2D                       # 留空会用一块方形色块占位
## 归一化坐标（0~1，相对地图图片左上角）。默认 (0.5, 0.5) = 图片正中央，
## 是个显眼的兜底值：忘了填一眼就能在图中间看到它。
@export var position := Vector2(0.5, 0.5)            # 归一化，相对地图图片
## 交互时显示的那一句台词（单段文本，不支持换行分支）。
## 默认 "……" 表示"这个 NPC 还没写台词"，对话面板照常弹出但什么都不说。
@export var dialogue: String = "……"
## 这个 NPC 能把玩家送到哪些地图（填 MapData.id）。
## 空数组 = 纯装饰/纯对话 NPC，WorldMap 不会给它生成传送按钮。
## 双向传送的做法：A 图 NPC 的 destinations 里有 B，B 图 NPC 的 destinations 里有 A，各自手动配。
@export var destinations: Array[String] = []          # 目标地图 id 列表
## 传送按钮上的动词措辞，便于营造场景感（例如码头 NPC 用"出海前往"、城门 NPC 用"出城前往"）。
## 默认 "我想去" 是通用说法，后面会自动拼上目标地图的 display_name。
@export var teleport_label := "我想去"                # 传送按钮的措辞，例如"出海前往"


# ───────────────────────────────────────────────────────────────────────────
#  ── 交互类型：按 E 交谈时给玩家什么按钮 ──
#  ⚠ 枚举整数值会写进 .tres，所以不要调整成员顺序。
# ───────────────────────────────────────────────────────────────────────────
## NPC 的交互类型：
##   AUTO          —— 按老规则推断（destinations 非空 = 传送，否则纯对话）。默认值，
##                    所以给已存在的 .tres 加这个字段**不会改变**它们的表现。
##   TALK          —— 只显示台词，一个按钮都不给（即使误填了 destinations 也不显示传送）。
##   TELEPORT      —— 台词 + 每个目的地一个传送按钮（读 destinations）。
##   RECRUIT_PARTY —— 台词 + 每个候选队友一个「加入 XX」按钮（读 recruit_pool）。
##   SELL_WEAPONS  —— 按 E 直接打开**商人面板**卖装备（读 sell_pool，留空 = 现有全部装备）。
##                    注意它和上面几种不一样：不在小对话框里铺按钮，而是直接开一个带滚动列表的
##                    大面板（26 件装备塞进 600×460 的小面板根本看不了），见 WorldMap._open_panel 的分流。
##                    ⚠ 枚举名是历史遗留（叫 SELL_WEAPONS），地图线现在卖的是装备
##                    （ItemEquipment：头盔/武器/腰带/项链/衣服/鞋子），不再是老的 ItemWeapon。
##   JOIN_SECT     —— 门派掌门：台词 + 每个队员一个「拜入 XX」按钮（读 sect_id）。
##                    按钮会按**种族**筛：种族的门派限制来自 Global.SECTS；
##                    已经有门派的队员、种族不符的队员都会置灰并注明原因。
##                    ⚠ 只在建邺城放了 5 个（一个门派一个），见 map_jianyecheng.tres。
enum Action {
	AUTO,
	TALK,
	TELEPORT,
	RECRUIT_PARTY,
	SELL_WEAPONS,
	JOIN_SECT,
}

## 交互类型。世界地图的 WorldMap.resolve_action() 负责把 AUTO 解析成具体类型，
## 于是"这个 NPC 会干什么"这条规则只有一份，面板和以后别的界面都问它。
@export var action: Action = Action.AUTO

## RECRUIT_PARTY 专用：可招募的队友（UnitStats 资源）。
## 留空 = 自动扫描 Global.RECRUIT_DIR（res://resources/units/players/）下的所有 UnitStats
## —— 于是"往那个目录里丢一个新角色 .tres，他就能被招募"，不用回来改 NPC。
## ⚠ 导出（打包）后文本资源可能被转成 .res，扫描依赖 PCK 的文件索引；要绝对稳妥就把
##   候选逐个拖进这个数组（显式列表优先于自动扫描，见 WorldMap._recruit_candidates）。
@export var recruit_pool: Array[UnitStats] = []

## RECRUIT_PARTY 专用：招募按钮上的动词前缀，最终文字形如「加入 Knight」。
## 与 teleport_label 分开是为了语义清楚：招募 NPC 根本不需要填传送措辞。
@export var recruit_label := "加入"

## SELL_WEAPONS 专用：这个商人卖哪些装备（ItemEquipment / ItemBase 资源）。
## 留空 = 自动用 Global.get_all_equipment()（扫 res://resources/items/equipment/ 下的全部装备，
## 当前 26 件 = 6 类 × 4~5 件）—— 于是"往那个目录丢一件新装备"它就自动上架。
## 想只卖几件（例如限量的新手商人），把这几件逐个拖进来即可（显式列表优先）。
## ⚠ 类型是 Array[ItemBase]：以后别的道具（丹药、卷轴…）也能塞进货架。
@export var sell_pool: Array[ItemBase] = []

## SELL_WEAPONS 专用：购买按钮上的动词前缀，最终文字形如「购买  12 金币」。
## 与 teleport_label / recruit_label 一样，抽出来是为了措辞能按 NPC 调（"买下"/"兑换"…）。
@export var shop_label := "购买"

## JOIN_SECT 专用：这个掌门代表哪个门派（Global.SECTS 的键：taixu / piaomiao / zixiao /
## wanyao / xingluo）。留空 = 这个 NPC 没有门派可拜（面板会提示"没有这个门派"）。
## 为什么用字符串 id 而不是直接存"门派对象"：门派是 Global 里的常量表，不是资源，
##   这样地图 .tres 只依赖一个稳定的键，改门派规则（名字/种族限制）不用动地图。
@export var sect_id: String = ""
