extends Node2D
## 骨骼角色 · 武器挂点。
##
## 用法：
##   rig.set_weapon_texture(load("res://assets/.../sword_01.png"))
##   rig.set_weapon("sword_01")          # 走 assets/sprites/equipment/sword/
##   rig.set_weapon(null)                # 收起来
##
## 武器节点 s_weapon 挂在 hand_r 骨头下，所以：
##   · 攻击动画一挥手，武器跟着动，不用额外代码
##   · 握把对齐骨头原点（手腕），剑身朝上

const WEAPON_PATH := "关节/hip/spine/chest/arm_r/fore_r/hand_r/s_weapon"
const WEAPON_DIR := "res://assets/sprites/equipment/"

## 各武器类型对应的贴图目录（和 ItemBase.EquipType / WEAPON_TYPE_NAMES 对得上）
const TYPE_DIRS := {
	"sword": "sword", "blade": "blade", "spear": "spear",
	"staff": "staff", "fan": "fan", "claw": "claw",
}

## 当前武器贴图（null = 空手）
var weapon_texture: Texture2D = null
## design_height() 的缓存
var _design_h := 0.0


func _ready() -> void:
	_refresh()


## 直接给贴图
func set_weapon_texture(tex: Texture2D) -> void:
	weapon_texture = tex
	_refresh()


## 按「武器类型 + 序号」取图，例：set_weapon("sword", 3) → sword_03.png
## 找不到文件时静默隐藏武器，不报错。
func set_weapon(kind: String, index: int = 1) -> void:
	if kind.is_empty():
		set_weapon_texture(null)
		return
	var dir: String = TYPE_DIRS.get(kind, kind)
	var path := "%s%s/%s_%02d.png" % [WEAPON_DIR, dir, dir, index]
	if not ResourceLoader.exists(path):
		push_warning("RigWeapon: 找不到武器贴图 %s" % path)
		set_weapon_texture(null)
		return
	set_weapon_texture(load(path))


## 用装备实例填充（推荐：和 ItemEquipment.icon 对接）
func set_from_equipment(item) -> void:
	# ⚠ 图标在 ItemBase.item_icon 上，不是 item.icon
	if item == null or item.item_icon == null:
		set_weapon_texture(null)
		return
	set_weapon_texture(item.item_icon)


func _refresh() -> void:
	var w := get_node_or_null(WEAPON_PATH) as Sprite2D
	if w == null:
		return
	w.texture = weapon_texture
	w.visible = weapon_texture != null


## 这套拆件拼起来的设计高度（脚底到头顶，像素）。
## world_map / battle_unit 用它把角色缩到游戏里的目标高度。
func design_height() -> float:
	if _design_h > 0.0:
		return _design_h
	var top := 0.0
	var found := false
	for n in find_children("*", "Sprite2D", true, false):
		var sp := n as Sprite2D
		if sp.texture == null:
			continue
		var w := sp.texture.get_width() * sp.scale.x
		var h := sp.texture.get_height() * sp.scale.y
		for p in [Vector2(0, 0), Vector2(w, 0), Vector2(0, h), Vector2(w, h)]:
			var y := sp.to_global(p).y
			if not found or y < top:
				top = y
				found = true
	_design_h = maxf(1.0, -top) if found else 1.0
	return _design_h


## 让 rig 播某条动画（idle/walk/attack/cast）
func play(anim_name: String) -> void:
	var ap := get_node_or_null("AnimationPlayer") as AnimationPlayer
	if ap != null and ap.has_animation(anim_name):
		ap.play(anim_name)

## 把角色放回原点：去掉在编辑器里为方便操作而加的位移。
## 游戏里实例化后必须调一次，否则角色会被推到地图外面。
func reset_to_origin() -> void:
	position = Vector2.ZERO
	var j := get_node_or_null("关节")
	if j != null:
		j.position = Vector2.ZERO
