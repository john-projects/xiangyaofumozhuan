## ═══════════════════════════════════════════════════════════════════════════
## SoundManager —— 全局音效播放器池（autoload 单例）
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   project.godot 的 [autoload] 里登记为 SoundManager="*uid://pnwjxb7rtm7r"，
##   而这个 uid 指的是 **场景** autoloads/sound_manager.tscn（不是裸脚本）——
##   那个场景挂了 10 个 AudioStreamPlayer 子节点，并用 node_paths 把它们连进下面的
##   stream_players 数组。所以这个"播放器池"是在编辑器里配置的，不是代码创建的。
##
## 为什么要有池：
##   同一个音效可能在同一帧被请求很多次（一刀扫到 5 个敌人 = 5 次 ENEMY_HIT）。
##   如果全项目共用一个 AudioStreamPlayer，后一次 play() 会打断前一次；
##   这里每次 play_sound() 都挑一个**当前没在播**的播放器，从而实现音效自然叠加。
##
## 数据流：
##   调用方（回合制战斗里的命中/施法、以及各种 UI 按钮按下时）→ SoundManager.play_sound(Sound.XXX)
##     → get_free_stream_player() 从池里取一个空闲播放器
##     → 把 sound_dictionary 里对应的 AudioStream 贴上去 → 随机音高 → play()
##   全程没有返回值、没有信号，属于"即发即忘"。
##
## 坑：
##   · 池子只有 10 个。同一瞬间超过 10 个音效时，play_sound() 会**静默丢音**
##     （get_free_stream_player() 返回 null 就直接 return），既不排队也不报错。
##   · 音源用 preload("uid://...") 写死在本文件里；换音效要么改 uid，要么改这里。
extends Node

## 音效种类。它既是 sound_dictionary 的键，也是外部唯一允许传给 play_sound() 的值。
## 成员没有显式指定数字，所以顺序不能随意调整；不过调用处都用符号名（Sound.UI），
## 所以不像 .tres 里存整数那样容易静默错位。
enum Sound {
	ENEMY_HIT,   # 0：命中判定生效时响（HitboxComponent._on_area_entered，武器攻击和敌人投射物都会触发）
	FIRE,        # 1：远程武器开火时响（RangeBehavior.execute_attack）
	UI           # 2：所有 UI 按钮点击（买/卖、选人、下一波、主菜单…）
}

## 音效表：Sound 枚举 → 真正的音频资源（用 uid 直接 preload，不走路径字符串）。
## 加一种音效的步骤：在 Sound 枚举末尾补成员 → 这里补一行 preload → 调用处 play_sound(Sound.新成员)。
## 类型标成 Dictionary[Sound, Resource]（类型化字典），键错用其它枚举值会被类型检查拦下。
var sound_dictionary: Dictionary[Sound, Resource] = {
	Sound.ENEMY_HIT: preload("uid://blonjlaa37md0"),   # 命中音
	Sound.FIRE: preload("uid://g72hyxdnaath"),         # 射击音
	Sound.UI: preload("uid://6nolwqlami52"),           # UI 点击音
	
}

## 播放器池（对象池）。实际值是 autoloads/sound_manager.tscn 里那 10 个 AudioStreamPlayer 的 NodePath 数组。
## 正因为 autoload 登记的是"场景"而不是本脚本，这个 @export 才有地方填写（裸脚本 autoload 没有检视面板）。
## 如果哪天把 SoundManager 改成裸脚本 autoload，这里就会是空数组 → play_sound() 永远第一行就 return，
## 表现为"游戏完全没声音"且不报任何错。
@export var stream_players: Array[AudioStreamPlayer]

## 播放一个音效。这是本文件唯一的对外接口。
## 参数 type：Sound 枚举值（形参写成 int 而不是 Sound，所以编译器不会帮你拦非法值）。
##   ⚠ 传一个没登记进 sound_dictionary 的整数，会在 sound_dictionary[type] 那一行直接运行时报错。
## 返回值：无。
## 副作用（都在音频子系统内，不影响任何游戏状态）：
##   · 从池里占用一个 AudioStreamPlayer —— 它会进入 playing = true，直到音频自然播完（无需手动归还）；
##   · 会覆盖该播放器上一次的 stream（所以不要指望它"播完再切"）；
##   · 池子被占满时**静默丢音**：不排队、不报错、不打印；
##   · 每次随机 pitch_scale = 0.8~1.3，这是刻意设计的 —— 让连续命中的同一个音效不显得机械。
## 时序说明：本函数不做任何帧/线程判断，因此在物理回调（如 area_entered）里调用是安全的：
##   它只改音频节点状态，不碰 collision、不 add_child/queue_free。
func play_sound(type: int) -> void:
	var stream := get_free_stream_player()
	if not stream:
		return
	var audio := sound_dictionary[type]
	stream.stream = audio
	stream.pitch_scale = randf_range(0.8, 1.3)   # 0.8~1.3 倍速：低于 1 更沉闷、高于 1 更清脆，避免"机关枪式"重复音
	stream.play()

## 从池里取一个当前空闲的播放器（对象池的"拿一个空槽位"）。
## 参数：无。
## 返回值：空闲的 AudioStreamPlayer；池子为空或 10 个全在播时返回 null。
## 副作用：无 —— 只读 stream.playing，不启动、不停止、不改变任何状态。
## 说明：AudioStreamPlayer 没有真正的"池"概念，这里的"空闲"就是用 playing 标志判断的；
##       音频播完后 playing 会自动变回 false，所以调用方不需要"归还"。
## 顺序含义：遍历顺序是确定的（从数组第 0 个开始找），所以池会被依次占满；
##   10 个播放器功能完全等价，顺序不影响听感，只是决定了"先用哪个"。
func get_free_stream_player() -> AudioStreamPlayer:
	for stream: AudioStreamPlayer in stream_players:
		if not stream.playing:
			return stream
	return null
