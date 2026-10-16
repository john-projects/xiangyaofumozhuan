## ═══════════════════════════════════════════════════════════════════════════
## StatsContainer —— 右侧/下侧那块"角色属性一览"面板（八项数值）
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   纯展示型 UI，被两个面板复用为子场景：
##     · shop_panel.tscn（商店里看属性，买完被动能立刻看到变化）
##     · upgrade_panel.tscn（每波结算的升级界面同样带一块）
##   两者都只是 `instance=ExtResource(...)` 引用同一个 stats_container.tscn，脚本也同一份。
##
## 数据流（每帧轮询，单向读取）：
##   Global.player（Player 节点）→ 它的 stats（UnitStats 资源）
##     → _process() 每帧把 8 个字段写进 8 个 %XxxLabel
##   写入方是别处：升级卡（ItemUpgrade.apply_upgrade）、被动道具（ItemPassive.apply_passive）、
##   商店买卖与波次结算（Global.add_harvesting_coins 等）都在改那份 UnitStats。
##   本文件**只读**，一行都不写属性值。
##
## 为什么用 _process 而不是信号：UnitStats 是普通 Resource，改字段没有任何通知机制，
##   所以只能每帧刷 —— 好处是"任何来源的改动都会自动出现"，代价是每帧 8 次字符串赋值。
##
## 坑：
##   · Global.player 是**跨场景存活的旧引用**，切场景/重开一局后可能指向已释放的节点，
##     所以第一行必须先 is_instance_valid(Global.player) 再取字段 —— 少了这句会在
##     选人界面/主菜单阶段（那时还没有 player）直接报错。
##   · 8 个 % 节点都是 unique_name_in_owner，改名要连 .tscn 一起改。
##   · 面板隐藏时本函数照样在跑（visible=false 不停止 _process）；开销很小，忽略即可。
extends Panel
class_name StatsContainer

## ── 八个数值的显示 Label（全部是 unique_name_in_owner，可用 % 取）──────────
## 名字里的 Label 后缀和界面上的位置一一对应：
##   HealthLabel=生命上限、HPRegenLabel=每波回血、LifeStealLabel=吸血%、DamageLabel=伤害、
##   LuckLabel=幸运、SpeedLabel=移速、BlockLabel=格挡%、HarvestingLabel=每波采集（金币）。
## @onready 在 _ready() 之前是 null，别提前访问。
@onready var health_label: Label = %HealthLabel
@onready var hp_regen_label: Label = %HPRegenLabel
@onready var life_steal_label: Label = %LifeStealLabel
@onready var damage_label: Label = %DamageLabel
@onready var luck_label: Label = %LuckLabel
@onready var speed_label: Label = %SpeedLabel
@onready var block_label: Label = %BlockLabel
@onready var harvesting_label: Label = %HarvestingLabel


## 每帧把玩家当前的 8 项属性刷到界面。
## 参数 delta：引擎给的帧间隔（秒）。这里用不到（只是读值，不按时间累积），所以未引用。
## 返回值：无。
## 副作用：写 8 个 Label 的 text；**只读** Global.player.stats，绝不修改任何数值。
## 早退条件：Global.player 不存在或已被释放时直接 return —— 因为在主菜单 / 选人界面阶段
##   Global.player 还是 null（它是在 Arena._on_selection_panel_on_selection_completed()
##   里才 add_child 并赋值的）。少了这个判断，一进主菜单就会崩。
## 单位口径：life_steal 与 block_chance 在 UnitStats 里都是**百分数语义**（0~100+），
##   所以这里直接拼 "%"；而 health/damage/speed/luck/hp_regen/harvesting 是裸数值，原样 str()。
## Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta: float) -> void:
	# 必须在取字段之前判有效：Global.player 是跨场景存活的引用，主菜单/选人阶段它是 null，
	# 上一局结束后它还可能是"已被 queue_free 的节点"。is_instance_valid 能同时挡住这两种情况。
	if not is_instance_valid(Global.player):
		return
	# 下面 8 行都是"读 UnitStats → str() → 写 Label"。life_steal / block_chance 额外拼一个 % 号。
	# 这些属性随时可能被卡片 / 被动 / 升级改掉，所以每帧重读一遍最省心。
	health_label.text = str(Global.player.stats.health)
	hp_regen_label.text = str(Global.player.stats.hp_regen)
	# 这两个在 UnitStats 里就是百分数语义（0~100+），所以这里直接拼 "%"，不要再 ×100：
	# 单位口径必须和 resources/units/unit_stats.gd 的注释一致（block_chance 在 Unit 里是 /100 后掷骰）。
	# ⚠ 坑：WeaponStats.life_steal 的单位是 0~1 小数，和 UnitStats.life_steal（百分数）**不一样**，
	#   显示的是后者，所以面板上写 "5%" 就代表 UnitStats 里存的是 5。
	life_steal_label.text = str(Global.player.stats.life_steal) + "%"
	damage_label.text = str(Global.player.stats.damage)
	luck_label.text = str(Global.player.stats.luck)
	speed_label.text = str(Global.player.stats.speed)
	block_label.text = str(Global.player.stats.block_chance) + "%"
	harvesting_label.text = str(Global.player.stats.harvesting)
