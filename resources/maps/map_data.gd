## MapData —— 一张地图的配置（resources/maps/*.tres）
##
## 探索玩法：地图图片按 map_scale 等比放大成世界（2048×1152 × 2 = 4096×2304），相机跟着玩家走；
## 所有位置（spawn_point / NPC.position）都是「相对地图图片的归一化坐标」0~1：world = normalized * (图片尺寸 * map_scale)。
## 传送靠跟 NPC 对话，不做地图上的点击热点。调坐标：运行游戏把鼠标移到目标处按 F1，控制台会打印归一化坐标。
## 位置：GameRoot.maps 持有全游戏的地图清单，current_map_id 指向当前这张；运行时交给 WorldMap.setup() 读。
## 串联：next_id 串成一条线（建邺城 → 东海湾 → 傲来国 → 花果山），最后一张留空表示终点；
##   npcs 里配好双向传送时，next_id 这条"兜底链"就不生效。
extends Resource
class_name MapData

## 地图唯一 id，被 MapData.next_id、MapNPC.destinations、GameRoot.current_map_id 和存档字段共同引用；
## 一改就必须把所有引用它的 .tres 同步改掉，否则传送会找不到图。
@export var id: String = ""
## 界面上显示的地图名（地图标题、传送按钮后缀）。默认空串 = 忘了填，会在 UI 上显示成空白。
@export var display_name: String = ""
## 地图底图。它是整张地图的坐标系基准：世界尺寸 = 本图纹理像素尺寸 × map_scale，换图 = 换坐标系。
@export var texture: Texture2D

## 这张图**专用的场景**（在 world_map.tscn 上「新建继承场景」做出来的）。留空 = 用通用 scenes/world/world_map.tscn。
## 填了 = GameRoot 实例化你的场景，走动/相机/NPC/传送/战斗入口仍继承基类，你只加"这张图才有的东西"。
## ⚠ 两种模式数据来源不同：留空时 WorldMap 直接读本 Resource 的字段；填了时改 .tres 字段未必生效。
@export var scene: PackedScene

@export_group("探索")
## 图片放大倍数（世界尺寸 = 图片像素 × map_scale）。
## ⚠ 清晰度公式：屏幕上一个贴图像素被放大的倍数 = window/stretch/scale（0.8）× map_scale。
##   要 1:1 不糊就让它 ≈ 1.0（现在 0.8×1.25 = 1.0）；填 2.0 就是 1.6 倍放大、明显发虚。
##   另外世界宽必须 ≥ 逻辑画布宽（1680/0.8 = 2100），否则地图盖不满屏幕。
@export var map_scale := 1.25
## 角色在这张图上的显示高度（世界像素）。底图画得越大，这里要按比例调大，否则人物会显得很小。
## 195 = 老底图（1448×1086、map_scale 1.5）的基准；4350×3263 这类大图按 1.5~1.7 倍给（290~330）。
@export var unit_height := 195.0
## 进入本图时的默认出生点（归一化 0~1，相对地图图片左上角）。默认 (0.5, 0.62)：水平居中、略偏下。
## ⚠ 从 A 图走到 B 图时，优先放在 B 图里"指向 A 的那个 NPC"旁边，只有找不到这种 NPC 才用本字段。
@export var spawn_point := Vector2(0.5, 0.62)

@export_group("图层（地表 + 物件）")
## 物件层：房子/树/桥/摊位等独立 PNG，按接地点做 y 排序（走到后面会被挡、走到前面挡住它）。
## 配了它就不要再把同样的东西画进 texture 里，否则会出现"双层房子"。
@export var props: Array[MapProp] = []
## 可行走掩膜：白(255)=可走、黑(0)=阻挡，尺寸必须和 texture 一样（mapgen.py 会生成）。
## 留空 = 整张图都能走（老地图保持原行为）。
@export var walk_mask: Texture2D

@export_group("NPC")
## 本图上的固定 NPC 列表（元素类型是 MapNPC，子资源）。留空则走下面的"兜底"逻辑。
@export var npcs: Array[MapNPC] = []

@export_group("兜底（npcs 配空时才会用到）")
## 如果 npcs 是空的，就在 exit_center 自动生成一个能去 next_id 的传送 NPC。留空 = 本图是终点。
@export var next_id: String = ""
## 兜底 NPC 的归一化位置。默认 (0.85, 0.5)：靠右侧、垂直居中，像一个"地图右边的出口"，不挡出生点。
@export var exit_center := Vector2(0.85, 0.5)

@export_group("战斗")
## 本图是否允许进入战斗（WorldMap 的「进入战斗」按钮据此启用/隐藏）；关掉就能做纯剧情/城镇图。
@export var battle_enabled := true
## 本图专用的敌人图鉴（元素是 UnitStats）。留空 = 用 GameRoot.enemy_pool 这个全局池。
## ⚠ GameRoot._make_enemy_team() 是 duplicate() 出去再按地图序号加成；Spawner.enemy_collection 那条路径是
##   就地修改共享 Resource 的，两边语义不同，别混着理解。
@export var enemy_pool: Array[UnitStats] = []
## 进入本图时切换的背景音乐。留空 = 不改音乐（保持上一张图的 BGM）；目前是预留字段，GameRoot 还没接上。
@export var bgm: AudioStream
