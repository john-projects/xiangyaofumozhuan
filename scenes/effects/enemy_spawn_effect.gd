## 敌人出场特效：在刷怪点闪一下"召唤阵"标记，播完就消失。
##
## ── 在系统里的位置 ──
##   scenes/effects/enemy_spawn_effect.tscn 的根脚本：根是 Sprite2D（贴图 = Spawn_mark.png），
##   下面挂一个 AnimationPlayer。它**不负责生成敌人**，只负责"演出"。
##   真正的刷怪节奏在 scenes/arena/spawner.gd 的 spawn_enemy()：
##     实例化本特效 → add_child 到 Spawner 的父节点（Arena）→ 设 global_position
##     → await anim_player.animation_finished → queue_free() → 再实例化敌人
##   也就是说敌人是在特效**播完之后**才出现的，两者共用同一个 spawn_pos。
##
## ── 为什么在 Arena 下而不是 Spawner 下 ──
##   Spawner 自己是个逻辑节点（信号/计时器），特效挂在它的同级（get_parent()）
##   才能保证坐标不被 Spawner 的变换影响，并且不受 Spawner 内部的层级遮挡影响。
##
## ── 数据流 ──
##   Global.SPAWN_EFFECT_SCENE（preload 的场景常量）→ Spawner 实例化 → 播放动画 → 自毁。
##   本脚本没有任何 @export、没有信号、不改 Global、不碰存档 —— 纯表现层，删掉不影响玩法逻辑
##   （但 Spawner.spawn_enemy() 里那句 await 就会永久挂住，所以别单独删场景）。

extends Sprite2D
class_name EnemySpawnEffect

## 指向本场景里唯一的 AnimationPlayer 子节点。
## ⚠ 时序：@onready 在节点进入场景树、_ready() 之前才赋值，
##   所以在这个脚本里能安全用的是 _ready 及之后，而不能在 _init 里访问；
##   又因为根脚本没有重写 _ready/_process，本变量目前只是给外部（Spawner）读的句柄。
## ⚠ 用 $ 普通路径而不是 %（unique_name_in_owner）取节点：改子节点名字或层级会直接报错，
##   改名时要同步改这里。
## 动画库在 .tscn 里配了两个动画：RESET 和 spawn，其中 spawn 的 autoplay = &"spawn"，
## 所以特效一被 add_child 进场景树就会自动开始播 0.8 秒的闪烁；Spawner 等的就是这个动画的 animation_finished。
@onready var anim_player: AnimationPlayer = $AnimationPlayer
