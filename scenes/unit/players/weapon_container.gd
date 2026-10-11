## ═══════════════════════════════════════════════════════════════════════════
## WeaponContainer —— 武器挂点容器：把手上的武器摆到预设"阵型"的位置上
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   它是 player_well_rounded.tscn 里玩家根节点下的一个 Node2D 子节点（挂本脚本）。
##   玩家不是它的子节点，**武器也不是** —— 武器挂在玩家根节点下（见 Player.add_weapon）。
##   所以本脚本只做一件事：把武器节点搬到"标记点"的世界坐标上。
##
## 场景里的结构（这张表就是"阵型表"）：
##   WeaponContainer
##     ├─ One   → 1 个 Marker2D（1 把武器时的位置）
##     ├─ Two   → 2 个
##     ├─ Three → 3 个
##     ├─ Four  → 4 个
##     ├─ Five  → 5 个
##     └─ Six   → 6 个
##   每套布局的子节点数 = 该数量下的武器数，位置是手摆的（例如 Six = 2 下 + 2 上 + 2 侧）。
##   注意 Marker 的**名字**不参与配对（Marker2D / Marker2D2 / … 只是编辑器自动命名），
##   真正决定配对的是 get_children() 的**顺序**，也就是场景树里的节点顺序。
##
## 数据流：
##   Player.current_weapons（场上真实的 Weapon 节点，顺序 = 获得顺序）
##     → Player.add_weapon() 调用 update_weapons_position()
##     → 本脚本按数量选一套布局，逐个把 weapons[i].global_position 设成 markers[i].global_position
##
## 坑（改之前务必看）：
##   · 只在"新增武器"时被调用一次：卖出 / 合成删掉武器之后**没人重排**，
##     剩余武器会停在原位（视觉上留空档）；又因为数组顺序 = 获得顺序，
##     卖掉中间的武器还会让后面的武器"占着别人的位置"；
##   · 赋值用的是 global_position：Marker 的位置写在玩家本地坐标系里，赋值那一刻换算成世界坐标 ——
##     所以玩家移动中摆位也是安全的（武器同样是玩家的子节点，之后随父一起移动）；
##   · count 为 0 或 > 6 时 match 不会给 reference_node 赋值，下一行直接 null 报错（详见函数注释）。
extends Node2D
class_name WeaponContainer

## ── 阵型布局节点（$ 普通路径，不是唯一名）────────────────────────────────
## 六个布局节点，名字直接表示"适用于几把武器"：
##   One → 1 把，Two → 2 把 …… Six → 6 把（6 同时也是武器上限，由 ShopCard 在购买前检查）。
## 每个节点的子节点是若干 Marker2D，它们的 position 就是该数量下的摆放位置。
@onready var one: Node2D = $One
@onready var two: Node2D = $Two
@onready var three: Node2D = $Three
@onready var four: Node2D = $Four
@onready var five: Node2D = $Five
@onready var six: Node2D = $Six

## 按武器数量重排所有武器的位置。
## 谁调用：Player.add_weapon()（每新增一把武器就整体重排一次）。
## 参数 weapons：玩家场上的武器节点数组（通常就是 Player.current_weapons，**顺序 = 获得顺序**）。
## 返回值：无。
## 副作用：修改 weapons 里每个 Weapon 节点的 global_position。
##   不改数组本身、不 emit 信号、不 add/remove 任何节点。
## 实现细节：
##   · `match count:` 把数量映射到布局节点。⚠ count 为 0 或者大于 6 时没有任何分支命中，
##     reference_node 会保持**未初始化的 null**，紧接着 reference_node.get_children() 直接报
##     "null instance" 错误。目前唯一的调用点（Player.add_weapon，先 append 再调用）保证 count ≥ 1；
##     若以后在"卖出武器之后"也调用本函数，count = 0 就会炸；
##   · `if markers.size() != count: return` 是数据自检：布局里的 Marker 数与武器数不一致时整批放弃
##     （不做部分摆放）。改场景时若某套布局少摆/多摆一个 Marker，那个数量的武器就**永远不排位**
##     （静默失效，没有任何报错）；
##   · `for i in count:` 是 GDScript 惯用法：用整数当范围，等价于 range(count)，即 0…count-1；
##   · 用 global_position 而不是 position：Marker 的世界坐标包含了玩家（父链）的变换，
##     赋给同属玩家子节点的武器，两边基准一致。
func update_weapons_position(weapons: Array[Weapon]) -> void:
	var count := weapons.size()
	# 声明时没有初始化：如果下面的 match 一个分支都没命中（count 为 0 或 > 6），它就是 null。
	var reference_node: Node2D
	# 数量 → 布局节点。六个分支对应 One..Six，命名与"武器数"一一对应。
	match count:
		1: reference_node = one
		2: reference_node = two
		3: reference_node = three
		4: reference_node = four
		5: reference_node = five
		6: reference_node = six
		
	# 取该布局下的全部 Marker；顺序就是场景树里的顺序，也是武器的配对顺序。
	var markers := reference_node.get_children()
	# 自检：Marker 数与武器数不符就直接放弃（宁可不动，也不做"摆一半"）。
	if markers.size() != count:
		return
		
	# i 同时充当"第几把武器"和"第几个 Marker"。global_position 是把 Marker 的本地坐标
	# 把 Marker 的本地坐标（写在玩家坐标系里）换算成世界坐标后赋给武器 —— 两者父节点相同，基准一致。
	for i in count:
		weapons[i].global_position = markers[i].global_position
