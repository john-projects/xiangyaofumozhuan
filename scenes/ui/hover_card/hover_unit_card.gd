extends Panel
class_name HoverUnitCard

@export var unit: UnitStats: set = _set_unit

@onready var item_icon: TextureRect = %ItemIcon
@onready var item_name: Label = %ItemName
@onready var item_type: Label = %ItemType
@onready var item_desc: RichTextLabel = %ItemDesc


func _set_unit(value: UnitStats) -> void:
	unit = value
	item_icon.texture = value.icon
	item_name.text = value.name
	item_desc.text = "[code]Health: [color=green]%s[/color]
Damage: [color=green]%s[/color]
Speed: [color=green]%s[/color]
Luck: [color=green]%s[/color]
Block Chance: [color=green]%s%%[/color][/code]" % [value.health, value.damage, value.speed, value.luck, value.block_chance]
