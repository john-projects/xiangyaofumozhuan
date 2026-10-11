## ═══════════════════════════════════════════════════════════════════════════
## Unit —— 所有"战斗单位"（玩家 / 敌人）的公共基类
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   场景模板是 scenes/unit/unit.tscn，它的根节点类型是 **Area2D**，而本脚本 extends Node2D ——
##   这不冲突：Area2D 本身就是 Node2D 的子类。所有玩家场景（player_*.tscn）与敌人场景
##   （enemy_*.tscn）都是 unit.tscn 的实例，所以这里写的东西两队共用。
##   Player（scenes/unit/players/player.gd）与 Enemy（scenes/unit/enemy/enemy.gd）都 extends Unit，
##   它们覆盖 _ready() 时都必须调用 super._ready()（见下面的坑）。
##
## 本文件只干三件事：
##   1. 进场时把 UnitStats 灌进 HealthComponent（血量上限 + 满血 + 通知血条）
##   2. 挨打流程：死亡检查 → 格挡判定 → 白闪 → 扣血 → 请求飘字
##   3. 白闪结束后把 sprite.material 摘掉
##
## 数据流（从哪来到哪去）：
##   @export stats: UnitStats（.tres，位于 res://resources/units/{players,enemies}/）
##     → _ready() → health_component.setup(stats) → HealthComponent emit on_health_changed
##     → 场景里已连好的 HealthBar 刷新显示。
##   受击来源：HurtboxComponent.on_damaged 信号（连接直接写在 unit.tscn 末尾的 [connection] 段里，
##     本文件里没有 connect 语句）→ _on_hurtbox_component_on_damaged()。
##   表现输出：只 emit 全局信号，由 Arena 订阅后弹飘字 —— 本类不认识任何 UI 节点，
##     所以没有 UI 的场景里挨打也不会报错（没人监听就什么也不发生）。
##
## 关联文件：
##   · scenes/component/health_component.gd —— 真正管血量的组件；血量归零时它自己
##     owner.queue_free() 把整个单位删掉，**Unit 不负责销毁自己**。
##   · scenes/component/hitbox_component.gd —— 攻击方的判定框；本文件只从它身上读 damage。
##   · autoloads/global.gd —— 提供 FLASH_MATERIAL、两个飘字信号、以及格挡用的概率判定。
##
## 坑（改之前务必看）：
##   · 子类覆盖 _ready() 时**必须**调 super._ready()。否则下面那句 health_component.setup(stats)
##     永远不执行，HealthComponent 会停在自身默认值（max_health = current_health = 1.0）→
##     所有单位一碰就死，而且血条也一直是 1/1。
##   · %Visuals / %Sprite 用的是"场景唯一名"（unit.tscn 里勾了 unique_name_in_owner = true），
##     只能在**拥有该节点的场景**里这样访问；$AnimationPlayer / $HealthComponent / $FlashTimer
##     是普通节点路径 —— 改节点名要同步改这里，否则 @onready 得到 null。
##   · @onready 的赋值时机是"节点进树之后、_ready() 被调用之前"；在 _init() / _enter_tree() 里
##     这些变量还是 null，别在那儿用。
##   · _on_hurtbox_component_on_damaged() 这个函数名是 Godot 为"信号 → 方法"生成的约定名，
##     被 unit.tscn 里的 [connection] 直接按字符串引用 —— 重命名等于断开连接（编辑器里会显示悬空连接）。
extends Node2D
class_name Unit

## ── 数值 ────────────────────────────────────────────────────────────────
## 单位的数据来源（血量 / 速度 / 伤害 / 格挡率 / 幸运 / 掉落金币 …，定义见 resources/units/unit_stats.gd）。
## 单位：各字段单位不同，见 UnitStats 内的注释；这里是 Resource 引用，不是节点。
## 取值范围/默认值：unit.tscn 本身留空（null，因为基类没有合理的默认数值），
##   **每个**玩家/敌人场景都必须覆盖成自己的 .tres —— 没填的话 _ready() 里 setup(null) 立刻报错。
## 注意：这是共享的 Resource 实例，运行时 `stats.health += 1` 之类的就地修改会永久改掉这份数据
##   （Player.update_player_new_wave / Spawner.update_enemies_new_wave 就是这么干的）。
@export var stats: UnitStats

## ── 节点引用（全部来自 unit.tscn，子场景继承下来）──────────────────────────
##   Visuals         → 视觉根节点。单位的"左右朝向"就是靠它的负 X 缩放实现的，scale 默认 (0.5, 0.5)
##   Sprite          → 本体贴图，位置 (0, -58)，受击白闪材质贴在它身上
##   AnimationPlayer → 播放 idle / move / die（unit.tscn 里 autoplay = "idle"）
##   HealthComponent → 血量组件（普通子节点，不是 Area2D）
##   FlashTimer      → 白闪计时器；unit.tscn 里 wait_time = 0.2、one_shot = true（只响一次）
## 这些引用在子场景里也有效，节点名若在子场景被改掉，这里会拿到 null。
@onready var visuals: Node2D = %Visuals
@onready var sprite: Sprite2D = %Sprite
@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var health_component: HealthComponent = $HealthComponent
@onready var flash_timer: Timer = $FlashTimer

