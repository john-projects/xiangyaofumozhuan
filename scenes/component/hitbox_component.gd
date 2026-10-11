extends Area2D
class_name HitboxComponent

## HitboxComponent —— 攻击方的"命中判定框"（打人的那一侧）。
##
## ── 在系统里的位置 ──
##   伤害系统成对出现：HitboxComponent（打人）+ HurtboxComponent（挨打），两者都是 Area2D。
##   本组件是**主动方**：它自己算不了伤害，只负责"带上这次攻击的参数（伤害/暴击/击退/攻击者）"
##   去碰别人的 Hurtbox，碰上就发信号 + 播命中音。
##   真正的扣血在受害者的 Unit._on_hurtbox_component_on_damaged() 里。
##   场景 scenes/component/hitbox_component.tscn 把 area_entered 连回自己的 _on_area_entered。
##
## ── 谁在用（三种挂法，用法完全不同） ──
##   1) 近战武器（weapon_wand/sword/... 的 Sprite2D 下）：开打时 enable() + setup()，
##      挥砍 tween 结束时 disable()，见 melee_behavior.gd —— 判定只在挥砍那几帧存在；
##   2) 投射物（projectile_pistol.tscn 的 HitboxComponent 子节点）：**不调 enable/disable**，
##      场景里就配成常开，飞行全程都在判定，见 projectile.gd；
##   3) 敌人自带的接触伤害框（enemy_chaser_slow.tscn）：同样常开。
##
## ── 碰撞层约定（project.godot [layer_names]，值是 2^(层号-1) 位掩码） ──
##   1=Player 2=Enemy 3=HitboxEnemy(4) 4=HurtboxEnemy(8) 5=HitboxPlayer(16) 6=HurtboxPlayer(32)
##   敌人的 Hitbox：layer 4（HitboxEnemy）+ mask 32（HurtboxPlayer）→ 只打玩家；
##   玩家武器/投射物：layer 16（HitboxPlayer）+ mask 8（HurtboxEnemy）→ 只打敌人。
##   为什么敌人打不到敌人：mask 里没有 HurtboxEnemy 那一位。
##   层位是在各自的 .tscn 上配的，本脚本不碰 —— "打不到人"九成是层位配错，不是这里的问题。

## 命中一个 Hurtbox 时对外发的信号，参数是对方的 HurtboxComponent。
## ⚠ 大多数调用方**并不连它**：
##   · Unit 那边是从自己的 Hurtbox.on_damaged 反向收到伤害的（受击方视角）；
##   · 投射物连它是为了自毁（projectile_pistol.tscn 里连到 _on_hitbox_component_on_hit_hurtbox）。
##   所以这个信号的真实用途是"让攻击者知道自己打中了"。
signal on_hit_hurtbox(hurtbox: HurtboxComponent)

## 本次攻击的伤害值（单位：血点）。默认 1.0 是"没 setup 就碰上"时的最小兜底。
## 由 setup() 写入；受击方直接读它来扣血（Unit._on_hurtbox_component_on_damaged → take_damage(hitbox.damage)）。
var damage := 1.0
## 本次攻击是否暴击。只作为"标记"随信号/外观传出去，不影响伤害数值 ——
## Arena._on_create_damage_text() 会读它决定飘字的颜色。
## ⚠ 由攻击方在 setup() 时算好（见 WeaponBehavior.critical），并且武器在攻击结束后会把它重置为 false，
##   所以**不要在攻击判定之后还依赖它**。
var critical := false
## 击退力度（单位：像素/秒量级的速度系数，0 = 不击退）。
## 受击方 Enemy._on_hurtbox_component_on_damaged() 里判 if > 0，然后按
## hitbox.source.global_position 指向自己的方向施加击退。默认 0.0 = 默认不击退（对射程武器/投射物友好）。
var knockback_power := 0.0
## 攻击来源节点（一般是武器或施法单位）。**故意不加类型注解**：调用方传的是 weapon.get_parent()
## 这类"五花八门的东西"，只要是个 Node2D 就行。
## ⚠ 用途只有一个：给击退算方向（Enemy 里读 source.global_position）。
##   所以如果传进来的节点已经被 queue_free（例如投射物自毁后又有人读它），访问 global_position 会报错 ——
##   传之前确保它是长期存活的对象（武器/单位），而不是投射物本身。
var source: Node2D

# Called when the node enters the scene tree for the first time.
## Godot 生命周期钩子：节点首次进入场景树时调用一次（之后被移除再加回来不会重跑）。
## 本函数**刻意留空**：HitboxComponent 不做任何自动初始化，一切都由攻击方显式调 setup()/enable()，
## 这样同一份 Hitbox 场景可以被近战、投射物、接触伤害复用，行为完全由调用方决定。
## ⚠ 别在这里加"自动 enable()"：投射物需要常开，而近战必须默认关闭，
##   两者共用这个脚本，自动开启会让近战武器的判定框在没挥砍时也一直生效（隔空打人）。
func _ready() -> void:
	pass # Replace with function body.


