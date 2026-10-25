## ═══════════════════════════════════════════════════════════════════════════
## FloatingText —— 飘字（伤害数字 / "Blocked!" / "+N" 回血数字）
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   纯表现层。它是 Global.FLOATING_TEXT_SCENE（uid://btdihrlsugqm0）指向的场景所挂的脚本；
##   谁要飘字就 instantiate() 它。本文件不读也不写 Global，不发任何信号，
##   对玩法数值零影响 —— 只是"把一串已经算好的文字弹出来再删掉"。
##
## 谁在用它：
##   回合制战斗：scenes/battle/battle.gd 的 create_floating_text() 生成它（伤害 / "Blocked!" 数字），
##   挂到 Battle 的 %Fx 下面，所以飘字跟着战斗屏幕走。
##   （竞技场时代那条"实时战斗链 + Arena.create_floating_text"已经随竞技场一起移除。）
##
## 数据流：
##   （文案 String，颜色 Color）由调用方给出 → setup() 写进 $ValueLabel.text 与 self.modulate
##   → 内部 tween 播一段动画 → 动画结束自己 queue_free()。调用方不需要回收它。
##
## 生命周期顺序（关键，写错了会崩）：
##   Battle 的用法是：instantiate() → add_child() → 摆 global_position → 最后才调 setup()。
##   这个顺序**必须**保持：setup() 里要写 @onready var value_label，而 @onready 只在
##   "节点进入场景树"那一刻之后才有值；如果先 setup() 后 add_child()，value_label 还是 null，
##   第一行赋值就会报 "Cannot set property 'text' on a null instance"。
##
## 坑：
##   · setup() 是 async（函数体里有 await）：调用方**不加 await 也完全正常** ——
##     函数会一路执行到 await 那一行才"挂起"，返回的是一个协程信号而不是等它结束；
##     所以 Battle 直接 text.setup(...) 不管它，飘字照样会在动画结束后自己消失。
##   · 动画总时长不是 0.4 + 0.5 + 0.4，而是 ≈ 0.9 秒，原因见 setup() 里的详细说明
##     （parallel() 的实际语义和直觉不同）。
##   · 因为末尾是 queue_free()，调用方在 setup() 之后**不能再**对这个实例做假定它一直活着的事；
##     需要额外逻辑请在 await tween.finished 之前做。
extends Node2D
class_name FloatingText

## $ValueLabel 用的是**普通子节点路径**（floating_text.tscn 里没勾 unique_name_in_owner，
## 所以不能用 %ValueLabel）。字号 32、黑色 10 像素描边写在那个节点的 LabelSettings 子资源上，
## 本脚本只负责文字内容和整体 modulate（颜色）。
@onready var value_label: Label = $ValueLabel

## 播放一次飘字：弹入 → 随机微旋转 → 缩回并淡出 → 自毁。
## 参数 value：要显示的最终文本（例如 "12"、"Blocked!"）。本函数**不做**任何
##   格式化或单位换算，来的什么就显示什么；数字转字符串是调用方（Battle.create_floating_text）做的。
## 参数 color：整条飘字的颜色。写的是 self.modulate 而不是 value_label.modulate，
##   所以它会连描边一起染色（Label 的 outline 也会被 modulate 乘算）—— 这是刻意的，浅色文字配黑边更清楚。
##   Battle 按来源传：普通伤害 normal_color、暴击 critical_color、格挡 blocked_color。
## 返回值：无（函数体里有 await，严格说返回的是协程信号；调用方忽略它即可，但**不要** await 后再操作本节点，
##   因为那时它已经被 queue_free() 了）。
## 副作用（按时间顺序）：
##   1) 立刻把 scale 归零 —— 所以飘字是从"看不见"弹出来的，而不是突然出现；
##   2) 随机旋转 ±10°、随机目标倍率 0.8~1.6，让同屏多个飘字不会整齐划一（randf_range 用的是全局随机数，
##      会推进随机序列，和抽卡共用同一个随机源）；
##   3) create_tween() 建的 tween 是**绑定在本节点上**的（Node.create_tween 的语义），
##      所以本节点被提前释放时 tween 会自动失效，不会留下野指针；
##   4) 动画结束后 queue_free() 自己，调用方不需要（也不应该）再释放它。
func setup(value: String, color: Color) -> void:
	value_label.text = value
	modulate = color
	scale = Vector2.ZERO
	
	# 不旋转：数字歪着显示会看不清，统一水平摆放（同屏多个靠位置和缩放错开就够）。
	rotation = 0.0
	# 随机"目标倍率"：0.9~1.35 倍。第一条 tween 就是放大到它，后面再缩回 1.0，形成回弹感。
	var random_scale := randf_range(0.9, 1.35)
	
	# create_tween() 是 Node 的方法：tween 由本节点驱动，节点没了 tween 自动失效，
	# 不需要手动 kill；飘字会照常播完、照常自毁。
	# 时序（全部用 chain() 明确切成四段，别再用 parallel() 猜语义）：
	#   ① 0~0.22s  弹入：scale 0 → random_scale、同时上浮 18px
	#   ② 0.22~0.34s 回弹：scale → 1.0
	#   ③ 0.34~0.72s 停留：满不透明度、不再移动（⚠ 这段是"看得清"的关键，删了数字会一闪就没）
	#   ④ 0.72~0.95s 淡出：alpha → 0，然后自毁
	var tween := create_tween()
	tween.tween_property(self, "scale", random_scale * Vector2.ONE, 0.22)
	tween.parallel().tween_property(self, "global_position", global_position + Vector2.UP * 18.0, 0.22)
	tween.tween_property(self, "scale", Vector2.ONE, 0.12)
	tween.tween_interval(0.38)
	tween.tween_property(self, "modulate:a", 0.0, 0.23)
	
	# await 等的是整个 tween 的 finished 信号；等到之后本节点已经没人引用，
	# 直接 queue_free() 自毁 —— 这是本文件唯一的"销毁"动作，调用方无需回收。
	# 注意：await 之后函数才真正结束；在它之前本节点都还活着（可以再被外部访问），之后就是野引用了。
	await tween.finished
	queue_free()
