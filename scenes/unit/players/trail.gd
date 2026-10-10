extends Line2D
class_name Trail

@export var player: Player
@export var trail_length:= 25
@export var trail_duration:= 1.0
var min_distance := 5.0
@onready var trail_timer: Timer = %TrailTimer

var points_array: Array[Vector2] = []
var is_active := false


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	if not is_active:
		return

	var current_pos = player.global_position
		# 如果数组不为空，检查当前位置和上一个记录的点距离够不够远
	if not points_array.is_empty():
		var last_pos = points_array[-1]
		# 如果移动距离太小，直接结束这一帧，不记录点
		if current_pos.distance_to(last_pos) < min_distance:
			return
	points_array.append(player.global_position)
	if points_array.size() > trail_length:
		points_array.pop_front()
	
	points = points_array
	
func start_trail() -> void:
	is_active = true
	clear_points()
	points_array.clear()
	trail_timer.start(trail_duration)

func _on_trail_timer_timeout() -> void:
	is_active = false
	clear_points()
	points_array.clear()
	
