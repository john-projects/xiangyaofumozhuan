# 技能特效：公共弹道 + 元素外观包（scenes/effects/）

## 分工

```
scenes/effects/projectile/skill_projectile.tscn / .gd   ← 公共弹道（所有元素共用）
scenes/effects/burst_effect.tscn / .gd                  ← 默认命中爆炸（闪光/冲击波/火星/浓烟）
scenes/effects/effect_tex.gd                            ← 程序化贴图工厂（glow/dot/ring/smoke/additive/mix/curve/ramp/tint_ramp）
scenes/effects/projectile/…                             ← 之后冰/雷等元素的外观包也放这一类目录
```

| | 公共弹道 | 元素外观包 |
|---|---|---|
| 职责 | 生成位置、飞行位移、拖尾线、命中爆炸、自毁 | "这个元素长什么样"：序列帧、粒子层、配色、配比 |
| 节点 | `%Trail`（Line2D，世界坐标）/ `%Visual` → `%Sprite`（静态贴图）+ `%Appearance`（插槽）/ `%Burst`（兜底粒子） | 例：`%EffectXxx`（帧动画）+ `%FireCore` / `%FireBlob` / `%TrailParticles` / `%Sparks` / `%Smoke` |
| 允许出现的字眼 | 只有通用词（visual / sprite / appearance / trail / burst） | 元素词随便用（fire / ice / spark…） |
| 读取数据 | `projectile_texture` / `projectile_scale` / `projectile_speed` / `tint` / `hit_effect_scene` / `burst_scale` / `hit_particles` / `appearance_scene` | 自己决定读哪些（外观包读 `sequence_frame_scene` / `frames_only` / `flight_particle_ratio` / `show_smoke_trail` / `projectile_scale` / `tint` / `hit_particles`） |

## 外观包契约（鸭子类型，两个都可选）

| 方法 | 何时被调 | 该做什么 |
|---|---|---|
| `setup_effect(projectile: Node2D, skill: SkillData)` | 公共弹道 `setup()` 里，外观已 add_child 之后 | 照 SkillData 配置自己（换素材、缩放、粒子密度、染色） |
| `stop_flight()` | 公共弹道 `burst()` 里（命中瞬间） | 停发射 + 藏帧动画，但**不要 queue_free** —— 让已喷出的粒子自然消亡 |

两个都不实现也能用：那它就只是挂在插槽里的一个静态装饰。
**兜底**：如果挂进来的场景没有 `setup_effect()`（例如直接把纯素材场景 `某个纯序列帧特效场景` 塞进
`SkillData.appearance_scene`），公共弹道会按 `projectile_scale` 缩放它 —— 但**只缩放**：
染色、粒子层、换帧配色都要靠外观包自己实现。所以正式用法仍然是挂外观包。
外观包要调公共弹道时，用 `setup_effect` 收到的 `projectile` 参数（`projectile.global_position` 等）。

## 命中爆炸的两种形态

`SkillData.hit_effect_scene` 留空 = 默认 `burst_effect.tscn`（程序化四层，有 `play(tint, count)`）；
填了就用你的场景，公共弹道按 duck typing 选择播法：

- 有 `play()` → `boom.play(tint, count)`（程序化爆炸自己染色排布）；
- 没有 `play()`（纯序列帧，例如 `某个纯序列帧特效场景`）→ `SkillProjectile.play_sequence_once(boom)`：
  从头播一遍、按"帧数 / fps"定时停帧并自毁。

`burst_scale` 控制整体缩放（爆裂投射物 1.8；群体技能的"每敌人一朵小爆炸"再乘 `Battle.AOE_TARGET_BURST_RATIO` = 0.55）。

## 加一个新元素（以寒冰箭为例）

1. 复制 `scenes/effects/` 里现成的特效场景 整个目录 → `scenes/effects/ice/`；
2. 把帧动画换成冰的序列帧（`effect_ice_1.tscn`…），没有素材就先用 `effect_tex.gd` 的程序化贴图；
3. 改外观包脚本：类名改成 `IceAppearance`、配色常量换成冰色（`FIRE_*` → `ICE_*`），
   粒子层的 `Gravity / direction / spread` 按冰的物理调（冰通常往下坠、扩散小）；
