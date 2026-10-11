extends Node2D
class_name HealthComponent

## HealthComponent —— 单位的"血量账本"：唯一负责记录并修改当前血量的组件。
##
## ── 在系统里的位置 ──
##   伤害链路的终点站：HurtboxComponent 收到 Hitbox → 交给 Unit._on_hurtbox_component_on_damaged()
##   → 格挡判定通过后调本组件的 take_damage()，扣血并广播信号。
##   它自己**不知道**谁打的、也不负责演出（白闪、飘字、击退都在 Unit/Enemy 那边做），
##   只负责"血量"这一件事，所以玩家和敌人（Player / Enemy 都继承 Unit）共用同一份实现。
##   节点形态：一个挂在 unit.tscn 里的 Node2D（scenes/component/health_component.tscn），不是 Area2D，
##   所以它不参与任何碰撞，纯粹靠函数调用与信号驱动。
##
## ── 数据流向 ──
##   UnitStats.health（模板）→ setup() 拷进 max_health / current_health
##     → take_damage() / heal() 改 current_health
##       → emit on_health_changed → 场景里连到 HealthBar（血条 UI）
##       → emit on_unit_hit / on_unit_died → 由具体单位决定后续（敌人掉金币、玩家结束战斗等）
##     → 死亡时 die() 释放宿主节点
##
## ── 陷阱清单（都在这一个文件里） ──
##   · die() 用的是 owner.queue_free()：owner 只有在"从场景文件实例化出来"的节点上才有值。
##     如果将来把 HealthComponent 的宿主 Unit 用 Unit.new()/纯代码拼出来再 add_child，
##     owner 会是 null，这里会直接报错（运行时 add_child 不会自动设置 owner）。
##   · 三个信号的接收方都写在 .tscn 的 [connection] 里（health_bar / enemy 等），
##     本文件不自己做 connect —— 所以"血条不动"这类问题要去场景里查连线。

## 单位每次实际受到伤害时发一次（在扣血之后、判死之前）。
## ⚠ 当前全项目**没有任何地方连接这个信号**（grep on_unit_hit 只有本文件），
##   击中的音效其实是在 HitboxComponent._on_area_entered 里播的。
##   它保留下来是给"受击额外反馈"（顿帧、屏幕边缘红闪、震动）预留的挂点，别以为它在驱动音效。
signal on_unit_hit
## 血量归零时发一次，且在 die() 之前发 —— 所以接收方还能安全读到 stats、全局坐标等（节点尚未释放）。
## 连在 Enemy 上用来到 Global.on_enemy_died（掉金币），连在玩家侧用来做战败处理。
signal on_unit_died
## 血量变化广播（受伤、回血、初始化都会发）。参数是当前值与最大值，直接喂给血条 UI。
## 注意参数名 current / max 里的 max 是**变量名**不是函数，GDScript 不会把它解析成 max()。
signal on_health_changed(current: float, max: float)

## 血量上限。默认 1.0（一个"不该出现"的极小值）：万一某处忘了 setup() 就直接 take_damage(1)，
## 单位会立刻死亡而不是卡在 NaN/0 上限的怪状态里，方便在测试时立刻发现漏调 setup 的问题。
var max_health := 1.0
## 当前血量。单位存活与否**只看这里**（Unit 和 Enemy 都直接读 current_health <= 0）。
var current_health := 1.0

## 初始化（或重置）血量：把 UnitStats.health 拷成本组件的上限与当前值。
## 参数 stats：单位的属性表 Resource。⚠ 这里只是**读**它，不会写回去，
##   所以战斗中掉血不会污染 .tres（和 Spawner/ItemPassive 那种就地改 Resource 的写法不同）。
## 返回值：无。
## 副作用：修改 max_health / current_health，并 emit on_health_changed（血条会在这一帧刷新）。
## 调用时机：Unit._ready() 里 —— 也就是节点进树后立刻执行，早于玩家第一次操作。
## ⚠ 会被重复调用（Player 在 update_player_new_wave() / rebuild 之类路径上也会调），
##   语义是"按模板重置满血"，不是"叠加"，所以在战斗中途调它等于回满血。
func setup(stats: UnitStats) -> void:
	max_health = stats.health
	current_health = max_health
	on_health_changed.emit(current_health, max_health)
	
