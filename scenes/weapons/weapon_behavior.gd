## ═══════════════════════════════════════════════════════════════════════════
## WeaponBehavior —— 武器行为的抽象基类（伤害计算 + 吸血这两个公共能力）
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   挂在武器场景的 "WeaponBehavior" 子节点上（weapon_base.tscn 里的那个节点），
##   具体脚本由各武器覆盖：近战挂 MeleeBehavior（melee/melee_behavior.gd），
##   远程挂 RangeBehavior（range/range_behavior.gd）。
##   武器侧的 Weapon 只通过本基类接口调 execute_attack()，不关心底下是哪种。
##
## 本文件提供什么：
##   1. execute_attack()：空实现（接口占位，等子类覆盖）
##   2. get_damage()：算本次伤害（武器基础伤害 + 玩家全局伤害，暴击时向上取整）
##   3. apply_life_steal()：按概率吸血，成功则固定回 1 点血并请求飘字
##
## 数据流（从哪来到哪去）：
##   @export weapon（场景里用 node_paths 绑成 NodePath("..")）→ weapon.data.stats（WeaponStats）
##   Global.player.stats.damage / life_steal → 玩家的全局加成
##   Global.get_chance_success() → 暴击与吸血的概率判定（**会推进全局随机数**）
##   emit Global.on_create_heal_text → Arena 弹 "+1" 飘字
##   算出的伤害最终由子类交给 HitboxComponent.setup() → 命中 HurtboxComponent → Unit 扣血
##
## 坑（改之前务必看）：
##   · critical 是**暂存标记**而不是返回值：get_damage() 写它、子类读它去初始化 hitbox。
##     GDScript 的函数实参**从左到右**求值，所以子类里写 `hitbox.setup(get_damage(), critical, …)`
##     才能拿到本次的暴击结果 —— 两个参数一调换，暴击标记就永远慢一拍；
##   · 两个子类都在"动作进行中"**无条件**调 apply_life_steal()，与是否命中无关 → 挥空也能吸血；
##   · UnitStats.life_steal 是百分数、WeaponStats.life_steal 是 0~1 小数，单位不同（详见 apply_life_steal）。
extends Node2D
class_name WeaponBehavior

## 反向引用宿主武器节点（场景里绑的是 NodePath("..")，也就是武器根节点）。
## 通过它能拿到：data（数值）、rotation（开火方向）、sprite（后座/前冲动画的目标）、
## atk_start_pos（动画基准位置）、get_parent()（玩家，作为伤害来源传给 hitbox）。
## 为 null 时本文件这三个函数都会崩，所以武器场景里这一项必填。
@export var weapon: Weapon

## 本次攻击是否暴击的**暂存标记**。
## 由 get_damage() 在判定成功时置 true；由子类在收招结束时复位为 false
## （MeleeBehavior 在 tween.finished 回调里、RangeBehavior 在 await tween.finished 之后）。
## 默认 false —— "没暴击"是安全的默认值。
var critical := false
 
## 接口占位：真正的攻击动作由子类覆盖实现。
## 参数：无（子类从 weapon / hitbox 等成员里自取所需数据）。
## 返回值：无。
## 副作用：无 —— 基类版本是空的。所以"把本基类直接挂在武器上"的后果是：
##   武器照常转向、照常走冷却，但**什么也不会发生**（不报错，只是打不出东西）。
## 注意：两个子类覆盖它时都**没有**调用 super（这里 super 本来也没意义）。
func execute_attack() -> void:
	pass
	
