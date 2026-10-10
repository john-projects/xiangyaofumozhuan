extends ItemBase
class_name ItemWeapon

enum WeaponType {
	MELEE,
	RANGE
}

@export var type:WeaponType
@export var scene: PackedScene
@export var stats: WeaponStats
@export var upgrade_to: ItemWeapon
 
func get_description() -> String:
	return "[code]Damage: [color=green]%s[/color]
Cooldown: [color=green]%s[/color]
Range: [color=green]%s[/color]
Critical: [color=green]%s%%[/color]
[/code]" % [stats.damage, stats.cooldown, stats.max_range, stats.crit_chance * 100]
