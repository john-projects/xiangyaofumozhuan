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

@export var id: String = ""
@export var display_name: String = ""
@export var texture: Texture2D

## 这张图**专用的场景**：在 scenes/world/world_map.tscn 上「新建继承场景」做出来的那个。
## 留空 = 用通用的 scenes/world/world_map.tscn（纯数据驱动，改 .tres 就能调）。
## 填了 = GameRoot 会实例化你的场景，通用逻辑（走动/相机/NPC/传送/战斗入口）仍然继承自基类，
## 你只需要在里面加"这张图才有的东西"：装饰、TileMapLayer 碰撞、机关、触发器……
@export var scene: PackedScene

@export_group("探索")
## 图片放大倍数（世界尺寸 = 图片像素 × map_scale），越大越"走得久"
@export var map_scale := 2.0
## 进入本图时的默认出生点（归一化）
@export var spawn_point := Vector2(0.5, 0.62)

@export_group("NPC")
@export var npcs: Array[MapNPC] = []

@export_group("兜底（npcs 配空时才会用到）")
## 如果 npcs 是空的，就在 exit_center 自动生成一个能去 next_id 的传送 NPC
@export var next_id: String = ""
@export var exit_center := Vector2(0.85, 0.5)

@export_group("战斗")
@export var battle_enabled := true
@export var enemy_pool: Array[UnitStats] = []           # 留空则用 GameRoot.enemy_pool
@export var bgm: AudioStream                            # 留空则不改音乐（以后接）
