extends Area2D
class_name HitboxComponent

signal on_hit_hurtbox(hurtbox: HurtboxComponent)

var damage := 1.0
var critical := false
var knockback_power := 0.0
var source: Node2D

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.


func enable() -> void:
	set_deferred("monitoring", true)
	set_deferred("monitorable", true)
	
func disable() -> void:
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
	
func setup(new_damage: float, new_critical: bool, new_knockback: float, new_source: Node2D) -> void:
	self.damage = new_damage
	self.critical = new_critical
	knockback_power = new_knockback
	self.source = new_source
	

func _on_area_entered(area: Area2D) -> void:
	if area is HurtboxComponent:
		SoundManager.play_sound(SoundManager.Sound.ENEMY_HIT)
		on_hit_hurtbox.emit(area)
