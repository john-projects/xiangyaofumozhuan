extends HBoxContainer
class_name CharacterArea

## 角色形象区：◀ [形象 + 名字牌] ▶，左右各 3 个装备栏（头盔 / 武器 / 腰带 · 项链 / 衣服 / 鞋子）。
##
## ── 它是干什么的 ──
##   把"背包面板里那块角色区"抽成一个可复用场景，外观**逐像素照搬**（96px 格子、240×308 形象框、
##   同样的稀有度描边和名字牌），于是"角色属性"面板的上半部分和背包看起来是同一套东西。
##   以后背包想复用也可以直接换成它（目前背包还是自己那份，保持不动、零风险）。
##
## ── 数据（只读）──
##   · 形象：UnitStats.icon；
##   · 装备：GameRoot.equipment_in(当前展示的角色, 栏位) —— 每个角色一套，见 Global.equipment_by_character；
##   · 本节点**不写**任何游戏数据：点装备栏只是 emit unequip_requested，
##     真正的"能不能脱 / 脱到哪"由 GameRoot.unequip_slot() 判定（和背包同一个入口）。
##
## ── 键盘 ──
##   只有 ◀ / ▶ 两个按钮进焦点环（focus_ring()）；装备栏是**鼠标专用**：
##   属性面板和背包同屏时，背包那边已经有一份可点击的装备栏，这里再进环会重复。

const EQUIP_SLOTS_PER_SIDE := 3
## 左边从上到下：头盔 / 武器 / 腰带；右边从上到下：项链 / 衣服 / 鞋子（和背包完全一致）。
const EQUIP_LAYOUT: Array[int] = [
	ItemBase.EquipType.HELMET, ItemBase.EquipType.WEAPON, ItemBase.EquipType.BELT,
	ItemBase.EquipType.NECKLACE, ItemBase.EquipType.ARMOR, ItemBase.EquipType.BOOTS,
]
## 装备格边长（和背包的 96px 对齐）。
const EQUIP_SLOT_SIZE := 96.0
## 栏位名标签占的高度（有装备时名字缩到底部）。
const EQUIP_LABEL_HEIGHT := 20.0

## 换了"正在看谁"（点 ◀ / ▶ 时发）。外层面板据此决定要不要同步别的面板 / 重建属性。
signal character_changed(character: UnitStats)
## 点了某个**有装备**的装备栏：请求脱下来。参数是 ItemBase.EquipType 的成员值。
signal unequip_requested(slot_type: int)

@onready var left_slots: VBoxContainer = %LeftSlots
@onready var right_slots: VBoxContainer = %RightSlots
@onready var prev_button: Button = %PrevPlayerButton
@onready var next_button: Button = %NextPlayerButton
@onready var player_view: TextureRect = %PlayerView
@onready var player_fallback: Label = %PlayerFallback
@onready var name_label: Label = %PlayerNameLabel

## 团队名册（外层传进来的引用，只读）与"正在看谁"的下标。
var _party: Array[UnitStats] = []
var _view_index := 0


func _ready() -> void:
	prev_button.pressed.connect(func() -> void: step_player(-1))
	next_button.pressed.connect(func() -> void: step_player(1))
	_build_slots()
	refresh()


## 绑定团队名册并展示（默认展示队长）。
## 参数 members：团队名册（引用语义，只读；**不要叫 party**，会和下面的 party() 撞名）；
##   index：要展示的下标（<0 = 自动找队长）。
func show_party(members: Array[UnitStats], index := -1) -> void:
	_party = members
	if index >= 0:
		_view_index = clampi(index, 0, maxi(0, _party.size() - 1))
	else:
		_view_index = _index_of_leader()
	refresh()


## 当前绑定到的团队名册（只读；◀ / ▶ 在这个数组里翻）。
## 给同屏的面板用：例如属性面板在"这个人还没拜师"时，要提示"队里谁已经拜师了、用 ▶ 切过去"。
func party() -> Array[UnitStats]:
	return _party


## 当前展示的角色（◀ / ▶ 切换的那个）。团队为空时退回主角。
func current_character() -> UnitStats:
	if _view_index >= 0 and _view_index < _party.size():
		var member: UnitStats = _party[_view_index]
		if member != null:
			return member
	return Global.main_player_selected