## 扣血。这是全项目唯一的"造成伤害"落点（近战、投射物、技能最终都汇总到这句）。
## 参数 value：伤害点数（单位：血点）。**没有做正数校验** —— 传负数相当于回血，
##   所以调用方必须保证传进来的是正伤害（HitboxComponent.damage 正常都 >= 0）。
## 返回值：无。
## 副作用（按执行顺序，很重要）：
##   1. 已经死了（current_health <= 0）就直接 return —— 这是"尸体免疫"保护，
##      防止同一帧多次命中把血量打成负数、或让 on_unit_died 重复发射；
##   2. 扣血后用 max(x, 0) 钳到 0（Godot 的 max() 是全局函数，同 min()/clampf()）；
##   3. emit on_unit_hit（当前无监听者）；emit on_health_changed（血条刷新）；
##   4. 若归零：再钳一次 0 → emit on_unit_died（Enemy 借此掉金币）→ 调 die() **释放宿主节点**。
## ⚠ 时序坑：第 4 步是**同步**发生的 —— die() 在 take_damage() 返回前就执行了 queue_free()。
##   queue_free() 只是"排队"，节点要到本帧末才真正消失，所以调用方在 take_damage() 之后
##   仍能访问该节点（但下一帧就是无效引用，跨帧持有必须 is_instance_valid()）。
## ⚠ 谁负责白闪/飘字？不是这里，是 Unit._on_hurtbox_component_on_damaged() 在调用本函数**之前/之后**
##   自己做的（先 set_flash_material 再 take_damage，然后 emit Global.on_create_damage_text）。
##   所以单独调用 take_damage()（例如控制台或测试脚本）不会看到任何视觉反馈。
func take_damage(value: float) -> void:
	if current_health <= 0:
		return
	current_health -= value
	current_health = max(current_health, 0)
	
	on_unit_hit.emit()
	on_health_changed.emit(current_health, max_health)
	
	if current_health <= 0:
		current_health = 0
		on_unit_died.emit()
		die()

## 回血：把 current_health 加上 amount，并钳不超过 max_health（不溢出）。
## 参数 amount：回复量（单位：血点，可以是小数，例如 UnitStats.hp_regen 那种 0.5/跳）。
##   ⚠ 同样没有正负校验：传负数等于扣血，但**不会**触发 on_unit_hit / 死亡判定，
##   所以拿它当"扣血"用会得到一个血量 <= 0 却还活着的僵尸单位。
## 返回值：无。
## 副作用：改 current_health、emit on_health_changed（血条刷新）。
##   **不会** emit on_unit_hit，也**不会**调 die()。
## 已死单位（current_health <= 0）直接 return：不允许"治疗复活"，
##   想复活必须重新 setup()（那等于重造满血）。
## 调用方：UnitStats.hp_regen 的定时器（Player._on_hp_regen_timer_timeout）、
##   WeaponBehavior.apply_life_steal()（吸血固定回 1 点）。
func heal(amount: float) -> void:
	if current_health <= 0:
		return
	
	current_health += amount
	current_health = min(current_health, max_health)
	on_health_changed.emit(current_health, max_health)


## 死亡处理：把宿主动画/节点整体销毁。
## 参数：无。
## 返回值：无。
## 副作用：**owner.queue_free()** —— 释放的是"宿主单位节点"，不是 HealthComponent 自己。
##   本组件是 Unit 的子节点，所以这一句等于"整个单位消失"（血条、Hurtbox、贴图一起没了）。
## ⚠ owner 的坑（本项目最典型的隐雷）：
##   · owner 只在节点**随场景实例化**时由引擎赋值（指向场景根，unit.tscn 的根就是 Unit）；
##   · 用 Unit.new() 或 add_child() 手动拼出来的节点，owner 是 null ——
##     此时 owner.queue_free() 会抛 "Attempt to call function 'queue_free' in base 'null instance'"，
##     正确写法是 queue_free()（释放自己）或让调用方释放宿主；
##   · 释放单位应该释放**宿主**而不是本组件，否则会留下一个没血的空壳单位。
## ⚠ 敌人不是走这条路消失的：Enemy.destroy_enemy() 会先播 "die" 动画再 queue_free
##   （那是"清场"用的），所以敌人死亡的实际表现取决于触发者，两者都会让节点消失，但对不齐动画。
func die() -> void:
	owner.queue_free()
