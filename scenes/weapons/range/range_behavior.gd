## ═══════════════════════════════════════════════════════════════════════════
## RangeBehavior —— 远程武器的一次开火（WeaponBehavior 的子类）
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   挂在远程武器场景的 WeaponBehavior 节点上（weapon_pistol / smg / shotgun /
##   revolver / laser 这 5 个场景都用它，脚本覆盖写在各自的 .tscn 里）。
##   父类 WeaponBehavior 提供 get_damage() 与 apply_life_steal()，本文件实现 execute_attack()
##   以及它专用的 create_projectile()。
##
## 一次开火的完整时间线：
##   1) 置 weapon.is_attacking = true（Weapon 据此锁定目标、并改用带散布的朝向）
##   2) create_projectile()：从 Muzzle 位置生成一颗子弹，方向 = 武器当前 rotation
##   3) 播开枪音效（SoundManager 的 FIRE）
##   4) 后座 tween：sprite 沿 -x 退一个 recoil，再用 recoil_duration 回到原位
##   5) 中途摇一次吸血
##   6) await tween.finished → 清掉 is_attacking 与 critical
##
## 数据流（从哪来到哪去）：
##   weapon.data.stats（WeaponStats）→ projectile_scene / projectile_speed / recoil /
##     recoil_duration / knockback
##   @onready muzzle = %Muzzle（场景唯一名，挂在 Sprite2D 下）→ 子弹出生点
##   weapon.rotation → 开火方向（Weapon.use_weapon() 里刚算好的"目标角度 + 散布"）
##   get_damage() 与 critical → 交给 Projectile.set_peojectile()（伤害与是否暴击）
##   weapon.get_parent() = 玩家节点 → 作为伤害来源（hitbox.source）传给子弹
##
## 坑（改之前务必看）：
##   · 只有**远程**武器场景才有 Muzzle 节点（都设了 unique_name_in_owner）；近战场景没有，
##     不过近战挂的是 MeleeBehavior，根本不会执行到这里；
##   · execute_attack() 里有 await，所以它是协程：Weapon.use_weapon() 调用它时**不等**，
##     冷却照常从"开火那一刻"开始算；好处是代码读起来是顺序的，代价是调用方无从得知何时结束；
##   · 子弹挂在 /root 下，owner 为 null，且不随武器/玩家销毁；
##   · apply_life_steal() 与是否命中无关 —— 打空也照样可能回血。
extends WeaponBehavior
class_name RangeBehavior

## 枪口标记（Marker2D，场景里设了 unique_name_in_owner，所以用 % 取）。
## 它是 Sprite2D 的子节点 → 跟着武器旋转、也跟着 update_visuals() 的 scale.y 翻转一起动，
## 所以枪口始终停在枪管前端（武器指向左半边时不会跑到枪托后面）。
## ⚠ 只有远程武器场景才摆了这个节点；缺了它，@onready 会拿到 null，create_projectile() 里读
##   muzzle.global_position 时就会崩（那正是子弹出生点的来源）。
@onready var muzzle: Marker2D = %Muzzle

