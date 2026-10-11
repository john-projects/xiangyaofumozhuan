## ═══════════════════════════════════════════════════════════════════════════
## MeleeBehavior —— 近战武器的一次挥击（WeaponBehavior 的子类）
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   挂在近战武器场景的 WeaponBehavior 节点上（weapon_punch / sword / axe / mace /
##   chain_saw / wand 这 6 个场景都用它，脚本覆盖写在各自的 .tscn 里）。
##   父类 WeaponBehavior 提供 get_damage() 与 apply_life_steal()，本文件只实现 execute_attack()。
##
## 一次挥击的完整时间线（所有位移都作用在 weapon.sprite.position.x 上）：
##   1) 向后蓄力：x 从 atk_start_pos.x 减一个 recoil
##   2) 打开 hitbox，并写入本次伤害 / 暴击标记 / 击退力度 / 伤害来源
##   3) 向前挥出：x 来到 atk_start_pos.x 加一个 max_range（近战把射程复用成前冲距离）
##   4) 顺便摇一次吸血
##   5) 收招：x 回到 atk_start_pos
##   6) tween 播完 → 关掉 hitbox、清掉 is_attacking 与 critical，允许下一击
##
## 数据流（从哪来到哪去）：
##   weapon.data.stats（WeaponStats）→ recoil / recoil_duration / max_range / back_duration / knockback
##   @export hitbox（场景里绑 NodePath("../Sprite2D/HitboxComponent")）→ 真正打人的判定框
##   get_damage() 与 critical → 交给 hitbox.setup()（伤害数值 + 是否暴击，后者决定飘字颜色）
##   weapon.get_parent() = 玩家节点 → 作为 hitbox.source 传下去（敌人据此算击退方向）
##
## 坑（改之前务必看）：
##   · hitbox 是 Sprite2D 的子节点，所以"动 sprite"就等于"动判定框" —— 挥击动画与命中判定是同一件事；
##   · hitbox.enable() / disable() 内部用的是 set_deferred：物理状态要等本帧物理结束才真正生效；
##   · `hitbox.setup(get_damage(), critical, …)` 的实参**从左到右**求值：get_damage() 先把 critical
##     定好，紧接着读到的才是本次结果 —— 两个参数一调换，就永远用上一次的暴击状态；
##   · 收招复位写在 tween.finished 的回调里：tween 被中断（节点被移除等）时回调不会执行，
##     武器会卡在 is_attacking = true 上再也打不出下一击；
##   · print("攻击") 是原作者留的调试输出，每次攻击都会刷屏（不是漏删，但发布前应摘掉）。
extends WeaponBehavior
class_name MeleeBehavior

## 近战判定框（HitboxComponent），场景里绑的是 NodePath("../Sprite2D/HitboxComponent")。
## 它挂在 sprite 下面 → 跟着挥击位移一起动，所以判定范围就是"当前贴图盖到的地方"。
## 场景里 monitoring / monitorable 初始为 false（不挥击时不判定），靠 enable() / disable() 开关。
@export var hitbox: HitboxComponent

## 执行一次挥击（覆盖父类的空实现；**不调用** super —— 父类那句是 pass，没东西可继承）。
## 参数：无（数据来自 weapon.data.stats 与 @export hitbox）。
## 返回值：无。⚠ 函数**不是**协程（没有 await），收招复位靠 tween 的信号回调完成，
##   所以 Weapon.use_weapon() 调用它之后立刻就能继续设置冷却。
## 副作用（按发生顺序）：
##   · 写 weapon.is_attacking = true（Weapon 据此停止重新索敌、并改用带散布的朝向）；
##   · 创建 tween 并依次改 weapon.sprite.position（后座 → 前冲 → 回位）；
##   · hitbox.enable() 打开判定（内部 set_deferred，下一物理帧生效）；
##   · hitbox.setup(...) 写入伤害 / 暴击 / 击退 / 来源（source 是玩家节点）；
##   · apply_life_steal() 摇一次吸血并可能给玩家回血 + emit 回血飘字；
##   · tween 结束时：hitbox.disable()、weapon.is_attacking = false、critical = false。
## 时序 / 坑：
##   · create_tween() 由**本节点**创建 → tween 自动绑定本节点，节点被释放时 tween 一并失效，
##     不会留下野指针；
##   · recoil_pos / attack_pos 都只改 x、保留 atk_start_pos.y，也就是武器只沿水平方向做动作；
##   · 三段 tween 的时长分别用 recoil_duration / recoil_duration / back_duration，
##     所以前两段对称、收招更快（或更慢，看 WeaponStats 怎么配）；
##   · 全程不与"是否命中"挂钩：没打到敌人也照样播完、照样可能吸血回血；
##   · 三次 tween_property 是**串行**追加到同一个 tween 上的，所以它们是依次播放而不是同时。
func execute_attack() -> void:
	# 调试输出：每次攻击都会打印一行（原作者留下的，不是漏删）。
	print("攻击")
	# 上锁：Weapon._process 看到它为 true 就不会重新索敌，并改用"目标角度 + 散布"的朝向。
	weapon.is_attacking = true
	# 创建 tween（自动绑定本节点）；后面三句 tween_property 会排队依次播放。
	var tween := create_tween()
	# 蓄力位：只改 x，y 保持武器的握持高度；recoil 是"往后退多少像素"。
	var recoil_pos := Vector2(weapon.atk_start_pos.x - weapon.data.stats.recoil, weapon.atk_start_pos.y)
	# 第 1 段：后撤（近战的"拉弓"动作），时长 recoil_duration。
	tween.tween_property(weapon.sprite, "position", recoil_pos, weapon.data.stats.recoil_duration)
	
	# 打开判定框：内部 set_deferred("monitoring"/"monitorable", true) —— 本帧物理结束后才真正生效。
	hitbox.enable()
	# 写入本次攻击参数。⚠ 实参从左到右求值：get_damage() 会先写好 critical，紧接着才读 critical。
	# source 传 weapon.get_parent()（玩家节点），敌人的击退方向 = source → 自己。
	hitbox.setup(get_damage(), critical, weapon.data.stats.knockback, weapon.get_parent())
	
	# 挥出位：max_range 在近战里被复用成"前冲距离"（它同时还是武器索敌圆的半径）。
	var attack_pos := Vector2(weapon.atk_start_pos.x + weapon.data.stats.max_range, weapon.atk_start_pos.y)
	# 第 2 段：前冲，时长同样用 recoil_duration（所以前后两段耗时一样）。
	tween.tween_property(weapon.sprite, "position", attack_pos, weapon.data.stats.recoil_duration)
	
	# 摇吸血（父类方法）：与是否真的打到敌人无关 —— 挥空也可能回血并弹 "+1" 飘字。
	apply_life_steal()
	
	# 第 3 段：收招回位，时长用 back_duration（与前面两段的参数不同）。
	tween.tween_property(weapon.sprite, "position", weapon.atk_start_pos, weapon.data.stats.back_duration)
	
	# 用 connect 挂回调（而不是 await），这样 execute_attack 保持同步函数、调用方不必等它。
	# 回调里的三个复位动作就是"本次挥击结束"的收尾。
	tween.finished.connect(func():
		# 关掉判定框（同样是 set_deferred，下一物理帧生效），避免收招后还能打到人。
		hitbox.disable()
		# 解锁：Weapon 可以重新索敌、并在冷却结束后再次出手。
		weapon.is_attacking = false
		# 清掉暴击标记，避免下一次非暴击的攻击沿用上一次的暴击结果（飘字颜色会错）。
		critical = false
	)
	
