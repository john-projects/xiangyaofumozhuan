extends Node2D
class_name FloatingText
## Fixed-size feedback: quick pop, readable hold, then fade.
@onready var value_label: Label = $ValueLabel

func setup(value: String, color: Color, is_critical: bool = false) -> void:
	var is_damage := value.is_valid_int() and not value.begins_with("+")
	if is_damage:
		var settings := value_label.label_settings.duplicate() as LabelSettings
		settings.font_size = 64
		settings.outline_size = 18
		value_label.label_settings = settings
	value_label.text = value
	modulate = color
	scale = Vector2.ZERO
	rotation = 0.0
	var resting_scale := 1.15 if is_damage and is_critical else 1.0
	var pop_time := 0.10 if is_damage else 0.22
	var tween := create_tween()
	tween.tween_property(self, "scale", Vector2.ONE * resting_scale * 1.08, pop_time)
	tween.parallel().tween_property(self, "global_position", global_position + Vector2.UP * 18.0, pop_time)
	tween.tween_property(self, "scale", Vector2.ONE * resting_scale, 0.12)
	tween.tween_interval(0.48 if is_damage else 0.38)
	tween.tween_property(self, "modulate:a", 0.0, 0.23)
	await tween.finished
	queue_free()