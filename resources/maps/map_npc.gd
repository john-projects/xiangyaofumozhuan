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
