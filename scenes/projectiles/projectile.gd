## Projectile —— 直线飞行的子弹/投射物（远程武器与敌人射击共用这一个脚本）。
##
## ── 在系统里的位置 ──
##   一个轻量 Node2D：自己只做"每帧位移"，命中判定外包给子节点 HitboxComponent，
##   飞出屏幕就自毁。它**不认识敌人也不认识玩家** —— 打谁完全由 HitboxComponent 的碰撞层决定，
##   所以同一份脚本既做玩家的子弹（layer 16 → mask 8 打敌人），
##   也做敌人的弹幕（layer 4 → mask 32 打玩家，见 projectile_enemy.tscn）。
##
## ── 场景结构（projectile_pistol.tscn 是其余几种子弹的父场景） ──
##   ProjectilePistol (Node2D，本脚本，node_paths 里把 hitbox 指到子节点)
##     ├─ Sprite2D              贴图
##     ├─ HitboxComponent       命中判定（场景里默认就是开启状态，见下）
##     └─ VisibleOnScreenNotifier2D  出屏通知
##   场景文件里连了两根信号：
##     HitboxComponent.on_hit_hurtbox        → _on_hitbox_component_on_hit_hurtbox（自毁）
##     VisibleOnScreenNotifier2D.screen_exited → _on_visible_on_screen_notifier_2d_screen_exited（自毁）
##   换皮的做法：做个"继承场景"改贴图和碰撞半径（projectile_smg / _shotgun / _revolver / _laser 都是这么来的）。
##
## ── 谁生成它、怎么用 ──
##   · 玩家远程武器：RangeBehavior.create_projectile() —— add_child 到 get_tree().root
##     （也就是当前场景的根，不是武器下面），再设 global_position，最后 set_peojectile(...)；
##   · 敌人射击：ShootingBehavior.shoot() —— 同样挂到 root，一次扇形发多颗。
##   生命周期全靠自毁，没有对象池：每发子弹都是一次 instantiate + queue_free（量大时可优化成池）。
##
## ── 坑 ──
##   · set_peojectile 的名字是**拼错的**（projectile 写成了 peojectile），
##     但三个调用方都照着这个名字调，所以别"顺手改名"——会一次性改坏所有远程武器和敌人射击；
##   · 位移写在 _process 里且**不看 Global.game_paused**：全局暂停时子弹照飞
##     （其他单位都在 _process 里 if Global.game_paused: return）。这是现状，不是这里写的 bug；
##   · 本节点是运行时 add_child 进场景树的，owner 为 null —— 任何依赖 owner 的操作（如 owner.queue_free）都会失败，
##     所以自毁一律用 queue_free()（释放自己）。

extends Node2D
class_name Projectile

## 命中判定框（子节点）。在 .tscn 里通过 node_paths 连好，不是代码里 get_node。
## ⚠ 它**故意可以被留空**：所有用到它的地方都写了 if hitbox 空值检查，
##   所以一个只有 Sprite2D 的"纯装饰投射物"场景也能跑（不会打人，但不会崩）。
@export var hitbox: HitboxComponent

## 速度向量（单位：像素/秒，方向 + 大小合一）。
## 不设 @export：它在编辑器里没有意义，只能由 set_peojectile() 在运行时按发射方向算出来。
## 默认值（零向量）= 没调用 set_peojectile 就进树时"原地不动"，是个安全的初始态。
var velocity: Vector2

## 每帧位移。用 _process（帧率相关）而不是 _physics_process：
## 投射物只做视觉飞行、不参与物理求解，用帧回调更顺滑；乘 delta 保证不同帧率下速度一致。
## 参数 delta：距上一帧的秒数（Godot 传入）。
## 返回值：无。副作用：只改自己的 position，不碰碰撞、不发信号。
## ⚠ 改写 position 而不是 global_position：投射物被挂到 get_tree().root 下，父节点通常是世界根（无变换），
##   两者等价且 position 更便宜；但如果哪天把它塞进一个有缩放/旋转的父节点，这里就会跟着变形。
## ⚠ 没有 if Global.game_paused 判断（见文件头"坑"）。
func _process(delta: float) -> void:
	position += velocity * delta


