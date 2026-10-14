# 雷/斩击类特效序列帧（scenes/effects/thunder/）

由 DSH 依据 `assets/sprites/skills/skills/thunders/` 的素材生成，
实现方式对齐 `scenes/effects/fireball/effect_fireball_1.tscn`：
**Node2D 根 + AnimatedSprite2D 子节点 + 内嵌 SpriteFrames**，
动画名固定 `default`、`loop = 1`、`autoplay = "default"`。

## 场景清单

| 场景 | 素材目录 | 帧数 | speed(fps) |
|---|---|---|---|
| `effect_arcane_slash_down.tscn` | `_frames/arcane_slash_down_9x5_128px` | 33 | 33.33 |
| `effect_arcane_slash_up.tscn` | `_frames/arcane_slash_up_9x5_128px` | 33 | 33.33 |
| `effect_demon_slash.tscn` | `_frames/demon_slash_9x5_128px` | 75 | 33.33 |
| `effect_fire_slash_down.tscn` | `_frames/fire_slash_down_9x5_128px` | 45 | 33.33 |
| `effect_fire_slash_up.tscn` | `_frames/fire_slash_up_9x5_128px` | 45 | 33.33 |
| `effect_holy_slash_down.tscn` | `_frames/holy_slash_down_9x5_128px` | 42 | 33.33 |
| `effect_holy_slash_up.tscn` | `_frames/holy_slash_up_9x5_128px` | 42 | 33.33 |
| `effect_poison_slash_down.tscn` | `_frames/poison_slash_down_9x5_128px` | 42 | 33.33 |
| `effect_poison_slash_up.tscn` | `_frames/poison_slash_up_9x5_128px` | 42 | 33.33 |
| `effect_thunder_slash_down.tscn` | `_frames/thunder_slash_down_9x5_128px` | 36 | 33.33 |
| `effect_thunder_slash_up.tscn` | `_frames/thunder_slash_up_9x5_128px` | 36 | 33.33 |
| `effect_water_slash_down.tscn` | `_frames/water_slash_down_9x5_128px` | 42 | 33.33 |
| `effect_water_slash_up.tscn` | `_frames/water_slash_up_9x5_128px` | 42 | 33.33 |

`speed` 取自原始 GIF 的帧间隔（30 ms/帧 → 33.33 fps），单帧 `duration` 都是 1.0，
和 fireball 那套一致（想改播放速度只改 `SpriteFrames` 的 `speed` 即可）。

## 用法

这些都是**纯序列帧场景、没有脚本**，和 `effect_fireball_hit.tscn` 同一类。
公共弹道 `SkillProjectile` 会按 duck typing 处理：

* 命中特效：`SkillData.hit_effect_scene` 指向本目录任一场景 → 弹道发现它没有 `play()`，
  就走 `play_sequence_once()`：从头播一遍、按 `帧数 / speed` 定时停帧并自毁。
* 飞行外观：`SkillData.appearance_scene` 需要外观包（参考 `fireball_appearance.tscn`），
  直接塞纯素材场景只会被按 `projectile_scale` 缩放（见 `scenes/effects/README.md` 的兜底说明）。
* 手动播放：`anim.play(&"default")` / `anim.play(&"default", 2.0)` 控制速度。

## 素材事实（写场景时量出来的）

* 每帧画布 **128×128**，内容包围盒约 80~96 × 115~128 —— 内容基本占满画布，
  所以**不需要** fireball 那种 3~4 倍放大（火球素材 100×100 里只有约 43×21 有内容）。
* 每个 `NN.png` 都有配对的 `.import`（UID 已烘进场景），不要单独删 `.import`。
* 同目录 `GIF/` 里是原始 GIF，Godot 不能导入，仅作参考，可以移出工程。

## 预览

`effect_thunder_preview.tscn`：13 个场景按 4 列排开、各自 autoplay，
打开就能一眼对比全部配色/方向。只是查看用，不需要就删掉。

## 注意

* `effect_fireball_1.tscn` 里挂的脚本 `res://scenes/effects/fireball/effect_fireball_1.gd`
  **在工程里已经不存在了**（该场景加载时会报脚本缺失）。本目录的场景刻意没有根脚本，
  避免复制这个失效引用。
* 首次打开工程时 Godot 会为新场景补 `gd_scene uid` / 节点 `unique_id`，属于正常现象。
