## MapNPC —— 地图上的固定 NPC：负责对话 + 传送
##
## 纯数据 Resource，本身没有逻辑：MapData.npcs 持有，运行时由 WorldMap._add_npc() 实例化成 world_npc.tscn，
## WorldNPC.setup(本 Resource) 后读 dialogue 显示台词、读 destinations 生成传送按钮，改 .tres 就能改 NPC。
## position 是归一化坐标（0~1，相对地图图片），**不是像素**：world = position * (图片像素尺寸 × MapData.map_scale)。
## 好处是换分辨率相对位置不变；坏处是编辑器里看不出落点，只能运行游戏按 F1 打印坐标来调（见 world_map.gd）。
## 双向传送：两张图的 NPC 各自把对方写进 destinations（手动配，没有自动反链）。
## ⚠ Action 枚举的整数值会写进 .tres，不要调整成员顺序。
extends Resource
class_name MapNPC

## NPC 的唯一标识（本图范围唯一即可）。当前代码不用它查找，只作调试/以后存档与任务的稳定引用，别随便改已发布的 id。
@export var id: String = ""
## 交互面板与提示上显示的名字。默认 "路人"：没写名字时不至于显示空白。
@export var display_name: String = "路人"
## NPC 的贴图。留空时 WorldNPC 会退化成一块方形色块占位，所以配美术素材是可选的。
@export var texture: Texture2D
## 归一化坐标（0~1，相对地图图片左上角）。默认 (0.5, 0.5) = 正中央，是个显眼的兜底值。
@export var position := Vector2(0.5, 0.5)
## 交互时显示的那一句台词（单段文本，不支持换行分支）。默认 "……" = 还没写台词，面板照常弹出。
@export var dialogue: String = "……"
## 这个 NPC 能把玩家送到哪些地图（填 MapData.id）。空数组 = 纯装饰/纯对话 NPC，不生成传送按钮。
@export var destinations: Array[String] = []
## 传送按钮上的动词措辞（如"出海前往"/"出城前往"）。默认 "我想去"，后面会自动拼上目标地图的 display_name。
@export var teleport_label := "我想去"


## NPC 的交互类型（WorldMap.resolve_action() 把 AUTO 解析成具体类型，规则只有一份）：
## AUTO = destinations 非空就传送、否则纯对话（默认值，给老 .tres 加这个字段不会改变它们的表现）；
## TALK 只显示台词；TELEPORT 台词 + 每个目的地一个按钮；RECRUIT_PARTY 台词 + 每个候选队友一个「加入 XX」；
## SELL_WEAPONS 按 E 直接开商人面板（读 sell_pool；枚举名是历史遗留，现在卖的是 ItemEquipment 装备，不是老 ItemWeapon）；
## JOIN_SECT 门派掌门：台词 + 每个队员一个「拜入 XX」（读 sect_id，按种族筛，规则来自 Global.SECTS）。
enum Action {
	AUTO,
	TALK,
	TELEPORT,
	RECRUIT_PARTY,
	SELL_WEAPONS,
	JOIN_SECT,
}

## 交互类型。AUTO 由 WorldMap.resolve_action() 解析成具体类型。
@export var action: Action = Action.AUTO

## RECRUIT_PARTY 专用：可招募的队友（UnitStats）。留空 = 自动扫描 Global.RECRUIT_DIR 下所有 UnitStats。
## ⚠ 导出（打包）后文本资源可能被转成 .res，扫描依赖 PCK 文件索引；要绝对稳妥就把候选逐个拖进来（显式列表优先）。
@export var recruit_pool: Array[UnitStats] = []

## RECRUIT_PARTY 专用：招募按钮的动词前缀，最终文字形如「加入 Knight」。
@export var recruit_label := "加入"

## SELL_WEAPONS 专用：这个商人卖哪些装备。留空 = 自动用 Global.get_all_equipment()（扫 equipment 目录，当前 26 件）。
## 想只卖几件就把这几件逐个拖进来（显式列表优先）。类型是 ItemBase，以后丹药/卷轴也能上架。
@export var sell_pool: Array[ItemBase] = []

## SELL_WEAPONS 专用：购买按钮的动词前缀，最终文字形如「购买  12 金币」。
@export var shop_label := "购买"

## SELL_WEAPONS 专用：只上架这几类装备（ItemBase.EquipType 成员值）。
## 留空 = 全上架（保持旧行为）。武器商填 [WEAPON]，防具商填 [ARMOR, HELMET, BOOTS]，
## 首饰商填 [NECKLACE, BELT] —— 这样同一套装备表能拆成三家店。
@export var sell_types: Array[int] = []

## JOIN_SECT 专用：这个掌门代表哪个门派（Global.SECTS 的键：taixu / piaomiao / zixiao / wanyao / xingluo）。
## 留空 = 没有门派可拜（面板会提示"没有这个门派"）。用字符串 id 而不是门派对象，是为了让地图只依赖一个稳定的键。
@export var sect_id: String = ""
