extends Panel
class_name ShopPanel

signal on_shop_next_wave

const SHOP_CARD_SCENE = preload("uid://ba8e7xllxa8c2")
# 旧方案（本地 hover card）已弃用，改用 TooltipManager；保留备查
# const HOVER_ITEM_CARD_SCENE = preload("uid://sojan35we4eq")

@export var shop_items: Array[ItemBase]

@onready var items_container: HBoxContainer = %ItemsContainer
@onready var passives_container: GridContainer = %PassivesContainer
@onready var weapons_container: GridContainer = %WeaponsContainer
@onready var combine_button: Button = %CombineButton

var context_card: ItemCard
# 旧方案
# var hover_item_card: HoverItemCard

func _ready() -> void:
	for child in passives_container.get_children(): child.queue_free()
	for child in weapons_container.get_children(): child.queue_free()

	# 旧方案：本地创建一张提示卡，自己跟随鼠标
	# hover_item_card = HOVER_ITEM_CARD_SCENE.instantiate()
	# add_child(hover_item_card)
	# hover_item_card.hide()


# ──────────────────────────────────────────────────────────────
#  新方案：悬停提示统一交给 TooltipManager（autoload，独立 CanvasLayer）
#  卡片在"创建时"各自接好信号，所以不需要事后遍历容器
# ──────────────────────────────────────────────────────────────

func _on_shop_card_hover_started(card: ShopCard) -> void:
	if card.shop_item == null:
		return
	TooltipManager.show_for_control(card, card.shop_item)


func _on_item_card_hover_started(card: ItemCard) -> void:
	if card.item == null:
		return
	TooltipManager.show_for_control(card, card.item)


func _on_card_hover_ended() -> void:
	TooltipManager.hide_tip()


# ──────────────────────────────────────────────────────────────
#  旧方案（本地 hover card，已弃用）——保留备查，不再生效
# ──────────────────────────────────────────────────────────────
# func _process(delta: float) -> void:
# 	if hover_item_card.visible:
# 			_follow_mouse()
#
# func _follow_mouse() -> void:
# 	var vp := get_viewport().get_visible_rect().size
# 	var pos := get_local_mouse_position() + Vector2(16, 16)      # 相对 ShopPanel 的局部坐标
# 	pos.x = min(pos.x, vp.x - hover_item_card.size.x - 8)              # 别跑出屏幕
# 	pos.y = min(pos.y, vp.y - hover_item_card.size.y - 8)
# 	hover_item_card.position = pos
#
# func _on_shop_card_hover_started(weapon: ItemWeapon) -> void:
# 	if weapon == null:
# 		return
# 	hover_item_card.item = weapon
# 	hover_item_card.show()
# 	_follow_mouse()
#
# func _on_card_hover_ended() -> void:
# 	hover_item_card.hide()


# ──────────────────────────────────────────────────────────────

func load_shop(current_wave: int) -> void:
	for child in items_container.get_children(): child.queue_free()
	
	var config := Global.SHOP_PROBABILITY_CONFIG
	var selected_items := Global.select_items_for_offer(shop_items, current_wave, config)
	for shop_item: ItemBase in selected_items:
		var card_instance := SHOP_CARD_SCENE.instantiate() as ShopCard
		card_instance.on_item_purchased.connect(_on_item_purchased)
		card_instance.mouse_entered.connect(_on_shop_card_hover_started.bind(card_instance))
		card_instance.mouse_exited.connect(_on_card_hover_ended)
		items_container.add_child(card_instance)
		card_instance.shop_item = shop_item
	
	# 旧方案：事后遍历容器去接信号（错的，遍历的是节点不是数组）
	# for weapon: ItemWeapon in weapons_container:
	# 	hover_item_card.mouse_entered.connect(_on_shop_card_hover_started.bind(weapon))
	# 	hover_item_card.mouse_exited.connect(_on_card_hover_ended)


func create_item_card() -> ItemCard:
	var item_card := Global.ITEM_CARD_SCENE.instantiate() as ItemCard
	item_card.on_item_card_selected.connect(_on_item_card_selected)
	# ItemCard 全部经过这里创建（购买/合成/初始武器），一处接好就够了
	item_card.mouse_entered.connect(_on_item_card_hover_started.bind(item_card))
	item_card.mouse_exited.connect(_on_card_hover_ended)
	return item_card


func create_item_weapon(weapon: ItemWeapon) -> void:
	var card := create_item_card()
	weapons_container.add_child(card)
	card.item = weapon


func _on_next_wave_button_pressed() -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	on_shop_next_wave.emit()


func _on_item_purchased(item: ItemBase) -> void:
	var item_card := create_item_card()
	
	if item.item_type == ItemBase.ItemType.WEAPON:
		weapons_container.add_child(item_card)
		var weapon := item as ItemWeapon
		Global.player.add_weapon(weapon)
		Global.equipped_weapons.append(weapon)
		
	elif item.item_type == ItemBase.ItemType.PASSIVE:
		passives_container.add_child(item_card)
		var passive := item as ItemPassive
		passive.apply_passive()
		
	item_card.item = item


func _on_item_card_selected(card: ItemCard) -> void:
	context_card = card
	var can_merge := false
	if card.item.item_type == ItemBase.ItemType.WEAPON:
		var count := 0
		for weapon: ItemWeapon in Global.equipped_weapons:
			if weapon.item_name == card.item.item_name:
				count += 1
		if count >= 2:
			can_merge = true
		
	combine_button.disabled = not can_merge


func _on_combine_button_pressed() -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	if not context_card:
		return
		
	var clicked_weapon := context_card.item as ItemWeapon
	if not clicked_weapon.upgrade_to:
		return
	
	var weapons_to_remove: Array[Weapon] = Global.player.current_weapons.filter(func(w: Weapon):
		return w.data.item_name == clicked_weapon.item_name).slice(0, 2)
		
	var card_to_remove = weapons_container.get_children().filter(func(c: ItemCard):
		return c.item.item_name == clicked_weapon.item_name).slice(0, 2)
	
	if weapons_to_remove.size() < 2 or card_to_remove.size() < 2:
		return
	
	for weapon: Weapon in weapons_to_remove:
		Global.player.current_weapons.erase(weapon)
		Global.equipped_weapons.erase(weapon.data)
		weapon.queue_free()
		
	for card: ItemCard in card_to_remove:
		card.queue_free()
	
	var upgraded_weapon: ItemWeapon = load(clicked_weapon.upgrade_to.resource_path)
	Global.player.add_weapon(upgraded_weapon)
	Global.equipped_weapons.append(upgraded_weapon)
	
	var new_card := create_item_card()
	weapons_container.add_child(new_card)
	new_card.item = upgraded_weapon

	context_card = null


func _on_sell_button_pressed() -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	if not context_card:
		return
	var clicked_weapon := context_card.item as ItemWeapon
	var coins := int(clicked_weapon.item_cost * 0.75)
	var weapon_to_remove: Weapon = Global.player.current_weapons.filter(func(w: Weapon): 
		return w.data.item_name == clicked_weapon.item_name).front() as Weapon

	if weapon_to_remove:
		Global.player.current_weapons.erase(weapon_to_remove)
		Global.equipped_weapons.erase(weapon_to_remove.data)
		weapon_to_remove.queue_free()
	
	context_card.queue_free()
	context_card = null
	Global.coins += coins