## 计算本次攻击的伤害（同时决定本次是否暴击）。
## 参数：无。返回值：float —— 本次伤害数值。
## 副作用：
##   · 写成员 critical（暴击时置 true，且**不会自动复位** —— 复位是子类的责任）；
##   · 调 Global.get_chance_success()，**推进全局随机数序列**（会影响之后的掉落/抽卡结果）。
## 计算三步：
##   1) damage = 武器基础伤害 + Global.player.stats.damage（玩家的全局伤害加成走**加法**）；
##   2) crit_chance 取自武器（0~1 小数）；判定命中则
##      damage = ceil(damage × crit_damage)（**向上取整**，避免 1.5 倍后留下 .5 这种小数伤害）；
##   3) 返回最终伤害。
## 坑：
##   · 每次调用都会重掷暴击并**覆盖** critical —— 所以子类里只应调一次；
##     调两次会用第二次的结果（第一次的暴击白摇了，还多消耗一次随机数）；
##   · Global.player 未实例化时这里直接报错（实践中武器是玩家的子节点，必然存在）；
##   · 返回值是 float，暴击时是整数值；伤害飘字显示的是 hitbox.damage（Arena 里直接 str() 出来）。
func get_damage() -> float:
	# 武器基础伤害 + 玩家的全局伤害加成（加法，不是乘法）。
	var damage := weapon.data.stats.damage + Global.player.stats.damage
	# 暴击率来自武器数据（0~1 的小数，不是百分数）。
	var crit_chance := weapon.data.stats.crit_chance
	# 概率判定：Global.get_chance_success 内部是 randf_range(0,1) < chance，并会推进全局随机数。
	if Global.get_chance_success(crit_chance):
		# 命中暴击：把标记置上，子类随后会读这个成员去告诉 hitbox（飘字颜色也靠它）。
		critical = true
		# 向上取整：避免 1.5 倍伤害出现 7.5 这类小数，同时也让暴击永远不小于原伤害。
		damage = ceil(damage * weapon.data.stats.crit_damage)
	# 返回非暴击或已放大的伤害值；注意 critical 会一直保持到子类在收招时清掉它。
	return damage

## 按概率吸血：成功就给玩家回 1 点血，并请求弹一个 "+1" 飘字。
## 参数：无。返回值：无（调用方**无法知道**这次有没有吸到；想判断得自己复算概率）。
## 副作用：
##   · Global.player.health_component.heal(1.0)（heal 会把血量夹在上限内并 emit on_health_changed）；
##   · emit Global.on_create_heal_text(Global.player, 1.0) → Arena 弹 "+1" 飘字；
##   · 调 Global.get_chance_success()，推进全局随机数。
## 概率口径（最容易看错的地方 —— 两个同名字段单位不同）：
##   steal_chance = Global.player.stats.life_steal / 100.0   ← UnitStats 里填的是**百分数**（5 = 5%）
##                + weapon.data.stats.life_steal              ← WeaponStats 里直接是 **0~1 小数**（0.05 = 5%）
##   两项相加可能超过 1.0；get_chance_success() 用 `random < chance` 判定，所以 ≥1 就是必定吸血。
## 细节 / 坑：
##   · 回血量**固定 1.0 点**，与伤害无关（想改成"按伤害比例吸血"必须改逻辑，不是配置问题）；
##   · 条件写成 `can_steal and is_instance_valid(Global.player)`：短路求值保证玩家失效时不会去访问
##     health_component，但**概率判定已经消耗过随机数**了；
##   · 两个子类都在攻击动作**中途**调用它（近战在 tween 序列中间、远程在开火后），
##     那时命中还没结算（甚至可能完全没打到），所以**挥空也会吸血回血**，这是现存行为。
func apply_life_steal() -> void:
	# 玩家侧是百分数（要 /100），武器侧已是 0~1 小数，直接相加 —— 单位不同，最易看错。
	var steal_chance := (Global.player.stats.life_steal / 100.0) + weapon.data.stats.life_steal
	# 先摇概率（这一步就会消耗一次全局随机数，即使后面玩家校验失败也不回退）。
	var can_steal := Global.get_chance_success(steal_chance)
	# 短路求值：can_steal 为 false 时不会去碰 Global.player，避免访问已释放/未实例化的玩家。
	if can_steal and is_instance_valid(Global.player):
		# 固定回 1 点血（与伤害无关）；heal() 内部会把血量夹在上限内并刷新血条。
		Global.player.health_component.heal(1.0)
		# 弹 "+1" 飘字：Arena 订阅了 on_create_heal_text，用玩家节点的位置生成 FloatingText。
		Global.on_create_heal_text.emit(Global.player, 1.0)
