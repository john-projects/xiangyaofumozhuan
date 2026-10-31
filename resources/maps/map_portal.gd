extends Resource
class_name MapPortal
## 地面传送光圈：玩家走进范围内就切到目标地图。
##
## 坐标口径和 MapNPC / spawn_point 一致 —— 归一化 0~1，相对地图图片左上角，
## 所以调位置的方式也一样：游戏里把鼠标移到目标处按 F1，抄控制台打印的值。
##
## 和 NPC 传送的区别：NPC 要对话、点按钮；光圈是**踩上去就走**，适合放在
## 地图边缘、路口、洞口这类"往外走"的地方。

## 唯一 id，仅用于调试定位（不参与逻辑）。
@export var id := ""
## 光圈中心（归一化 0~1）。
@export var position := Vector2(0.5, 0.5)
## 目标地图 id（MapData.id）。
@export var target_map_id := ""
## 显示名（提示与名字牌用），留空则回落到目标地图的 display_name。
@export var label := ""
## 触发半径（世界像素）。踩到圆心这个距离内就传送。
@export var radius := 105.0