## 把 UnitStats 交给血量组件，完成单位的"出生初始化"。
## 生命周期时机：Godot 保证父节点 _ready() 在**所有子节点 _ready() 之后**才被调用，
##   所以这里能放心用 @onready 拿到的 health_component；而此时节点已经在场景树里了。
## 参数：无（数值取自 @export stats）。
## 返回值：无。
## 副作用：
##   · 修改 HealthComponent 的 max_health 与 current_health；
##   · HealthComponent 会 emit on_health_changed，unit.tscn 里该信号连着 HealthBar，
##     于是血条在开局的同一帧就被刷成满血；
##   · 子类（Player / Enemy）覆盖本函数时若不写 super._ready()，以上全部不会发生（见文件头"坑"）。
## 坑：setup() 是**把 current_health 直接设成满血**，不是"补满到上限"补差值。
##   所以运行期重复调用 = 原地回满血 —— Player.update_player_new_wave() 正是靠这一点实现"每波开局满血"。
# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	health_component.setup(stats)

## 给单位贴上受击白闪材质，并启动计时器准备摘掉它。
## 参数：无。
## 返回值：无。
## 副作用：
##   · **整体覆盖** sprite.material（不是叠加）：材质被换成 Global.FLASH_MATERIAL。
##     单位 sprite 平时没有材质，所以现在不丢东西；但若以后给单位 sprite 加了描边/染色材质，
##     受击一次就会被永久替换成白闪材质（本函数没有备份原材质）；
##   · Global.FLASH_MATERIAL 是 autoload 里 preload 出来的**共享 Resource 实例**，
##     全场所有单位共用同一份。谁要是就地改它的 shader_parameter，全体单位一起变色；
##   · flash_timer.start() 依赖场景里已设好的 wait_time = 0.2 与 one_shot = true。
##     ⚠ 如果哪天把 one_shot 改回 Timer 的默认值 false，计时器会**循环**触发 timeout，
##     sprite.material 就会每 0.2 秒被清一次、再被贴上，白闪变成持续闪烁，
##     而且 is_stopped() 会永远返回 false（任何拿它当"冷却完毕"判据的代码都会失效）。
func set_flash_material() -> void:
	sprite.material = Global.FLASH_MATERIAL
	flash_timer.start()

## 受击入口 —— 单位的"挨打总流程"。
## 信号来源：unit.tscn 里 HurtboxComponent 的 on_damaged 信号（编辑器连接，代码里没有 connect）。
## 参数 hitbox：打中我们的那个攻击判定框（HitboxComponent）。本函数只读它的 damage；
##   Enemy 的覆盖版本还会读 knockback_power 与 source（攻击者节点），用来算击退方向。
## 返回值：无。
## 副作用（三条路径三选一）：
##   · 已死亡 → 直接 return，什么都不做（防止尸体继续被判格挡、继续扣血）；
##   · 格挡成功 → emit Global.on_create_block_text(self)，Arena 订阅后弹 "Blocked!" 飘字，**不扣血**；
##   · 否则 → set_flash_material() 贴白闪 + 启动 FlashTimer；
##            health_component.take_damage(hitbox.damage)（血量归零时 HealthComponent 自己 emit
##            on_unit_died 并 owner.queue_free() 销毁本单位）；
##            emit Global.on_create_damage_text(self, hitbox)（Arena 用 hitbox.critical 决定飘字颜色）。
## 时序 / 坑：
##   · "是否已死"用 current_health <= 0 判断（而不是等死亡信号），因为物理帧里可能同时来多个判定框；
##   · 格挡率是**百分数**，所以这里除以 100 才喂给 Global.get_chance_success()（它只认 0~1 的小数）；
##   · Global.get_chance_success() 会推进全局随机数序列 —— 挨一次打会间接影响之后的掉落/抽卡随机结果；
##   · 飘字里显示的是 hitbox.damage（攻击方的原始伤害），不是实际扣掉的血量：
##     致死那一下（比如剩 3 血挨 10 点）飘字会显示 10，这是刻意的"打出多少显示多少"。
func _on_hurtbox_component_on_damaged(hitbox: HitboxComponent) -> void:
	if health_component.current_health <= 0:
		return
	var blocked := Global.get_chance_success(stats.block_chance / 100)
	if blocked:
		Global.on_create_block_text.emit(self)
		return
	
	set_flash_material()
	health_component.take_damage(hitbox.damage)
	Global.on_create_damage_text.emit(self, hitbox)
	

## 白闪结束回调。
## 信号来源：unit.tscn 里 FlashTimer.timeout → 本方法（参数为空，Timer.timeout 不带参数）。
## 参数：无。
## 返回值：无。
## 副作用：把 sprite.material 置回 null，也就是"摘掉白闪"。
## 坑：
##   · 置 null 的语义是"没有材质"，前提是单位 sprite 平时本来就没材质；
##     如果受击之前挂过材质，这里会连它一起抹掉（原材质没有备份，见 set_flash_material 的说明）；
##   · FlashTimer 在 unit.tscn 里是 one_shot = true，响一次就自动停，不需要在这里再 stop()；
##   · 单位在这 0.2 秒内被打死的话，本方法可能在节点被 queue_free 之后才触发 ——
##     Godot 释放节点时会连带断开它的信号连接，所以不会执行到已释放的对象上。
func _on_flash_timer_timeout() -> void:
	sprite.material = null
