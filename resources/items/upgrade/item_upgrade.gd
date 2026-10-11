## ═══════════════════════════════════════════════════════════════════════════
## ItemUpgrade —— 波次结算时给出的"整局属性升级"
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   ItemBase 的子类，item_type 固定为 ItemType.UPGRADE（.tres 里写 item_type = 1）。
##   它和 ItemPassive 的区别：只会"加"，不会扣；且只出现在波次结束后的升级面板里（四选一），
##   不进商店、不影响背包。
##
## 数据流（从哪来到哪去）：
##   resources/items/upgrade/data/<属性>/upgrade_<属性>_<档位>.tres（按 damage / health /
##   block / harvesting / hp_regen … 分目录，每个目录若干档）
##     → Arena 的 UpgradePanel.upgrade_list 是候选池
##     → 每波打完：Spawner 的 wave_timer 超时 → Arena._on_spawner_on_wave_completed()
##       → 等 1.5 秒 → Arena.show_upgrades() → UpgradePanel.load_upgrade(当前波数)
##     → Global.select_items_for_offer(upgrade_list, 波数, Global.UPGRADE_PROBABILITY_CONFIG) 抽 4 张
##     → 实例化成 UpgradeCard（卡片直接显示本类的 description 纯文本）
##     → 玩家点一张 → UpgradeCard._on_custom_button_pressed() → 调本文件的 apply_upgrade()
##     → 紧接着 emit Global.on_upgrade_selected → Arena 关掉升级面板、打开商店面板
##
## 坑：
##   · stat_id 是字符串键，直接喂给 Global.player.stats.get/set()。写错只会运行时炸，
##     可用键名见 resources/units/unit_stats.gd 的 @export 变量名。
##   · 本类没有重写 get_description()（基类返回空串），提示卡上显示的是纯文本的 description 字段；
##     两者别搞混：description 是给 UpgradeCard 用的，get_description() 是给悬停提示卡用的。
extends ItemBase
class_name ItemUpgrade

@export var value: float          # 本次要加多少（增量，不是覆盖值）。单位随 stat_id 而定：damage 档在 .tres 里是 1.0~9.0，health 档是 1.0~10.0
@export var description: String   # 升级卡上显示的纯文本，例如 "+ 1"；不是 BBCode，直接塞进 Label.text
@export var stat_id: String       # 目标属性名，必须是 UnitStats 的 @export 字段名，如 "damage" / "health" / "block_chance" / "harvesting"

## 把本次升级加到玩家属性上。由 UpgradeCard._on_custom_button_pressed() 在玩家点选卡片时调用一次。
## 副作用（本文件唯一的副作用点）：
##   · 就地修改 Global.player.stats（UnitStats，Resource 共享引用）上的字段，永久生效、无回滚；
##   · 不 emit 信号 —— 升级流程的推进（关升级面板 → 开商店面板）是 UpgradeCard 那侧 emit
##     Global.on_upgrade_selected 完成的，不是这里；
##   · 不做上下限钳制（block_chance 这类百分比属性理论可以被加到 100 以上）。
## 参数：无（用自身的 stat_id / value）。
## 返回值：无。
## 实现细节：因为走的是 get/set + 显式 float() 转换，所以静态类型检查不会报错，
## 但 stat_id 不存在时 get() 返回 null，as float 会得到 0.0 —— 表现为"这次升级静默无效"。
func apply_upgrade() -> void:
	var current_value := Global.player.stats.get(stat_id) as float      # 属性名不存在时 get() 给 null，as float 静默变成 0.0
	var new_value := float(value) + float(current_value) 
	Global.player.stats.set(stat_id, new_value)                         # 与 ItemPassive 的改法等价，只是这里用 set() 而不是 [] 索引