4. **检查层级**：帧动画 `z_index` 必须高于所有粒子层（外观包是帧 5 / 粒子 0~4）；
5. 新技能资源：复制 `某个技能资源` → 改 `id` / `display_name` / `power` / `mana_cost`，
   `tint` 改偏蓝，`appearance_scene` 指向 `ice_appearance.tscn`；
6. 拖进 `battle.tscn` 上 `Battle` 节点的 **Default Skills**，或填进某个角色的 `UnitStats.skills`。

**公共弹道一行都不用改。**

## 踩过的坑（都已在代码/场景里处理）

| 症状 | 原因 | 处理 |
|---|---|---|
| 像素帧动画被粒子整片盖住 | 四层飞行粒子 `z_index` 是 1~4，帧动画是默认 0 | 帧动画烘成 5（在 `某个外观包场景` 里），顺序见外观包脚本头部注释 |
| `Amount of particles cannot be smaller than 1.` | 关浓烟时写了 `smoke.amount = 0`（`GPUParticles2D.amount` 最小 1，且赋 0 不会生效只会刷红字） | 改成只关 `emitting` + 隐藏节点 |
| 序列帧技能看着"被糊住" | 像素帧实际内容只有 ~43×21 px（画布 100×100 里 97% 透明），粒子单个 50~130 px | `frames_only = true` + `flight_particle_ratio ≈ 0.15~0.2` + `projectile_scale` 放大到 3.5~5.5 |
| 命中序列帧播完不消失 | 素材烘焙的是 `loop = 1`（一直循环） | `play_sequence_once()` 按时长自毁；**不要**去改 `sprite_frames.set_animation_loop()`（内嵌 SubResource 是共享的，还会被编辑器写回 .tscn） |
| 拖尾线不显示 | `%Trail` 在场景里 `visible = false`（当前可见拖尾由外观包的 `TrailParticles` 负责） | 想启用：`setup()` 里 `trail.visible = true`；它设了 `top_level`，点是世界坐标 |
| 冰系染色被火色污染 | `%Trail` 的渐变原来烘的是橙色，`modulate` 再乘 tint 会变脏 | 公共弹道的拖尾渐变改成**白色**，颜色完全由 `tint` 决定 |
| Godot 4.7 粒子绕体盘旋报错 `Invalid assignment 'orbital_velocity_min'` | 4.7 把"轨道速度"改名了 | 用 `angular_velocity_min/max`（+ `radial_velocity` 做外扩） |

## 紫霄派 / 星罗教增益（scenes/effects/wulei_zhengfa/ + zixiao_ningshen/ + xingluo_shaji/）

两个技能的特效都是**纯程序化粒子，零外部素材**（贴图全来自 `EffectTex` 工厂），节点全部在脚本 `_ready`/`play()` 里代码构建，`.tscn` 只有根节点 + 脚本：

| 文件 | 类型 | 接入 |
|---|---|---|
| `wulei_zhengfa/wulei_zhengfa_hit.tscn` | 命中特效（天降雷柱：外缘电弧闪烁 + 白热核心 + 闪光 + 火星 + 冲击波环 + 水平电弧乱窜，1.5s 自毁） | `SkillData.hit_effect_scene` + `instant_hit = true`（**无弹道**：不飞弹体，施法后雷柱直接劈在目标身上，契约 `play(tint, count)`） |
| `xingluo_shaji/xingluo_shaji_aura.tscn` | 施法/增益光环 v2（加大华丽版：开场猩红火花迸发 + 双层血色法环 3 波向外扩散 + 螺旋杀气绕体盘旋上升 + 血色光柱 + 心口暗红杀气骤亮骤暗 + 血尘上浮，2.6s 淡出自毁；原点 = 单位脚下） | `SkillData.hit_effect_scene`（辅助技能 `_spawn_support_effect()` 没配 `target_effect_scene` 时退回读它），`burst_scale = 1.25` |

（曾给五雷正法做过"雷光球"飞行外观，后按设计改为无弹道直接落雷，`wulei_zhengfa_orb` 已删除。）

`skill_wulei_zhengfa.tres`：`instant_hit = true` / `hit_effect_scene` / `burst_scale = 1.4` / `screen_shake = 9.0` 已接线；
`skill_zixiao_ningshen.tres`：`hit_effect_scene` / `hit_particles = 20` 已接线；
`skill_xingluo_shaji.tres`：`hit_effect_scene` / `hit_particles = 20` 已接线。
改观感直接调各脚本里的常量与粒子参数。
