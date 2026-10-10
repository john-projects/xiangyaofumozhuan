extends Node2D
class_name WorldNPC

## 地图上的 NPC：显示立绘/名字，玩家靠近时高亮提示可以交谈
## 位置与行为由 WorldMap 决定（WorldMap 负责距离判定和交互）

const HIGHLIGHT_SCALE := 1.1

var data: MapNPC

@onready var sprite: Sprite2D = %Sprite
@onready var fallback: Polygon2D = %Fallback
@onready var name_label: Label = %NameLabel
@onready var mark: Label = %Mark


func setup(p_data: MapNPC) -> void:
	data = p_data
	if data.texture != null:
		sprite.texture = data.texture
		fallback.visible = false
	else:
		fallback.visible = true
	name_label.text = data.display_name
	set_highlight(false)


func set_highlight(value: bool) -> void:
	mark.visible = value
	var tween := create_tween()
	tween.tween_property(self, "scale", Vector2.ONE * (HIGHLIGHT_SCALE if value else 1.0), 0.1)