## 把"正在看谁"切到指定角色（外层在"背包换人了"时调它，保持两边同一个人）。
## 不在名册里就忽略（例如他刚被移出团队）；**不发** character_changed（避免两边来回弹）。
func show_character(character: UnitStats) -> void:
	var index := _index_of(character)
	if index < 0 or index == _view_index:
		return
	_view_index = index
	refresh()


## ◀ / ▶：在名册里前后翻一个（越界回卷），刷新外观并发 character_changed。
func step_player(step: int) -> void:
	if _party.size() <= 1:
		return
	_view_index = wrapi(_view_index + step, 0, _party.size())
	SoundManager.play_sound(SoundManager.Sound.UI)
	refresh()
	character_changed.emit(current_character())


## 按当前角色刷新：形象 / 名字 / 箭头可用状态 / 6 个装备栏。
## 副作用：只改本节点的显示，不碰游戏数据。
func refresh() -> void:
	var character := current_character()
	var icon: Texture2D = character.icon if character != null else null
	player_view.texture = icon
	player_view.visible = icon != null
	player_fallback.visible = icon == null
	player_fallback.text = "（团队里没有人）" if _party.is_empty() else "（未选角色）"
	name_label.text = character.name if character != null else ""
	var switchable := _party.size() > 1
	prev_button.disabled = not switchable
	next_button.disabled = not switchable
	_refresh_slots()


## 可以聚焦的控件（外层设焦点环用）：只有两个切换箭头；单人时为空。
func focus_ring() -> Array[Control]:
	var out: Array[Control] = []
	for button in [prev_button, next_button]:
		if button != null and not button.disabled:
			out.append(button)
	return out


# ══════════════════════════════════════════════════════════
#  六个装备栏
# ══════════════════════════════════════════════════════════

## 造左右两排装备栏（各 EQUIP_SLOTS_PER_SIDE 个）—— 只在 _ready 里造一次。
## 内容不在这里定：换角色/穿脱都走 _refresh_slots() 就地刷新，按钮节点不变
## （和背包同一个理由：避免焦点/事件指向已释放的旧按钮）。
func _build_slots() -> void:
	if left_slots == null or right_slots == null:
		push_warning("CharacterArea：场景里找不到 %LeftSlots / %RightSlots —— 已跳过装备栏")
		return
	var columns: Array[VBoxContainer] = [left_slots, right_slots]
	for col in columns.size():
		var container: VBoxContainer = columns[col]
		for child in container.get_children():
			container.remove_child(child)
			child.queue_free()
		for i in EQUIP_SLOTS_PER_SIDE:
			var layout_index := col * EQUIP_SLOTS_PER_SIDE + i
			var slot_type: int = EQUIP_LAYOUT[layout_index] if layout_index < EQUIP_LAYOUT.size() \
					else ItemBase.EquipType.NONE
			container.add_child(_make_slot(slot_type))


## 造一个装备栏格子的固定部分：尺寸、栏位名、事件接线。
## 事件只接一次，内容由 _refresh_slot() 填。
func _make_slot(slot_type: int) -> Button:
	var slot := Button.new()
	slot.name = "EquipSlot"
	slot.set_meta("slot_type", slot_type)
	slot.custom_minimum_size = Vector2(EQUIP_SLOT_SIZE, EQUIP_SLOT_SIZE)
	slot.expand_icon = true
	slot.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# 装备栏是鼠标专用：不进焦点环（背包那边已经有一份可点的），但悬停仍有属性卡。
	slot.focus_mode = Control.FOCUS_NONE
	var tag := Label.new()
	tag.name = "SlotTypeLabel"
	tag.text = ItemBase.equip_type_name(slot_type)
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tag.add_theme_font_size_override("font_size", 13)
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_set_tag_bottom(tag)
	slot.add_child(tag)
	# 点一下 = 请求脱下（空格子 disabled，点不了）
	slot.pressed.connect(func() -> void: unequip_requested.emit(slot_type))
	# 悬停弹属性卡。⚠ 不能把 item 绑定进来：换角色/换装备后 item 会变，而事件只连一次。
	slot.mouse_entered.connect(func() -> void: _show_tip(slot, slot_type))
	slot.mouse_exited.connect(TooltipManager.hide_tip)
	return slot


