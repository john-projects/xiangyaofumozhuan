extends Panel
class_name SelectionPanel

signal on_selection_completed

@export var players: Array[UnitStats]
@export var start_weapons: Array[ItemWeapon]

# 旧方案（本地 hover card）已弃用，改用 TooltipManager；
# 这两张卡片的场景引用现在写在 tooltip_manager.gd 的登记区里
# const HOVER_UNIT_CARD_SCENE = preload("uid://bd5xd4lh1yhed")
# const HOVER_ITEM_CARD_SCENE = preload("uid://sojan35we4eq")

@onready var player_icon: TextureRect = %PlayerIcon
@onready var player_name: Label = %PlayerName
@onready var player_title: Label = %PlayerTitle
@onready var player_description: RichTextLabel = %PlayerDescription

@onready var player_container: HBoxContainer = %PlayerContainer
@onready var weapon_container: HBoxContainer = %WeaponContainer

# 旧方案
# var hover_unit_card: HoverUnitCard          # ← 和 player_container 那些放一起
# var hover_item_card: HoverItemCard          # ← 和 player_container 那些放一起

func _ready() -> void:
	for child in player_container.get_children(): child.queue_free()
	for child in weapon_container.get_children(): child.queue_free()
	
	# 旧方案：本地创建两张提示卡（必须先进树再赋值，否则 @onready 全是 null）
	# hover_unit_card = HOVER_UNIT_CARD_SCENE.instantiate()
	# add_child(hover_unit_card)              # ★ 关键：先进树，@onready 才有值
	# hover_unit_card.hide()
	# 
	# hover_item_card = HOVER_ITEM_CARD_SCENE.instantiate()
	# add_child(hover_item_card)              # ★ 关键：先进树，@onready 才有值
	# hover_item_card.hide()
	
	show_player_info(false)
	load_players()
	load_weapons()

func load_players() -> void:
	if players.is_empty():
		return
	for player: UnitStats in players:
		var card: SelectionCard = Global.SELECTION_CARD_SCENE.instantiate()
		card.pressed.connect(_on_player_selected.bind(player))
		player_container.add_child(card)
		card.set_icon(player.icon)
		
		# 绑定(数据, 卡片)：卡片当锚点，数据在回调里现取
		#card.mouse_entered.connect(_on_selection_unit_card_mouse_entered.bind(player, card))
		card.mouse_entered.connect(TooltipManager.show_for_control.bind(card, player))
		card.mouse_exited.connect(TooltipManager.hide_tip)
		
		
func load_weapons() -> void:
	if start_weapons.is_empty():
		return
	for weapon: ItemWeapon in start_weapons:
		var card: SelectionCard = Global.SELECTION_CARD_SCENE.instantiate()
		card.pressed.connect(_on_weapon_selected.bind(weapon))
		weapon_container.add_child(card)
		card.icon = weapon.item_icon
		
		#card.mouse_entered.connect(_on_selection_item_card_mouse_entered.bind(weapon, card))
		card.mouse_entered.connect(TooltipManager.show_for_control.bind(card, weapon))
		card.mouse_exited.connect(TooltipManager.hide_tip)


func show_player_info(value: bool) -> void:
	player_icon.visible = value
	player_name.visible = value
	player_title.visible = value
	player_description.visible = value
	

func _on_player_selected(player: UnitStats) -> void:
	Global.main_player_selected = player
	show_player_info(true)
	
	player_icon.texture = player.icon
	player_name.text = player.name
	player_description.text = "[code]Health: [color=green]%s[/color]
Damage: [color=green]%s[/color]
Speed: [color=green]%s[/color]
Luck: [color=green]%s[/color]
Block Chance: [color=green]%s%%[/color][/code]" % [player.health, player.damage, player.speed, player.luck, player.block_chance]


# ──────────────────────────────────────────────────────────────
#  新方案：悬停提示统一交给 TooltipManager（autoload，独立 CanvasLayer）
# ──────────────────────────────────────────────────────────────

func _on_selection_unit_card_mouse_entered(unit: UnitStats, card: SelectionCard) -> void:
	if unit == null:
		return
	TooltipManager.show_for_control(card, unit)

func _on_selection_item_card_mouse_entered(item: ItemWeapon, card: SelectionCard) -> void:
	if item == null:
		return
	TooltipManager.show_for_control(card, item)

func _on_selection_card_mouse_exited() -> void:
	TooltipManager.hide_tip()


# ──────────────────────────────────────────────────────────────
#  旧方案（本地 hover card，已弃用）——保留备查，不再生效
# ──────────────────────────────────────────────────────────────
# func _on_selection_unit_card_mouse_entered(unit: UnitStats) -> void:
# 	hover_unit_card.unit = unit
# 	hover_unit_card.global_position = get_local_mouse_position()
# 	hover_unit_card.show()
# 
# func _on_selection_unit_card_mouse_exited() -> void:
# 	hover_unit_card.hide()
# 
# 
# func _on_selection_item_card_mouse_entered(item: ItemWeapon) -> void:
# 	hover_item_card.item = item
# 	hover_item_card.global_position = get_local_mouse_position()
# 	hover_item_card.show()
# 
# func _on_selection_item_card_mouse_exited() -> void:
# 	hover_item_card.hide()


func _on_weapon_selected(weapon: ItemWeapon) -> void:
	Global.main_weapon_selected = weapon


func _on_continue_button_pressed() -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	if not Global.main_player_selected or not Global.main_weapon_selected:
		return
	on_selection_completed.emit()
	hide()