## 执行一次开火（覆盖父类的空实现，**不调用** super）。
## 参数：无（数值取自 weapon.data.stats 与 %Muzzle）。
## 返回值：无。⚠ 因为是协程，调用方拿到的是协程对象 —— Weapon.use_weapon() 没有 await 它。
## 副作用（按发生顺序）：
##   · 写 weapon.is_attacking = true；
##   · create_projectile()：instantiate 子弹并挂到 /root 下，设置速度/伤害/来源；
##   · SoundManager.play_sound(SoundManager.Sound.FIRE)（全局音效，与场景无关）；
##   · 创建 tween 改 weapon.sprite.position（后座 → 回位）；
##   · apply_life_steal()：摇吸血并可能给玩家回血 + emit 回血飘字；
##   · await 后清 is_attacking 与 critical。
## 时序 / 坑：
##   · create_projectile() 放在最前面，用的是**本帧刚算好的** weapon.rotation ——
##     Weapon._process 的顺序是 rotate_to_target → update_visuals → use_weapon(calculate_spread)，
##     所以子弹方向实际是"目标角度 + 累计散布"；
##   · 后座用的是 `atk_start_pos.x - recoil`（枪身后坐），回位时长用 recoil_duration，
##     而近战回位用的是 back_duration —— 两条路线的参数不同，别互相照抄；
##   · 与 MeleeBehavior 用 tween.finished.connect(回调) 不同，这里用 await：
##     写起来更直观，但**如果这个节点在 await 期间被释放**，协程会随节点一起中止，
##     于是 is_attacking 永远停在 true（节点都没了，实际只影响日志/调试观感）；
##   · 全程不与"是否命中"挂钩：打空也照样播完后座、照样可能吸血。
func execute_attack() -> void:
	# 上锁：Weapon 在攻击期间不再重新索敌，并把朝向固定成"目标角度 + 散布"。
	weapon.is_attacking = true
	
	# 先生成子弹（要用此刻的 rotation），再播后座动画。
	create_projectile()
	# 开枪音效（全局单例，和玩家/武器在不在树上无关）。
	SoundManager.play_sound(SoundManager.Sound.FIRE)
	
	# 后座动画用的 tween（自动绑定本节点，节点释放时自动失效）。
	var tween := create_tween()
	# 后座位：只改 x，y 保持握持高度；recoil 是枪身向后挪多少像素。
	var attack_pos := Vector2(weapon.atk_start_pos.x - weapon.data.stats.recoil, weapon.atk_start_pos.y)
	# 第 1 段：后座，时长 recoil_duration。
	tween.tween_property(weapon.sprite, "position", attack_pos, weapon.data.stats.recoil_duration)
	
	# 摇吸血（父类方法）：与这一枪是否打中无关。
	apply_life_steal()
	
	# 第 2 段：回位，时长也用 recoil_duration（后座与复位的耗时对称）。
	tween.tween_property(weapon.sprite, "position", weapon.atk_start_pos, weapon.data.stats.recoil_duration)
	
	# await 等 tween 播完再解锁 —— 这是与 MeleeBehavior（用 connect 回调）最大的写法差异。
	await tween.finished
	# 解锁：Weapon 可以重新索敌并在冷却结束后再开一枪。
	weapon.is_attacking = false
	# 清暴击标记，避免下一发非暴击的子弹沿用这一发的暴击状态（飘字颜色会错）。
	critical = false
	
## 生成并发射一颗子弹。
## 参数：无（数据取自 weapon.data.stats 与 %Muzzle）。
## 返回值：无。
## 副作用：
##   · instantiate 出子弹场景并 get_tree().root.add_child(instance)；
##   · 设置子弹的 global_position（枪口位置）；
##   · 调 instance.set_peojectile(velocity, 伤害, critical, knockback, weapon.get_parent())。
## 细节 / 坑：
##   · `instantiate() as Projectile` 是运行时类型转换：子弹场景根节点必须挂 Projectile 脚本，
##     否则得到 null，下一句设置属性就崩；projectile_scene 为 null 也会在同一句崩；
##   · 挂到 /root 而不是武器/玩家身下：子弹的生命周期与发射者解耦（武器被卖掉、玩家死亡，
##     飞出去的子弹照样飞）；代价是它的 owner 为 null，只能靠自身 queue_free()
##     （命中 hurtbox 或飞出屏幕时，见 projectile.gd），**不能用 owner.queue_free()**；
##   · 先 add_child 再赋 global_position：节点不在树里时 global_position 没有有效的父变换；
##   · 速度用 Vector2.RIGHT.rotated(rotation) * projectile_speed 表示，
##     等价于"以武器角度为方向、长度 = 速度"的向量（省一次 atan2），单位是像素/秒；
##   · set_peojectile 是原作者的拼写（不是 set_projectile），实参从左到右求值：
##     get_damage() 先写好 critical，紧接着读到的才是本次的暴击状态；
##   · 来源传 weapon.get_parent()（**玩家节点**，不是武器节点）：敌人被击退时
##     用 direction_to 从这里算方向，所以传错了会导致击退方向反向。
func create_projectile() -> void:
	# 实例化子弹场景。⚠ 用 as Projectile 做运行时转换，场景根节点挂错脚本会得到 null。
	var instance := weapon.data.stats.projectile_scene.instantiate() as Projectile
	# 挂到 /root 下（不属于武器/玩家），因此 owner 为 null，只能靠子弹自己 queue_free()。
	get_tree().root.add_child(instance)
	# 入树之后才能用 global_position 设世界坐标（枪口位置，已含武器的旋转与翻转）。
	instance.global_position = muzzle.global_position
	
	# 速度方向：把"向右的单位向量"按武器当前角度旋转，再乘速度（像素/秒）。
	var velocity := Vector2.RIGHT.rotated(weapon.rotation) * weapon.data.stats.projectile_speed
	# 参数依次是（速度, 伤害, 是否暴击, 击退力度, 伤害来源）。
	# 同样是从左到右求值：get_damage() 决定 critical，之后才读走它。
	instance.set_peojectile(velocity, get_damage(), critical, weapon.data.stats.knockback, weapon.get_parent())
	
	
