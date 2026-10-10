extends Panel
class_name HoverCard

@export var shop_item: ItemBase: set = _set_shop_item

@onready var item_icon: TextureRect = %ItemIcon
@onready var item_name: Label = %ItemName
@onready var item_type: Label = %ItemType
@onready var item_desc: RichTextLabel = %ItemDesc

func _set_shop_item(value: ItemBase) -> void:
	shop_item = value
	item_icon.texture = value.item_icon
	item_name.text = value.item_name
	item_type.text = ItemBase.ItemType.keys()[value.item_type]
	item_desc.text = value.get_description()
	
	var style := Global.get_tier_style(value.item_tier)
	add_theme_stylebox_override("panel", style)
