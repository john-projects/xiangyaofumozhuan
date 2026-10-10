extends Panel
class_name HoverItemCard

# 旧：@export var item: ItemWeapon: set = _set_item
# 类型放宽到 ItemBase，这样武器和被动道具能共用同一张提示卡
@export var item: ItemBase: set = _set_item

@onready var item_icon: TextureRect = %ItemIcon
@onready var item_name: Label = %ItemName
@onready var item_type: Label = %ItemType
@onready var item_desc: RichTextLabel = %ItemDesc

# 旧：func _set_item(value: ItemWeapon) -> void:
func _set_item(value: ItemBase) -> void:
	item = value
	if value == null:
		return
	item_icon.texture = value.item_icon
	item_name.text = value.item_name
	item_type.text = ItemBase.ItemType.keys()[value.item_type]
	item_desc.text = value.get_description()
	
	var style := Global.get_tier_style(value.item_tier)
	add_theme_stylebox_override("panel", style)
