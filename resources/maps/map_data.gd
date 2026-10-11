extends Resource
class_name MapData

## 一张地图的配置（resources/maps/*.tres）
##
## 探索玩法：
##   · 地图图片按 map_scale 等比放大成世界（2048×1152 × 2 = 4096×2304），相机跟着玩家走
##   · 所有位置（spawn_point / NPC.position）都是「相对地图图片的归一化坐标」0~1
##     换算公式：world = normalized * (图片尺寸 * map_scale)
##   · 传送靠跟 NPC 对话，不做地图上的点击热点
##
## 调坐标的小技巧：运行游戏进地图后，把鼠标移到目标位置，按 F1，
## 控制台会打印该点的归一化坐标，填进 spawn_point / NPC.position 即可。
##
## ── 在系统里的位置 ──
##   纯数据 Resource：GameRoot（scenes/main/main.gd）的 @export maps 数组持有全游戏的地图清单，
##   current_map_id 指向当前这张。运行时它被交给 WorldMap.setup(map, party, coins, ...)，
##   WorldMap 才是真正读这些字段干活的人（摆图、放 NPC、算出生点）。
##   本文件只是"配置表的形状"，没有一行逻辑 —— 改字段名/含义会连带影响 WorldMap、MapScreen、GameRoot。
##
## ── 数据流向 ──
##   resources/maps/*.tres（本 Resource）
##     → GameRoot.maps → GameRoot.get_map(id) → WorldMap.setup()（走动探索）
##     → 点「进入战斗」→ GameRoot 用 enemy_pool 组队伍 → Battle.start_battle()
##     → 点 NPC 传送 → travel_requested(map_id) → GameRoot 换到下一张 MapData
##
## ── 地图串联约定 ──
##   next_id 串成一条线（建邺城 → 东海湾 → 傲来国 → 花果山），最后一张留空表示终点。
##   npcs 里手动配好双向传送时，next_id 这条"兜底链"就不生效（见下方 @export_group"兜底"）。

## 地图唯一 id，被 MapData.next_id、MapNPC.destinations、GameRoot.current_map_id
## 以及存档字段共同引用 —— 一改就必须把引用它的 .tres 全部同步改掉，否则传送会找不到图。
@export var id: String = ""
## 界面上显示的地图名（地图标题、传送按钮后缀）。默认空串 = 忘了填，
## 会在 UI 上显示成空白，所以每张 .tres 都要写。
@export var display_name: String = ""
## 地图底图。它是整张地图的坐标系基准：世界尺寸 = 本图纹理像素尺寸 × map_scale，
## 所有归一化坐标都乘以这个尺寸换算成世界坐标，所以换图 = 换坐标系，NPC 配置要重新对。
@export var texture: Texture2D

## 这张图**专用的场景**：在 scenes/world/world_map.tscn 上「新建继承场景」做出来的那个。
## 留空 = 用通用的 scenes/world/world_map.tscn（纯数据驱动，改 .tres 就能调）。
## 填了 = GameRoot 会实例化你的场景，通用逻辑（走动/相机/NPC/传送/战斗入口）仍然继承自基类，
## 你只需要在里面加"这张图才有的东西"：装饰、TileMapLayer 碰撞、机关、触发器……
##
## ⚠ 两种模式的数据来源不同：
##   留空时 WorldMap 直接用**本 Resource 的字段**（texture / map_scale / npcs / spawn_point）驱动一切；
##   填了自定义场景时，实例化的那份场景里可能已经把 texture 等字段固化在节点上，
##   这时改本 .tres 的字段未必生效 —— 调试时要先确认自己走的是哪条路径。
@export var scene: PackedScene

# ────────────────────────────── 探索（WorldMap 走动用） ──────────────────────────────
@export_group("探索")
## 图片放大倍数（世界尺寸 = 图片像素 × map_scale），越大越"走得久"。
## 默认 2.0：2048×1152 的图会变成 4096×2304 的世界，配合 WorldMap.move_speed = 380 px/s
## 大概要走十几秒才能横穿，节奏不至于"一秒走完全图"。填 1.0 就是图片原始尺寸。
@export var map_scale := 2.0
## 进入本图时的默认出生点（归一化）
## 归一化坐标（0~1，相对地图图片左上角）。
## 默认 (0.5, 0.62)：水平居中、略偏下，像一个"站在画面中下方"的常规入场位置。
## 注意：从 A 图走到 B 图时，WorldMap 会优先把玩家放在 B 图里"指向 A 的那个 NPC"旁边，
## 只有找不到这种 NPC 时才用本字段（所以它能起作用的场景比看上去少）。
@export var spawn_point := Vector2(0.5, 0.62)

# ────────────────────────────── NPC ──────────────────────────────
@export_group("NPC")
## 本图上的固定 NPC 列表（元素类型是 MapNPC，是子资源）。
## 留空则走下面的"兜底"逻辑。类型标成 Array[MapNPC]（GDScript 里 Array[T] 只能跟在冒号后做类型，
## 写成 `= Array[MapNPC]` 会解析报错）；数组本身是空的，不是 null，所以可以直接 is_empty() 判断。
@export var npcs: Array[MapNPC] = []

# ───────────────── 兜底（npcs 配空时才会用到） ─────────────────
@export_group("兜底（npcs 配空时才会用到）")
## 如果 npcs 是空的，就在 exit_center 自动生成一个能去 next_id 的传送 NPC。
## 用途：新图还没配 NPC 时也能一路走到终点，先跑通流程再补美术与对话。留空 = 本图是终点。
@export var next_id: String = ""
## 兜底 NPC 的归一化位置。默认 (0.85, 0.5)：靠右侧、垂直居中，
## 像一个"地图右边的出口"，不会挡住中间的玩家出生点。
@export var exit_center := Vector2(0.85, 0.5)

# ────────────────────────────── 战斗 ──────────────────────────────
@export_group("战斗")
## 本图是否允许进入战斗（WorldMap 的「进入战斗」按钮据此启用/隐藏）。
## 默认 true：绝大多数图都要打；把它关掉就能做纯剧情/城镇图。
@export var battle_enabled := true
## 本图专用的敌人图鉴（元素是 UnitStats）。留空 = 用 GameRoot.enemy_pool 这个全局池。
## ⚠ 注意 GameRoot._make_enemy_team() 拿到池子里的 UnitStats 后是 duplicate() 出去再按地图序号
## 加成的，所以在这里的 .tres 上改数值不会在运行时被就地改坏；但 Spawner.enemy_collection
## 那条路径是**就地修改**共享 Resource 的，两边语义不同，别混着理解。
@export var enemy_pool: Array[UnitStats] = []           # 留空则用 GameRoot.enemy_pool
## 进入本图时切换的背景音乐。留空 = 不改音乐（保持上一张图的 BGM），
## 目前是预留字段，GameRoot 的过场演出还没接上。
@export var bgm: AudioStream                            # 留空则不改音乐（以后接）
