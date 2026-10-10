extends Resource
class_name MapNPC

## 地图上的固定 NPC：负责对话 + 传送
##
## position 是归一化坐标（0~1，相对地图图片），运行时换算成世界坐标。
## destinations 里填"这个 NPC 能把玩家送去哪几张图"（填地图 id），
## 双向传送就是两边地图的 NPC 互相把对方写进 destinations。

@export var id: String = ""
@export var display_name: String = "路人"
@export var texture: Texture2D                       # 留空会用一块方形色块占位
@export var position := Vector2(0.5, 0.5)            # 归一化，相对地图图片
@export var dialogue: String = "……"
@export var destinations: Array[String] = []          # 目标地图 id 列表
@export var teleport_label := "我想去"                # 传送按钮的措辞，例如"出海前往"
