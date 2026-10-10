extends Button
class_name ItemCard

signal on_item_card_selected(card: ItemCard)
signal on_item_card_hover(card: ItemCard)

@export var item: ItemBase: set = _set_item
@onready var item_icon: TextureRect = $ItemIcon


func _set_item(value: ItemBase) -> void:
	item = value
	item_icon.texture = item.item_icon

	var style := Global.get_tier_style(item.item_tier)
	add_theme_stylebox_override("normal", style)

func _on_pressed() -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	if item.item_type == ItemBase.ItemType.WEAPON:
		on_item_card_selected.emit(self)

func _on_mouse_entered() -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	on_item_card_hover.emit(self)