## 打开判定框（可以开始命中别人了）。
## 参数：无。返回值：无。
## 副作用：**用 set_deferred 把 monitoring / monitorable 延后到本帧末设为 true**。
##   monitoring   = 我去检测别人（area_entered 才会来）；
##   monitorable  = 别人能检测到我（对方主动检测时才需要）。
## ⚠ 为什么必须 set_deferred 而不是直接赋值：Area2D 的这两个属性属于物理服务器状态，
##   在物理回调（area_entered / body_entered）里直接改会让 Godot 报
##   "Can't change this state while flushing queries"。虽然本工程的调用点（tween 回调、_ready）
##   通常不在物理回调里，但统一用 deferred 是防御性写法：无论谁在什么时候调都安全。
##   deferred 的代价是**延迟一帧生效** —— 开打当帧就判定的话会漏掉第一帧，所以调用方一般提前 enable（见 melee_behavior）。
## ⚠ 本函数不会重置 damage/critical 等参数，enable 之后通常还要紧跟一次 setup()。
func enable() -> void:
	set_deferred("monitoring", true)
	set_deferred("monitorable", true)
	
## 关闭判定框（停止命中）。
## 参数：无。返回值：无。
## 副作用：同样用 **set_deferred** 把 monitoring / monitorable 置为 false（原因见 enable()）。
## ⚠ 时序坑：deferred 是"帧末执行"，所以 disable() 的**当帧**判定仍然有效 ——
##   已经排队/已进入范围的 area_entered 信号该来还是会来，本帧内同一个 Hurtbox 依然可能被命中一次。
##   想"一击只中一次"，得在受击方或攻击方自己加去重标记（当前项目没做，
##   敌人若被同一次挥砍在同一帧反复进入/离开判定范围，理论上能吃到多段伤害）。
## 调用方：melee_behavior.gd 在挥砍 tween 的 finished 回调里调它。
func disable() -> void:
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
	
## 给本次攻击装填参数。每次攻击**都要重新调用**（近战每挥一次、投射物每次发射一次）。
## 参数：
##   new_damage    伤害点数（血点），会直接存进 damage 并被受击方读取；
##   new_critical  是否暴击标记，只影响飘字颜色，不影响数值；
##   new_knockback 击退力度（0 = 不击退），敌人判 > 0 才施加；
##   new_source    攻击来源节点（用于算击退方向），传长期存活的对象，别传投射物自己。
## 返回值：无。
## 副作用：只改本组件自己的四个字段 —— 不发信号、不碰碰撞状态、不写 Global。
## ⚠ 为什么用 self.damage / self.critical 而不用 this.xxx 那种风格：这里只是为了和参数名区分，
##   行为完全等价（GDScript 里 self 可省，写不写都一样）。
## ⚠ 本函数**不检查**当前是否 enable —— 对着关闭状态的判定框 setup() 也是合法的（先装弹后开火），
##   近战就是这么用的：先 enable() 再 setup()。
func setup(new_damage: float, new_critical: bool, new_knockback: float, new_source: Node2D) -> void:
	self.damage = new_damage
	self.critical = new_critical
	knockback_power = new_knockback
	self.source = new_source
	

## Area2D 的 area_entered 回调：有别的 Area2D 进入我的检测范围时触发。
## 参数 area：进入的 Area2D，实际类型可能是任何 Area2D（取决于 mask 配到了哪些层）。
## 返回值：无。
## 副作用（顺序很重要）：
##   1. **播命中音** —— SoundManager.play_sound(Sound.ENEMY_HIT)，即发即忘、无返回值；
##      它是无条件播的（先播再判断类型都行），所以**只要是本框碰到的东西**都会响，
##      包括理论上碰到不该碰的对象时（当前层位配对下不会发生）；
##   2. emit on_hit_hurtbox(area)，把对方的 Hurtbox 传出去。
## ⚠ 它与 HurtboxComponent._on_area_entered 是**同一次物理接触的两侧回调**：
##   两个 Area2D 互相监测时两根回调都会触发（谁在谁的 mask 里决定），
##   所以"命中音只播一次"是靠"音效只写在本组件里"保证的，别在 Hurtbox 那边再加一遍。
## ⚠ 类型判断 `area is HurtboxComponent`：因为同层上可能挂着别的 Area2D（拾取、视野、触发器），
##   不判类型会对金币/宝箱也"命中"一次并白播音效。
## ⚠ 本回调运行在**物理步进中**：在这里绝不能直接改 monitoring/monitorable/collision_layer，
##   也不能靠它去 disable() 自己（要用 set_deferred，见 enable/disable）。
##   投射物在此处 queue_free() 是安全的（queue_free 只是排队删除，不立即改物理状态）。
func _on_area_entered(area: Area2D) -> void:
	if area is HurtboxComponent:
		SoundManager.play_sound(SoundManager.Sound.ENEMY_HIT)
		on_hit_hurtbox.emit(area)
