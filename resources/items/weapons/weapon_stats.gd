## ═══════════════════════════════════════════════════════════════════════════
## WeaponStats —— 一把武器的全部数值（Resource，纯数据容器，零逻辑）
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   被 ItemWeapon.stats 引用，再由 Weapon.setup_weapon() 和两个 behavior 脚本读取。
##   想调平衡只改 .tres，不用改代码。
##
## 数据流（从哪来到哪去）：
##   resources/items/weapons/<melee|range>/<武器名>/stats_<武器名>_<档位>.tres（全工程 44 处引用）
##     → ItemWeapon.stats
##     → Player.add_weapon() 实例化 Weapon 场景 → Weapon.setup_weapon(data) 用它设索敌半径
##     → 每帧：Weapon._process() 判冷却、算散布；behavior.execute_attack() 才真正挥砍 / 发射
##
## 谁读哪个字段（这就是本文件的"用途索引"）：
##   damage / crit_chance / crit_damage            → WeaponBehavior.get_damage()
##   cooldown                                      → Weapon.use_weapon() → CooldownTimer.wait_time
##   accuracy                                      → Weapon.calculate_spread()
##   max_range                                     → Weapon.setup_weapon()（索敌半径）+ MeleeBehavior（前冲距离）
##   knockback                                     → HitboxComponent.setup() → Enemy.apply_knockback()
##   life_steal                                    → WeaponBehavior.apply_life_steal()
##   recoil / recoil_duration / back_duration      → MeleeBehavior / RangeBehavior 里的 tween
##   projectile_scene / projectile_speed           → RangeBehavior.create_projectile()
##   attack_duration                               → ⚠ 目前没有任何代码读取它（历史遗留字段）
##
## 坑：
##   · 下面 := 后面的默认值只在"新建 .tres 且没填"时生效。已经存在的 .tres 里存的是写死的数值，
##     改这里的默认值不会影响它们。
##   · accuracy 与 life_steal 的单位跟 UnitStats 里的同名字段**不一样**（见各自注释）。
extends Resource
class_name WeaponStats

## ── 伤害与命中 ──────────────────────────────────────────────────────────
@export var damage := 1.0                            # 基础伤害（点）。最终伤害 = 本值 + Global.player.stats.damage，暴击再 × crit_damage 后向上取整
@export_range(0.0, 1.0) var accuracy := 0.9          # 命中精度 0~1（编辑器滑条 0.0~1.0）。1 = 完全不抖，0 = 最大抖动。⚠ 单位是**弧度**：散布 = randf_range(-1+accuracy, 1-accuracy)，且 weapon_spread 逐次累加、从不清零，所以连续攻击会越打越偏（现存行为，未修）
@export_range(0.5, 3.0) var cooldown := 1.0          # 两次攻击的间隔（秒），编辑器限制 0.5~3.0。直接写进 CooldownTimer.wait_time（那个 Timer 在场景里是 one_shot = true）
@export_range(0.0, 1.0) var crit_chance := 0.05      # 暴击概率 0~1（0.05 = 5%）。判定走 Global.get_chance_success()，即 randf_range(0,1) < 本值
@export var crit_damage := 1.5                       # 暴击伤害倍率（1.5 = 150%）。计算式 damage = ceil(damage * crit_damage)
## ── 索敌范围与命中附加效果 ──────────────────────────────────────────────
@export var max_range := 150.0                       # 索敌半径（像素）。Weapon 把它写成 RangeArea 里 CircleShape2D 的 radius；⚠ 该 shape 是场景子资源，同一武器场景的多个实例共享同一个圆（同名多把武器半径相同，所以平时看不出问题）。近战还会把这个值当前冲距离用
@export var knockback := 0.0                         # 击退力度（无量纲倍数）。Enemy 里最终位移 = (移动方向 + 击退方向 × 本值) × stats.speed × delta，所以 1.5 约等于"以 1.5 倍速度被顶开"。0 = 不击退
@export_range(0.0, 1.0) var life_steal := 0.0        # 吸血概率 0~1（0.05 = 5%）。⚠ 和 UnitStats.life_steal 单位不同：那边填的是百分数，代码先 /100 再和这里的值相加（见 WeaponBehavior.apply_life_steal）。吸血成功固定回 1 点血
## ── 挥击动作（近战前冲 / 远程后座），全部是作用在 sprite.position.x 上的 tween ──
@export var recoil := 25.0                           # 起手位移（像素）。两个 behavior 都是先挪到 sprite.position.x - recoil（向"后"撤），再 tween 回去；近战=向后蓄力，远程=枪身后座
@export_range(0.1, 3.0) var recoil_duration := 0.1   # 上面那段位移的 tween 时长（秒），编辑器限制 0.1~3.0。近战和远程都用它
@export_range(0.1, 3.0) var attack_duration := 0.2   # ⚠ 声明了但**当前代码里没有任何地方读取**（近战前冲复用了 recoil_duration）。留作未实现参数，改它没有任何效果
@export_range(0.1, 3.0) var back_duration := 0.15    # 近战挥完从最远处回到 atk_start_pos 的 tween 时长（秒）。只有 MeleeBehavior 用它；RangeBehavior 用 recoil_duration 回位
## ── 远程弹道（只有挂 RangeBehavior 的武器会用到）────────────────────────
@export var projectile_scene: PackedScene            # 子弹场景（根节点必须是 scenes/projectiles/projectile.gd 的 Projectile）；留空会在 RangeBehavior.create_projectile() 里直接报错
@export var projectile_speed := 1600.0               # 子弹速度（像素/秒）。velocity = Vector2.RIGHT.rotated(武器朝向) * 本值，然后每帧 position += velocity * delta
