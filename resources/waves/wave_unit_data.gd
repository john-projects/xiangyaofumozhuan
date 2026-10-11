extends Resource
class_name WaveUnitData

## 波次里的一个"敌人条目"：把一种敌人和它的抽中权重配成一对。
##
## ── 在系统里的位置 ──
##   WaveData.units 是 Array[WaveUnitData]，所以它是波次配置的最小单元。
##   Spawner.spawn_enemy() 每次要刷怪时都会调 WaveData.get_random_unit_scene()，
##   后者把本数组里所有条目的 unit_scene / weight 拆成两个平行数组，
##   再交给 RandomNumberGenerator.rand_weighted(weights) 抽一个场景出来实例化。
##
## ── 数据流向 ──
##   resources/waves/*.tres 里的本子资源 → WaveData.units → Spawner（挂 Arena 下）
##     → 每 wave_time 的 spawn_timer 到点 → 抽场景 → instantiate() 成 Enemy → 进场
##
## ── weight 的坑 ──
##   权重**不需要**加起来等于 1（rand_weighted 内部会先求总和再归一化）。
##   全部留默认 0.0 时 rand_weighted 退化成均匀分布（当前它们权重都为 0，
##   代码行为和"每种等概率"一致）；要自己配权重就让所有条目都 > 0，
##   别出现部分 0、部分正数的混合，否则 0 权重的条目永远抽不到，很容易误判成 bug。

## 要生成的敌人场景（根节点应为 Enemy，见 scenes/unit/enemy/）。
## 只有是 PackedScene 才能 instantiate()；路径留空会在 Spawner.spawn_enemy() 里
## 拿到 null 然后静默跳过本次刷怪（不会报错，表现为"这一波怪变少"）。
@export var unit_scene: PackedScene
## 该敌人在本波次被抽中的相对权重（无量纲，>= 0）。
## 默认 0.0：等于"不特别指定"，配合同数组其它条目全为 0 时退化为等概率随机。
@export var weight := 0.0
