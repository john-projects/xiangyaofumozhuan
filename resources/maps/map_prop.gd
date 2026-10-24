## MapProp —— 地图上的一个"物件"（房子/树/桥/摊位…），供 MapData.props 使用。
##
## 为什么用它：不再把整张地图烤成一张图，而是"地表图 + 一堆可复用物件"。
## 位置用**归一化坐标**（和 spawn_point / NPC 一样），锚点是物件的**接地点**（脚底/落地处），
## 运行时按 `position.y` 生成 z_index，于是"人走到房子后面被挡住、走到前面挡住房子"自动成立。
extends Resource
class_name MapProp

## 物件贴图。建议 PNG 带透明通道，尺寸按 2:1 等距视角画。
@export var texture: Texture2D
## 接地点（归一化 0~1，相对地图图片左上角）。不是贴图中心，是"东西踩在地上的那个点"。
@export var position := Vector2(0.5, 0.5)
## 缩放（1.0 = 原图像素）。世界坐标 = 图片像素 × map_scale，所以这里一般填 1.0 即可。
@export var scale := 1.0
@export var flip_h := false
## 排序微调：有的物件视觉上应该"更靠后/更靠前"，用它加减几十像素。
@export var sort_bias := 0.0