## 按当前角色刷新 6 个格子的图标/描边/可用状态。
func _refresh_slots() -> void:
	var character := current_character()
	for container in [left_slots, right_slots]:
		if container == null:
			continue
		for child in container.get_children():
			var slot := child as Button
			if slot != null:
				_refresh_slot(slot, int(slot.get_meta("slot_type", ItemBase.EquipType.NONE)), character)


## 刷新单个格子：这一栏有装备就画图标 + 稀有度描边，没有就画成暗色的"空坑位"。
func _refresh_slot(slot: Button, slot_type: int, character: UnitStats) -> void:
	var tag := slot.get_node_or_null("SlotTypeLabel") as Label
	var bottom_margin := int(EQUIP_LABEL_HEIGHT) + 4
	var item: ItemBase = GameRoot.equipment_in(character, slot_type)
	if item == null:
		slot.icon = null
		slot.disabled = true
		slot.add_theme_stylebox_override("disabled",
				_slot_style(Color(1, 1, 1, 0.14), Color(1, 1, 1, 0.03), bottom_margin))
		if tag != null:
			_set_tag_center(tag)
			tag.modulate = Color(1, 1, 1, 0.42)
		var who: String = character.name if character != null else "角色"
		slot.tooltip_text = "%s栏：%s现在没戴这个" % [ItemBase.equip_type_name(slot_type), who]
		return
	slot.icon = item.item_icon
	slot.disabled = false
	slot.tooltip_text = ""      # 有属性卡就不再设原生 tooltip，免得两个框叠一起
	var tier_color: Color = Global.TIER_COLORS.get(item.item_tier, Color(1, 1, 1, 0.4))
	slot.add_theme_stylebox_override("normal", _slot_style(tier_color, Color(1, 1, 1, 0.07), bottom_margin))
	slot.add_theme_stylebox_override("hover", _slot_style(tier_color, Color(1, 1, 1, 0.18), bottom_margin))
	slot.add_theme_stylebox_override("pressed", _slot_style(Color(1, 0.9, 0.5, 1.0), Color(1, 1, 1, 0.24), bottom_margin))
	if tag != null:
		_set_tag_bottom(tag)
		tag.modulate = Color(1, 1, 1, 0.85)


## 悬停时弹属性卡：**现取**当前角色这一栏的装备（不能提前绑定 item）。
func _show_tip(slot: Control, slot_type: int) -> void:
	var item: ItemBase = GameRoot.equipment_in(current_character(), slot_type)
	if item != null:
		TooltipManager.show_for_control(slot, item)


## 栏位名：缩到格子**底部**（有装备时用，图标画在它上面）。
func _set_tag_bottom(tag: Label) -> void:
	tag.anchor_left = 0.0
	tag.anchor_right = 1.0
	tag.anchor_top = 1.0
	tag.anchor_bottom = 1.0
	tag.offset_left = 2.0
	tag.offset_right = -2.0
	tag.offset_top = -(EQUIP_LABEL_HEIGHT + 2.0)
	tag.offset_bottom = -2.0


## 栏位名：居中铺满格子（空栏位用，像个"坑位"）。
func _set_tag_center(tag: Label) -> void:
	tag.anchor_left = 0.0
	tag.anchor_right = 1.0
	tag.anchor_top = 0.0
	tag.anchor_bottom = 1.0
	tag.offset_left = 2.0
	tag.offset_right = -2.0
	tag.offset_top = 0.0
	tag.offset_bottom = 0.0


## 格子底板样式（和背包的 _slot_style 同一套：2px 细描边 + 半透明底 + 四边 8px 内缩，
## 底部多留一条给栏位名）。装备栏在背包里用的也是这个函数，所以两边看起来完全一致。
func _slot_style(border: Color, bg: Color, bottom_margin: float) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 8
	style.content_margin_bottom = bottom_margin
	return style


## 团队里"当前主角"排第几（打开面板时先展示谁）。找不到就展示第一个人。
func _index_of_leader() -> int:
	var index := _index_of(Global.main_player_selected)
	return maxi(0, index)


## 某个角色在名册里的下标（引用或 resource_path 相同都算同一个人）；找不到返回 -1。
func _index_of(character: UnitStats) -> int:
	if character == null:
		return -1
	for i in _party.size():
		var member: UnitStats = _party[i]
		if member == character:
			return i
		if member != null and not member.resource_path.is_empty() \
				and member.resource_path == character.resource_path:
			return i
	return -1