## 装填投射物：设定飞行方向/速度，并同步朝向与命中参数。**名字里的 peojectile 是历史拼写错误，勿改**。
## 参数：
##   new_velocity 速度向量（像素/秒）—— 大小决定快慢，方向决定飞行方向；
##   damage       伤害点数（血点），原样传给 HitboxComponent.damage；
##   critical     是否暴击（只影响飘字颜色）；
##   knockback    击退力度（0 = 不击退；敌人射击固定传 0，玩家武器用 WeaponStats.knockback）；
##   unit         攻击来源节点（用于击退方向计算，RangeBehavior 传的是 weapon.get_parent()）。
## 返回值：无。
## 副作用：
##   · 写自己的 velocity 与 **rotation**；
##   · 若 hitbox 非空，会调 hitbox.setup(...)，把那四个参数装进判定框（会在命中时传给受击方）；
##   · 不播声音、不发信号、不启动 tween —— 声音由发射方（RangeBehavior / ShootingBehavior）自己播。
## ⚠ 旋转换算：rotation 是**弧度**，而 velocity.angle() 正好返回"该向量的弧度角"（atan2(y, x)），
##   所以直接赋值即可，不需要 deg_to_rad / rad_to_deg。
##   前提是**贴图的默认朝向是 +X（向右）**：如果美术把子弹画成朝上，就得改成 velocity.angle() + PI/2 之类的偏移。
## ⚠ 顺序坑：必须先设 velocity 再用它算 rotation（这里就是这么写的）。
##   另外它假设 (1,0) 是零度 —— Godot 的 angle() 正是这个约定（屏幕坐标系 y 轴向下，所以正角是顺时针）。
## ⚠ 本函数不检查 hitbox 是否 enable：投射物的判定框在场景里就是常开的，装填完立刻就能命中。
func set_peojectile(new_velocity: Vector2, damage:float, critical: bool, knockback: float, unit: Node2D) -> void:
	self.velocity = new_velocity
	rotation = velocity.angle()
	if hitbox:
		hitbox.setup(damage, critical, knockback, unit)
	

## VisibleOnScreenNotifier2D 的 screen_exited 回调：整个矩形彻底离开屏幕可见区域时触发。
## 参数：无（信号本身不带参数，.tscn 里直接连到本方法名）。
## 返回值：无。
## 副作用：**queue_free() 自己** —— 这是投射物的主要回收路径（防止飞出地图后永久堆积）。
## ⚠ 为什么不用 owner.queue_free()：本节点是运行时 add_child 到 root 的，owner 为 null（见文件头"坑"）。
## ⚠ 时序：queue_free 只是把节点排进删除队列，本帧稍后才真正释放，
##   所以回调返回后到帧末之间本对象仍可访问（同一帧的另一根回调也可能再触发一次自毁，重复 queue_free 是安全的）。
## ⚠ 屏幕判定基于**相机可见区域**：如果相机视野之外的子弹永远不进屏幕（例如直接生成在屏幕外），
##   这个 notifier 会在它第一次进屏幕时才开始跟踪，理论上存在"出生在屏幕外且一直不回来"的子弹永不回收
##   —— 当前玩法里子弹都是朝着屏幕内打的，所以没暴露这个问题。
func _on_visible_on_screen_notifier_2d_screen_exited() -> void:
	queue_free()


## HitboxComponent.on_hit_hurtbox 回调：打到某个 Hurtbox 时自毁。
## 参数 hurtbox：被打中的那个 HurtboxComponent。**当前实现故意不用它** ——
##   真正的伤害结算发生在受击方（Hurtbox 侧反向通知它的 Unit），
##   投射物只需要"我打中了，我该消失了"这一个信息，所以连 Type 都用不上。
## 返回值：无。
## 副作用：**queue_free() 自己**。
## ⚠ 没有命中特效/音效：命中音是 HitboxComponent._on_area_entered 里无条件播的
##   （SoundManager ENEMY_HIT），爆炸粒子之类要在这里补（参考 scenes/effects/burst_effect.tscn）。
## ⚠ 自毁发生在物理回调链里，是安全的（queue_free 不动碰撞状态）；
##   但同一物理帧若同时擦到两个 Hurtbox，本函数会被调两次 → 两次 queue_free（幂等，无副作用）。
##   受击方那一侧才是"会不会吃两次伤害"的关键（见 hurtbox_component.gd 的说明）。
func _on_hitbox_component_on_hit_hurtbox(_hurtbox: HurtboxComponent) -> void:
	queue_free()
