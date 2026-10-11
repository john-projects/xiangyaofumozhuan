extends Resource
class_name WaveData

## 本波次的刷怪方式。
## FIXED = 固定间隔（每 fixed_spawn_time 秒出一只，节奏可预测）；
## RANDOM = 在 [min_spawn_time, max_spawn_time] 之间随机取下一次间隔（节奏不可预测，高压感）。
## 枚举值会被写进 .tres，不要调整成员顺序。
enum SpawnType {
	FIXED,
	RANDOM
}

## 本配置从第几波开始生效（波次序号从 1 开始，Spawner.wave_index 初值就是 1）。
## ⚠ 没有默认值 = 默认 0，比第 1 波还小，所以**任何波次都能匹配上**：
##   如果 .tres 里忘了填 from/to，这份配置会变成"万能兜底"，把后面所有波次都吃掉。
@export var from: int
## 本配置生效到第几波为止（闭区间，含 to）。配合 from 形成一个波次区间。
## 同样没有默认值：from=0 / to=0 的默认组合会让 is_valid_index() 对任何 wave_index >= 1 都返回 false，
## 也就是这份配置谁也匹配不到 —— 排查"某一波不刷怪"时先看这两个字段。
@export var to: int
## 一波持续多少秒（交给 Arena 场景里的 WaveTimer 当 wait_time）。
## 默认 20.0：够玩家清完一波杂兵又不至于干等；改小 = 压力更大、产出更快。
@export var wave_time := 20.0
## 本波可刷的敌人条目列表（每种敌人 + 权重）。留空的话 get_random_unit_scene() 会 printerr 并返回 null。
@export var units: Array[WaveUnitData]

## 刷怪间隔模式。默认 RANDOM：随机节奏比固定节奏更像"被包围"，也让玩家更难预测。
@export var spawn_type := SpawnType.RANDOM
## FIXED 模式下的固定刷怪间隔（秒）。默认 1.0 = 每秒一只。
@export var fixed_spawn_time := 1.0
## RANDOM 模式的间隔下限（秒）。默认 1.0。
@export var min_spawn_time := 1.0
## RANDOM 模式的间隔上限（秒）。默认 1.0 —— 三个时间字段默认全是 1.0，
## 于是"随机"和"固定"在默认值下行为一致，改了才有区别。
## ⚠ 如果 min > max，randf_range(min, max) 会返回 min 并打印告警，表现是"间隔恒为 min"。
@export var max_spawn_time := 1.0

## 按权重随机抽一个敌人场景。Spawner 每次刷怪都会调它一次。
## 参数：无。
## 返回值：被抽中的 PackedScene；units 为空时返回 null（并已经 printerr 打过错误）。
## 副作用：**只读**本 Resource，不改任何字段、不发信号、不碰节点（纯函数，除了打日志）。
## 实现细节与坑：
##   · 先把 units 拆成两个平行数组 enemies（场景）和 weights（权重），因为 rand_weighted() 只吃 float 数组；
##   · rng 是函数内**新建**的 RandomNumberGenerator —— 好处是不影响全局随机数种子，
##     代价是它没有手动 randomize()/seed，Godot 4 的 RNG 默认由随机熵初始化，
##     所以连续两次调用一般不会返回同一个结果；但也意味着这个函数的随机**不可复现**，
##     以后要做"固定种子的战斗回放"必须改成注入共享的 rng；
##   · rng.rand_weighted(weights) 返回的是**下标**，不是权重值，用它去索引 enemies 数组；
##   · 权重全为 0 时退化为均匀随机（所以 WaveUnitData.weight 全留默认也能用）；
##   · 数组里若混进 unit_scene = null 的条目（PackedScene 字段留空），它照样可能被抽中，
##     返回值就是 null —— Spawner 那边会 if enemy_scene 判断后跳过这一次刷怪，不报错。
func get_random_unit_scene() -> PackedScene:
	if units.is_empty():
		printerr("not units.")
		return null
	var enemies: Array[PackedScene]
	var weights: Array[float]
	
	for unit in units:
		enemies.append(unit.unit_scene)
		weights.append(unit.weight)
		
	var rng := RandomNumberGenerator.new()
	var random_unit = enemies[rng.rand_weighted(weights)]
	return random_unit
		
## 判断某个波次序号是否落在本配置的生效区间内（闭区间 [from, to]）。
## 参数 wave_index：波次序号，从 1 开始（Arena.start_new_wave() 里 spawner.wave_index += 1）。
## 返回值：true 表示本配置负责这一波。
## 副作用：无（纯判定）。
## 用途：Spawner.find_wave_data() 遍历 waves_data，返回**第一个**匹配的配置 ——
##   所以 waves_data 数组里的顺序有意义：区间重叠时排在前面的优先，后面那份永远不会被选中。
## ⚠ 因为它同时判断两段，from 忘填（=0）而 to 正常时，前面那些波次也会被它匹配，容易造成"配置串味"。
func is_valid_index(wave_index: int) -> bool:
	return wave_index >= from and wave_index <= to
