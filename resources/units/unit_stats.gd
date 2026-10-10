extends Resource
class_name UnitStats

enum UnitType {
	PLAYER,
	ENEMY
}

@export var name: String
@export var type: UnitType
@export var icon: Texture2D
@export var health:= 1.0
@export var health_increase_per_wave:= 1.0
@export var damage:= 1.0
@export var damage_increase_per_wave:= 1.0
@export var speed:= 300
@export var luck:= 1.0
@export var block_chance:= 0.0
@export var gold_drop:= 1
@export var hp_regen := 0.0
@export var life_steal := 0.0
@export var harvesting := 0.0

## 蓝量：技能消耗（没填的 .tres 用这个默认值，不会报错）
@export var mana := 20.0
## 这个单位会的技能；留空的话，我方单位会用 Battle.default_skills（方便先跑通再逐个配）
@export var skills: Array[SkillData] = []
