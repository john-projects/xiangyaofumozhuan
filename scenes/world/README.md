# 世界地图（scenes/world/）

可探索的地图：**玩家自由走动 + 相机跟随 + 地图等比放大 + 固定 NPC + 跟 NPC 对话传送（双向）**。

## 操作

| 操作 | 按键 |
|---|---|
| 走动 | `W A S D`（用的是项目里已有的 `move_left/right/up/down`） |
| 加速走 | `空格`（复用 `dash` 动作），世界地图里它只是加速，不是冲刺技能 |
| 与 NPC 交谈 | `E` 或 `Enter`（靠近后底部会出现"按 E 与 XX 交谈"提示） |
| 打开背包 | `B`（随时，不用先开菜单；再按一次 `B` 或 `ESC` 关掉。背包里没有关闭按钮） |
| 打开角色属性 | `C`（随时，不用先开菜单；**只开属性面板，不连带背包**。再按 `C` / `ESC` 收掉属性面板） |
| 属性面板里开背包 | 属性面板开着时按 `B` = **单独**开关背包（左属性右背包，两个都能点、都能用键盘）；再按 `B` 只收背包 |
| 角色属性里换人 | 点属性面板**或背包**两边的 `◀` / `▶`（两边同步）：属性、装备和"点格子穿给谁"一起换 |
| 打开操作菜单 | `ESC`（没有任何面板开着时 = 打开菜单） |
| 菜单 / 面板里选择 | `↑↓` 或 `W S`（也可以直接用鼠标点） |
| 背包里走格 | `← ↑ → ↓` 或 `W A S D`（一行 8 格，上下跳一整行） |
| 背包里切换角色 | 点形象两边的 `◀` / `▶`，或用方向键把焦点移过去后按 `Enter` / `空格` / `E` |
| 穿装备 | 没跟商人交易时，点背包里的一格（或焦点移上去按 `E`）= 穿到**当前展示的那个角色**对应的装备栏（左二那个是武器栏） |
| 脱装备 | 点角色形象两侧**已穿上东西**的装备栏（或焦点移上去按 `E`）= 从**当前展示的角色**身上脱下、放回背包 |
| 切换角色看装备 | 点形象两边的 `◀` / `▶`（或键盘走到箭头上按 `E`）：装备栏跟着换成那个人的一套 |
| 商人处买装备 | 方向键 / `W A S D` 选格子 → `Enter` / `空格` / `E` 或点一下 → 确认框里选「确定购买」（`Esc` = 取消，再按一次才关掉交易） |
| 商人处卖东西 | 交易时点背包里的一格 → 确认框里选「确定卖出」（身上穿着的要先脱下来才会在背包里） |
| 看背包后面的行 | 滚轮下滑，或键盘往下走（列表会自动滚过去） |
| 看物品属性 | 鼠标悬停在格子上，或把键盘焦点移到格子上 |
| 菜单 / 面板里确认 | `Enter` / `空格` / `E` 都能按下当前高亮的按钮 |
| 关闭对话框 | `ESC` 或点「再想想」 |
| 退回上一级 | 队伍管理页 / 背包 / 角色属性按 `ESC` 退回操作菜单（直接按 `B` / `C` 开的则直接回游戏） |
| 进入战斗 | 操作菜单里的「进入战斗」，或右下角那个按钮（同一条通路） |
| 返回主菜单 | 操作菜单里的「返回主菜单」，或左下角那个按钮（同一条通路） |
| 调试：取坐标 | 鼠标移到目标位置按 **F1**，控制台打印归一化坐标 |

## 结构

```
WorldMap (Node2D, y_sort_enabled = true)   [world_map.gd]
├── MapSprite  (Sprite2D, centered = false, scale = map_scale)   ← 地图图片，原点在左上角
├── Player     (Node2D)                                          ← 玩家（Sprite 用所选角色的 icon）
│   ├── Shadow (Polygon2D)
│   ├── PlayerFallback (Polygon2D)
│   ├── PlayerSprite (Sprite2D)
│   ├── Camera (Camera2D, 带平滑跟随 + 地图边界限制)
│   └── NameLabel (Label, 运行时生成)                            ← 队长头顶的名字
├── Companion0…N (Node2D, 运行时生成)                            ← 上阵队友：Shadow + Sprite2D + NameLabel
├── （NPC 直接挂在 WorldMap 下，运行时生成）
└── UI (CanvasLayer)：地图名 / 金币 / 结果提示 / 交互提示 / 进入战斗 / 返回主菜单 / 对话框
```

> NPC 为什么没有单独的容器节点：`y_sort_enabled` 只对**兄弟节点**排序，NPC 和玩家必须是兄弟，
> 玩家才能走到 NPC 身后/身前。所以 `_add_npc()` 是直接 `add_child` 到 WorldMap 上的。
> 队友小人（Companion）同理挂在 WorldMap 下，才能和玩家/NPC 一起按 y 排序。

## 队伍立绘：队长名字 + 队友跟随

- **队长名字**：`_setup_party_visuals()` 在 `Player` 下加一个 `Label`（白字+黑描边，y = -78、宽 220 居中），
  文字取 `Global.main_player_selected.name`。因为它是 `Player` 的子节点，走动时自动跟着走，不用每帧同步。
- **上阵队友**：`_rebuild_companions()` 给 `deployed` 里除队长外的每个人生成一个 `Companion` 节点
  （Shadow + Sprite2D + 名字 Label，立绘用各自的 `UnitStats.icon`，缩放 1.3 和玩家一致）。
- **跟随方式**：队长每走 **2px** 就往"面包屑轨迹" `_trail` 头部插一个点（`_update_trail()`）；
  第 i 个队友的目标是轨迹里第 `i × 20` 个点（= 身后约 40px/人），再用
  `1 - exp(-12 × delta)` 插值挪过去（`_update_companions()`）——
  拐弯时队友是沿着队长**走过的路**跟过来，不会斜穿墙角，也不会几个小人叠在一起。
- **队伍变了**：`notify_party_changed()`（上阵/下阵/移除）会 `_rebuild_companions.call_deferred()`，
  场上小人数量立刻跟着变；队长本人永远不生成小人（他就是 `Player`）。

## 坐标与缩放

- 地图图片按 `MapData.map_scale` **等比放大**（默认 `2.0`）：2048×1152 → **4096×2304** 的世界，比视口大得多，所以能探索；
- 世界原点 = 图片左上角（`MapSprite.centered = false`），因此：

```
世界坐标 = 归一化坐标 × (图片尺寸 × map_scale)
```

- `MapData.spawn_point` 和每个 `MapNPC.position` 都是**归一化坐标**（0~1），换算在 `WorldMap._world_pos()`；
- 玩家被钳制在地图内（留 60 单位边距）；地图比视口大时相机被限制在地图矩形内，不会露出黑边。

**怎么知道该填什么坐标**：运行游戏进到那张图 → 鼠标移到目标位置 → 按 **F1**：

```
[WorldMap] 建邺城 鼠标归一化坐标: Vector2(0.823, 0.615)
```

把 x/y 填进 `MapData.spawn_point` 或对应 NPC 的 `position`。

## NPC 与双向传送

每张图在 `resources/maps/map_*.tres` 里配 `npcs` 数组，每个 NPC 是一个 `MapNPC`：

| 字段 | 说明 |
|---|---|
| `id` / `display_name` | 标识 / 显示名 |
| `texture` | 立绘；留空时用一块金色方块占位，方便先跑通 |
| `position` | 归一化坐标 |
| `dialogue` | 交谈时显示的话 |
| `destinations` | 这个 NPC 能把玩家送去哪些地图（填地图 id 数组） |
| `teleport_label` | 按钮措辞，例如"出海前往" |

**双向传送就是两边互相指**。当前配置：

```
建邺城   船夫     -> [donghaiwan]
东海湾   船夫     -> [jianyecheng]     向导 -> [aolaiguo]
傲来国   向导     -> [donghaiwan]      猎人 -> [huaguoshan]
花果山   看山猴   -> [aolaiguo]
```

落点规则（`WorldMap._spawn_normalized()`）：

1. `spawn_override` 有值就用它（**打完战斗回到地图时站在离开的位置**）；
2. 否则如果是从某张图走过来的（`from_map_id`），就出现在**指向那张图的 NPC 旁边**（+0.04 的 y 偏移，不会和 NPC 重叠）；
3. 都没有则用 `MapData.spawn_point`。

所以来回传送时，你总是出现在"带你回来的那个 NPC"旁边，不会迷路。

## 兜底

如果某张图的 `npcs` 是空的，`WorldMap` 会自动在 `MapData.exit_center` 生成一个「路牌」NPC，
指向 `MapData.next_id`，并 push_warning。这样就算 NPC 没配好，流程也能走通。

## 每张图独立场景（继承，可选但推荐）

现在**两种模式并存**，可以一张一张慢慢迁：

| 模式 | 怎么做 | 适合 |
|---|---|---|
| **纯数据**（默认） | `MapData.scene` 留空 → 用通用的 `world_map.tscn` | 改底图/NPC/传送/敌人，全在 `.tres` 里改，最快 |
| **独立场景** | `MapData.scene` 指向 `scenes/world/maps/world_<id>.tscn` | 要摆装饰、画地形碰撞、做每图不同的机关/触发器/演出 |

四张图的独立场景已经建好了（继承自 `world_map.tscn`，内容还是空的）：

```
scenes/world/maps/world_jianyecheng.tscn
scenes/world/maps/world_donghaiwan.tscn
scenes/world/maps/world_aolaiguo.tscn
scenes/world/maps/world_huaguoshan.tscn
```

### 怎么往里面加东西

1. 双击打开 `world_jianyecheng.tscn` —— 它是**继承场景**，你会看到基类的全部节点（灰底 = 继承来的）；
2. 直接把装饰拖进根节点下（`Sprite2D`/`AnimatedSprite2D`/`Light2D`…）。**想跟玩家正确前后遮挡就挂在根下**，
   因为 `WorldMap` 开了 `y_sort_enabled`，只对兄弟节点排序（放进容器里的话，整组会按容器的 y 排序）；
3. 要地形碰撞就加 `TileMapLayer` + 物理层；注意当前玩家是普通 `Node2D`（只做边界钳制），
   要真正挡人就先把 `Player` 换成 `CharacterBody2D` + `move_and_slide()`（走路逻辑在 `world_map.gd::_move_player()`）；
4. **通用逻辑千万别复制**：走动、相机、NPC 交互、对话框、战斗入口都在基类 `world_map.gd` 里。
   只有"这张图独有"的逻辑才新建脚本挂到继承场景的根上：

```gdscript
# world_jianyecheng.gd —— 挂在 world_jianyecheng.tscn 的根节点上
extends WorldMap

func _ready() -> void:
	super()                      # 先跑基类：搭地图/玩家/相机/NPC/UI
	# 再写只属于建邺城的东西：开场演出、进入时弹提示、特殊触发器……
```

（改基类 `world_map.tscn` / `world_map.gd`，四个继承场景会自动跟着变——**这就是"继承"而不是"复制"的意义**。）

### 已经验证过的行为

每张图实例化的确实是它自己的场景，基类逻辑全部继承：

```
起点=建邺城  实例场景=res://scenes/world/maps/world_jianyecheng.tscn  基类节点齐全=true NPC数=1
抵达=东海湾  实例场景=res://scenes/world/maps/world_donghaiwan.tscn  NPC数=2 玩家归一化=(0.3,0.59)
抵达=傲来国  实例场景=res://scenes/world/maps/world_aolaiguo.tscn    NPC数=2 玩家归一化=(0.28,0.49)
抵达=花果山  实例场景=res://scenes/world/maps/world_huaguoshan.tscn  NPC数=1 玩家归一化=(0.45,0.42)
回程=傲来国  实例场景=res://scenes/world/maps/world_aolaiguo.tscn
```

## 扩展点

| 想做的功能 | 改哪里 |
|---|---|
| 走动动画 | `world_map.tscn` 里把 `PlayerSprite` 换成 `AnimatedSprite2D`，在 `_move_player()` 里切动画 |
| 碰撞 / 障碍物 | 现在只有边界钳制。要墙就把 Player 换成 `CharacterBody2D` + `TileMapLayer` 加物理层 |
| 遇敌改成踩地雷 / 野怪 NPC | 把 `battle_requested` 的触发从 UI 按钮改成 `_move_player()` 里的随机判定，或加一个 NPC 类型（`MapNPC` 加 `battle: bool`） |
| NPC 对话分支 / 商店 / 任务 | `WorldMap._open_panel()` 里现在只生成"传送按钮"，可以按 NPC 类型生成不同按钮 |
| 同一张图多个传送 NPC | 已经支持（`npcs` 是数组）；`destinations` 也可以塞多个目标，对话框会自动多按钮 |
| 主角立绘换成行走图 | `_player_icon()` 现在取 `Global.main_player_selected.icon`，改成读另一份资源即可 |

## 已知限制

- 没有碰撞体：能走到图上任何地方（只有边界钳制）；
- NPC 立绘留空时是占位方块；
- 同一时刻只有一个 NPC 高亮（`interact_radius = 150`），两个 NPC 靠太近会优先取更近的那个；
- 战斗目前由 UI 按钮触发，还没和地图上的具体敌人绑定。


## NPC 交互类型（`MapNPC.action`）

| 类型 | 交谈时给什么按钮 | 读哪些字段 |
|---|---|---|
| `AUTO`（默认） | 按老规则：`destinations` 非空 = 传送，否则纯对话 | `destinations` |
| `TALK` | 只显示台词，一个按钮都不给 | `dialogue` |
| `TELEPORT` | 每个目的地一个按钮 | `destinations` / `teleport_label` |
| `RECRUIT_PARTY` | 每个候选队友一个「加入 XX」按钮 | `recruit_pool`（留空则扫 `Global.RECRUIT_DIR`）/ `recruit_label` |
| `SELL_WEAPONS` | **直接打开商人面板**（不在小窗口里铺按钮） | `sell_pool`（留空则扫 `Global.EQUIPMENT_DIR`）/ `shop_label` |
| `JOIN_SECT` | 门派掌门：团队里**每人一个「拜入 XX」按钮**，按种族筛（不符/已有门派的置灰并写明原因） | `sect_id`（`Global.SECTS` 的键） |

`AUTO` 存在的意义：老 `.tres` 只填了 `destinations`，加了 `action` 字段后它们的行为**不变**。
在 `.tres` 里 `action` 是整数（`AUTO=0 / TALK=1 / TELEPORT=2 / RECRUIT_PARTY=3 / SELL_WEAPONS=4 / JOIN_SECT=5`），
因为枚举整数值会落盘，**不要调整 `MapNPC.Action` 的成员顺序**。

### 对话面板（`TravelPanel`）

- 位置：**屏幕底部居中**，底边离屏幕 24px（`PANEL_BOTTOM_MARGIN`）；
- 宽度：**屏幕宽度的 3/4**（tscn 里左右锚点 0.125 / 0.875，窗口拉伸时自动跟着变，居中不变）；
- **名字和台词同一行**：`PanelLine`（HBox）= 金色的「名字：」+ 台词 Label（自动换行），
  不再有单独的名字行 —— 面板因此矮了一截（原来名字行 ~56px）；
- **拜师 / 招募这类"一句话回执"不写进台词行**：走 `WorldMap.show_toast()` ——
  屏幕**中央居中**的一条小弹窗（**较实的黑底 alpha 0.88** + 金色圆角描边，压在花纹地图上也看得清），停留 `TOAST_TIME = 1.5s` 后淡出；
  **战斗结算**也走同一个弹窗栈（停留 `result_toast_time = 3s`），而且 GameRoot 给的文案本身就是**多行**：
  「地图：战斗胜利！」/「获得 N 金币 · 上阵每人经验 +M」/ 每个升级了的队员一行 —— 于是会显示成一叠多条。
- **可以一次推多条**：`show_toast()` 会把 `\n` 拆成多条，**第一条以屏幕中心为基准，后续依次往下排**
  （栈是"从中心往下长"的，宽度固定 720、水平居中，每条到时各自淡出消失）；
  弹窗节点在 `UI` 里被移到最上层，开着对话框/背包时也不会被挡住。
- 高度：默认 200（`PANEL_MIN_HEIGHT`），按钮多时 `_fit_panel_height()` 会**向上长高**
  （锚点在底边，只改 `offset_top`；公式 = 按钮总高 + 164），上限视口高度的 85%，
  所以永远贴底、不会顶出屏幕；
- 选项按钮**高 34、字号 20**（`PANEL_OPTION_HEIGHT` / `PANEL_OPTION_FONT`，统一在 `_rebuild_panel_buttons()` 里设）：
  52 高的按钮里文字只占一行，行与行之间会空得很开；`_indent_button()` 同时把上下内边距压到 2px，
  否则默认主题的 4px 会把按钮最小高度顶到 35+，行距又被字号偷偷撑大；
- 面板里的按钮**铺满整行**（从对话框左边一直排到右边，文字仍然居左），
  说明文字/台词也占满整行；
- **选项文字居左、铺满整行**（从对话框左边开始，`button.alignment = LEFT` + 16px 左内边距 `PANEL_BUTTON_INDENT`；
  `_indent_button()` 会把 normal/hover/pressed/disabled/focus 五种样式的左边距一起改，鼠标悬停时文字不会跳）；
  **可点**的选项文字是**金色**（`PANEL_OPTION_COLOR`），置灰的（已入门派/种族不符）保持灰色；
  「再想想」也是同一套样式；
- 间距：选项之间 **2px**（`PanelButtons.separation`），台词/选项/关闭按钮之间 **6px**（外层 `VBox.separation`，
  原来是 16 —— 之前看着"行距没变"其实是这几道 16px 的外层间距，不是选项之间的间距）。

### 门派（拜师）

- **五个门派**写在 `Global.SECTS`（常量表：名字 / 收哪些种族 / 一句介绍），
  `Global.SECT_ORDER` 是展示顺序；种族限制只有这一份，**改规则改这里**：

  | 门派 | id | 收 |
  |---|---|---|
  | 太虚剑宗 | `taixu` | 人族 |
  | 缥缈仙府 | `piaomiao` | 人族、仙族 |
  | 紫霄神道教 | `zixiao` | 仙族 |
  | 万药谷 | `wanyao` | 仙族、魔族 |
  | 星罗教 | `xingluo` | 魔族 |

- **种族**在 `UnitStats.race`（`HUMAN / DEMON / IMMORTAL`，默认人族）：
  陆孤鸣、燕如意 = 人族；行修、霓衣 = 仙族；厉狂澜、夜魑 = 魔族。
- **默认无门派**：`Global.sect_by_character`（角色键 → 门派 id）一开始是空的；
  一个角色同时只属于一个门派，**不能改投**（想做得先加"叛出师门"）。
- **拜师流程**：跟掌门按 E → 面板列出**整支团队**，每人一行：
  能拜的写「拜入太虚剑宗 · 陆孤鸣（人族）」，种族不符写「行修（仙族）· 太虚剑宗不收仙族」并置灰，
  已经拜过的写「已入星罗教」并置灰 → 点能点的那个 → `sect_join_requested` →
  `GameRoot.join_sect()` 再判一次（规则仍只有一份）→ 成功后**中央弹出一串提示**：
  第一行「陆孤鸣拜入太虚剑宗！」，接着每学会一个门派技能各一行「学会 太虚剑典（Lv.1）」（1.5s 淡出，见 `WorldMap.show_toast()`），
  **NPC 台词行不动**。
  ⚠ 掌门面板里**不再显示**「（只收人族）：门派介绍」那句说明、也不再显示「团队 X 人」那一行，
  只保留台词 + 队员按钮（按钮间距 6px，比原来的 12px 更紧凑）。
- **建邺城**的 5 个掌门：`taixu_zhangmen` / `piaomiao_zhangmen` / `zixiao_zhangmen` /
  `wanyao_guzhu` / `xingluo_jiaozhu`（`map_jianyecheng.tres`，位置分散在城四周）。

### 门派技能

每个门派 **2 个被动 + 3 个主动**，表在 `Global.SECT_SKILLS`（一个门派一项，字段见文件注释）。

- **拜入即学会**：`GameRoot.join_sect()` 成功后写
  `Global.sect_skill_levels_by_character[角色键] = { 技能 id: 1, … }` —— 本门 5 个技能**各 1 级**。
- **等级是每个技能各自的**（`{技能 id: 等级}`），最高 `Global.SECT_SKILL_MAX_LEVEL = 100`；
  **不再随玩家升级自动涨**，只能在属性面板的「技能」页花**经验 + 金币**升（见下）。
- **被动真的生效**：`_make_player_team()` 里 `_apply_sect_passives()` **按每个被动自己的等级**把加成叠到战斗副本上。
  目前支持的加成类型：`damage_pct / hp_pct / crit_rate / crit_damage_bonus / speed / defense /
  spell_damage / healing / seal_hit`（对应 `UnitStats` 的字段；暴击率这一项 `BattleUnit.roll_crit()`
  已经会读 `stats.crit_rate`）。
- **主动技能目前只有数据与说明**（目标数阈值、连击数、封印/封法术、治疗/持续回血、状态参数都写在表里），
  战斗里还不会自动释放 —— 等技能栏/状态系统接好后再执行。

### 技能升级（属性面板 · 门派技能页）

属性面板现在有**三个页签：属性 / 门派技能 / 其他技能**。

**门派技能页**是一张表（仿参考图）：表头 `名称 / 等级 / 类型 / 目标 / 消耗`，
每个门派技能一行（`太虚剑典　1/100　被动　—　14经验 5金`）。**点某一行 = 选中它**（该行高亮），
下面出现这个技能的详情块：

```
【描述】太虚剑意淬体：每级提升 1% 伤害。
【条件】经验 14 · 金币 5          ← 不够时会写"（经验不足（需要 157））"并变红
【拥有】经验 5,000 · 金币 1,000
                              [升级] [升级10次]
```

**其他技能页**放角色自身的 `UnitStats.skills`（SkillData，没有等级/升级），和门派技能彻底分开。

点「升级」走 `GameRoot.upgrade_sect_skill(character, skill_id, times)`：
**扣这个角色自己的经验**（`GameRoot.exp_of(character)`，按角色存）+ `Global.coins`，等级 +1（`升级10次` 会一直升到钱/经验不够或满级为止），
成功后整页重建并显示一行回执（`升级成功：太虚剑典 → Lv.4`）。按钮在经验/金币不够或满级时置灰。

花费曲线（`GameRoot.sect_skill_upgrade_cost(level)`，改系数就能整体调贵/调便宜）：

| 等级 | 升到下一级：经验 | 金币 |
|---|---|---|
| Lv.1 | 14 | 5 |
| Lv.10 | 53 | 15 |
| Lv.30 | 157 | 43 |
| Lv.50 | 285 | 79 |
| Lv.70 | 437 | 123 |
| Lv.99 | 700 | 201 |

公式：`exp = round(10 + 4L + 0.03L²)`、`coins = round(4 + L + 0.01L²)`。
**把一个技能从 1 练满 ≈ 30,650 经验 / 8,630 金币**（≈ 玩家等级曲线总经验的 1/8），5 个技能全满 ≈ 15 万经验。　
⚠ 升级扣的是**这个角色当前等级里存着的经验**（`Global.exp_by_character`），所以冲技能会拖慢**他自己**的升级 —— 这是刻意的取舍。

五个门派的技能（`Global.SECT_SKILLS`，改表即可，不用动代码）：

| 门派（定位） | 被动 1 | 被动 2 | 主动 1 | 主动 2 | 主动 3 |
|---|---|---|---|---|---|
| 太虚剑宗（物理） | 太虚剑典 +1% 伤害/级 | 剑心通明 +0.5% 暴击率/级 | 三尺清风 2 目标（30 级 3 个） | 太虚神剑 单体 3 连击 | 人剑合一 暴击率状态 |
| 缥缈仙府（封系） | 云海心法 +0.5 速度/级 | 缥缈封心 +0.5% 封印命中/级 | 太虚封天 **群体封印** | 封灵诀 **封法术**（单体） | 缥缈剑指 固定伤害 2 目标（30 级 3 个） |
| 紫霄神道教（法系） | 紫霄雷体 +1.5 法伤/级 | 天雷淬体 +1 防御/级 | 五雷正法 单体 | 雷动九天 3 目标（**60 级 5 个**） | 紫霄凝神 法伤状态 |
| 万药谷（治疗） | 百草心经 +1 治疗/级 | 药王体魄 +0.8% 气血/级 | 回春诀 队友回复气血 + 持续回血（持续回合随等级提升；目标数 1/25/50/75 级 = 2/3/4/5） | 药雾弥漫 固定伤害 2 目标（30 级 3、60 级 4） | 万灵祝福 **全体队友** 伤害 + 法伤 状态 |
| 星罗教（物理） | 星象魔功 +1% 伤害/级 | 摄魂咒 +0.5% 暴击伤害/级 | 星罗魔爪 单体 2 连击 | 群星陨落 3 目标（30 级 4 个） | 星罗杀机 暴击伤害状态 |

> 主动技能的目标数是**按等级取档**的（`targets` 是一张 `[{等级, 数量}]` 表，
> 取"当前等级 ≤ 等级"里最大的那档），所以后面调阈值只改数字、不改代码。

## 队伍系统：团队（名册）与上阵名单

队伍分成**两层**，这是理解这一段的钥匙：

| | 团队 `GameRoot.party` | 上阵名单 `GameRoot.deployed` |
|---|---|---|
| 是什么 | 招募到的所有人（大名单） | 真正进战斗的那几个人 |
| 人数 | 默认**不限**（`MAX_TEAM_SIZE = 0`；设成正数才会有"团队已满"） | **最多 5 人**（`MAX_DEPLOYED`，= Battle 的 `Stage/PlayerSlots` 五个站位） |
| 关系 | 上阵名单永远是团队的**子集** | 移出团队的人会自动从上阵名单摘掉 |

- **候选来源**：`MapNPC.recruit_pool`（显式列表）优先；留空 → `Global.get_recruitable_players()`
  扫 `res://resources/units/players/`（就是选人界面那 5 个 `stats_player_*.tres`）；
  往那个目录丢一个新 `UnitStats` 的 `.tres`，它就能被招募，不用改 NPC；
- **点击「加入」之后**：`WorldMap.recruit_requested(stats)` → `GameRoot._on_recruit_requested()`
  → `GameRoot.add_party_member()`：**进团队**；如果上阵位还有空位就**顺手一起上阵**
  （招募的直觉就是"这人来一起打"），上阵位满了就先坐板凳，面板里显示 `[待上阵]`；
  然后回调 `WorldMap.notify_party_changed()` 在顶部弹一行"XXX 加入了团队！"（1.5s 淡出）并重建按钮
  （那个人随即变成灰的"已在团队中"）；
- **上阵 / 下阵**：队伍管理页每行的按钮 → `WorldMap.party_deploy_requested` /
  `party_undeploy_requested` → `GameRoot.deploy_member()` / `undeploy_member()`。
  两条硬约束：上阵最多 5 人；**至少要留 1 人上阵**（否则进不了战斗），
  违反的按钮会直接置灰并在 tooltip 里写明原因；
- **规则只有一份**：`GameRoot.party_count / party_has / party_can_join / deployed_count /
  is_deployed / deploy_can_add / deploy_can_remove` 全是静态函数，
  面板画按钮（灰不灰、文字是"上阵"还是"下阵"）和真正改数据用的是同一套判定，
  不会出现"按钮能点但点完没反应"；
- **界面同步**：`party` 与 `deployed` 都是引用语义的数组，`WorldMap._party` / `WorldMap.deployed`
  是同一个实例，所以数据立刻同步，需要的只是"刷新文字"这一步
  （面板底部那行「团队 n 人（上阵 m/5）：…」）；
- **战斗里怎么体现**：`_make_player_team()` 把 **`deployed`** 逐项 `duplicate()` 后交给
  `Battle.start_battle()`，每个上阵成员就是一个 `BattleUnit` —— 贴图取 `UnitStats.icon`、
  数值全取自 `.tres`，所以**队友不需要额外的角色场景**（只有"当主角"才需要
  `Global.available_players` 里那把 `name → PackedScene` 的映射）；
- **敌人数量看上阵人数**：`_make_enemy_team()` 用 `deployed_count(deployed) ± 1`（钳进 1~5），
  不是团队总人数 —— 坐板凳的人不该让敌人变多。

**加一个新的招募 NPC**：复制 `map_jianyecheng.tres` 里 `duiyou` 那条子资源 → 改 `id` /
`display_name` / `position` / `texture` → 把 `action` 设成 `3`（`RECRUIT_PARTY`）即可。

## 商人（装备商店）

建邺城的 `shangren`（`action = 4` = `SELL_WEAPONS`）卖**现有全部装备**（26 件）：

- **货架来源**：`MapNPC.sell_pool`（显式列表）优先；留空 → `Global.get_all_equipment()`
  递归扫 `res://resources/items/equipment/`，当前 **26 件**（头盔 4 / 武器 5 / 腰带 4 /
  项链 5 / 衣服 4 / 鞋子 4），按「栏位 → 价格」排序。往那个目录丢一件新装备就自动上架；
  ⚠ 只认 `item_*.tres`；货架类型是 `Array[ItemBase]`（以后丹药/卷轴也能上架）；
  ⚠ **老武器体系（ItemWeapon / resources/items/weapons/）已经整体移除**（连竞技场一起删的），
  现在工程里能上架、能穿、能卖的道具只有 `ItemEquipment`；
- **装备数据**：每件是 `ItemEquipment`（`resources/items/equipment/item_equipment.gd`），
  字段 `equip_type`（穿哪个栏位）+ `attack / defense / health / crit_chance / speed / block_chance`；
  图标在 `assets/sprites/equipment/<类型>/<类型>_0N.png`。属性是**随机生成后烘进 .tres** 的
  （固定种子生成，同一件每次打开都一样；主属性保证随品质递增，不会出现"传说不如史诗"）；
  ⚠ 这些数值目前**只展示、还没参与战斗结算**（战斗读 `UnitStats`），接加成时按同一口径直接加即可；
- **交互方式**：按 `E` **直接打开商人面板**（`scenes/ui/merchant_panel/`），不经过那个
  **底部对话面板**（方格货架铺不下）。所以 `WorldMap._open_panel()` 在最开头就把
  `SELL_WEAPONS` 分流到 `_open_merchant()`，并且**不置 `_panel_open`**；
  ⚠ 开交易会**同时打开背包**（`_open_bag(false, true)`，as_companion = true），
  交易窗口贴**最左边**、背包贴**最右边** —— 关了交易，配件背包一起收（Esc / B / 「关闭」都走 `_close_merchant()`）；
- **购买链路**：面板 `buy_requested(item)` → `WorldMap.item_buy_requested` →
  `GameRoot._on_item_buy_requested()` → `GameRoot.buy_item()`（扣 `Global.coins` +
  append 进 `Global.equipped_weapons`）→ 回调 `WorldMap.notify_shop_changed()`：
  刷新**背包信息行里的余额**、重建货架（灰不灰、"已持有 ×n" 全跟着变）；
- **购买链路的界面**：货架是**和背包一样的方格** —— **总共 6 列 × 20 行 = 120 格**（`SHELF_SLOTS`），
  **一屏 6×10 = 60 格**，其余靠滚动。现有 26 件装备只占前 26 格，剩下的是**空格子**
  （和背包一样把空格画出来：一眼看得出这个商人一共有多少格、还剩多少空位）；
  格子 **84px**、稀有度描边、悬停/焦点弹属性卡，区别只有两点：格子上多一个**价格角标**（右下）
  和「持×n」角标（左上），**点一下先弹确认框**；
- **尺寸与背包对齐**：84px × 6 列 + 间距 + 内边距 = 窗口 **610 × 1038**，背包是 **662 × 1044**
  —— 两个窗口并排时高矮一样、宽度同一档（这就是「放大到跟背包差不多」的算法：
  一屏 10 行要在 1080 里放下，格子最大只能 84）；
- **版面只剩三块**（台词 / 金币 / 按键提示 / 「关闭」按钮都按需求移除了）：
  **居中的 NPC 名字 → 结果提示 → 方格货架**。所以关交易只有 `Esc` / `B` 两条路
  （`close_requested` 信号与 WorldMap 的连线保留着，以后想加按钮直接接），余额看并排的背包那一行；
- **确认框**（`%ConfirmBox`）：写清「买下『X』？价格 N 金币 · 买后剩 M 金币」+「确定购买 / 取消」。
  没点确定之前**一分钱都不扣、背包也不变**（探针盯着这条）。确认框开着时：
  货架格子临时设成不可聚焦（焦点只在两个按钮之间），
  `Esc` **只关确认框**（`MerchantPanel.cancel_confirm()` 返回 true 时 WorldMap 就不关交易了），
  再按一次才关整个交易；
  场景里万一没有 `%ConfirmBox`（旧副本覆盖）会退化成"直接买"并 push_warning；
- **位置**：交易窗口贴屏幕**最左边**（左下角锚点 + 16px 边距），尺寸同样由代码算
  （`MerchantPanel._apply_window_geometry()`）。10 行的可见高 = `10×84 + 9×10 = 930`，
  面板总高 1038，1080 下 y = 26~1064 ✓；
- **确认框的层级（踩过的坑）**：交易时背包也开着，而两个面板**各自带一层全屏半透明遮罩**。
  按树序画的话，后创建的背包会把交易窗口和确认框整体压暗/盖住（用户报的"购买弹窗被遮挡"）。
  两处一起修：
  · `WorldMap._setup_overlays()` 里**背包先实例化、交易窗口后实例化**（同 CanvasLayer 里树序 = 绘制序）；
  · `ConfirmBox` 自己再设 `z_index = 100`（同一层内永远画在最上面，双保险）；
- **买不了时一定给理由**：`GameRoot.item_can_buy()` 统一判定（金币不够 / 背包满 `BAG_SLOTS` 格），
  买不起的格子置灰 + 价格角标转红 + 原生 tooltip 写明原因。
  ⚠ 一条格子只走**一种**提示：买得起 → 接属性卡、不设 `tooltip_text`；买不起 → 走原生 tooltip、
  不接属性卡（否则两个提示框会叠在一起）。背包那边也是这个原则；
- **键盘**：方向键按几何位置走；`W A S D` 走 `Global.grid_nav()`（上下 = 上一行同一列，
  中间夹着买不起的格子会自动跳过 —— 这是"几何找邻居"而不是"焦点环 ±6"的原因）；
  `Enter` / `空格` / `E` 按下焦点上的那一格（弹确认框）、`Esc` 关闭（先关确认框，再关交易）。
  因为方格语义归面板自己管，`WorldMap` 的商人分支**故意不调 `_overlay_nav()`**，只接 Esc / E；
- **⚠ 属性还没接进战斗**：`Global.equipped_weapons` / `Global.equipment_by_character` 都是**数据**，
  战斗里的 `BattleUnit` 只读 `UnitStats`（伤害/血量/技能），**不读装备** ——
  所以现在买装备/穿装备是"攒属性"，还不会让战斗变强。要让装备真正生效，在
  `GameRoot._make_player_team()` 里把 `Global.equipment_by_character` 的加成叠到对应角色的 `UnitStats` 副本上即可
  （字段口径和 `UnitStats` 一致，见 `ItemEquipment` 的注释）。

**加一个新商人**：复制 `map_jianyecheng.tres` 里 `shangren` 那条子资源 → 改 `id` /
`display_name` / `position` / `texture` / `dialogue` → `action` 保持 `4`。
想让他只卖几件（限量商人）：把那几件装备拖进 `sell_pool`。

**加一件新装备**：把图标丢进 `assets/sprites/equipment/<类型>/`，在
`resources/items/equipment/<类型>/` 里复制一个 `item_*.tres` 改图标/名字/价格/属性/`equip_type`
即可（商人下一次打开就会自动上架；`Global.get_all_equipment(true)` 可强制重扫）。
数值不用自己配也行：`ItemEquipment` 的字段都是 `@export`，属性卡会按非 0 项自动列出来。

## 背包（`scenes/ui/bag_panel/`）

梦幻西游那种**方格背包**：一行 **8 格**、共 **120 格**（15 行），空格也画出来（一眼看到还剩几格）。
面板从上到下是：**标题「背包 n/120」→ 角色区（形象 240×308 + 左右各 3 个 96px 装备栏）→ 信息行（左金币 / 右提示文字）→ 方格背包（68px 格子）**。

- **位置**：屏幕**右下角**（距右边/下边 16px）—— 像游戏里的"背包窗口"，世界还留在画面里
  （遮罩 `Dim` 是 0.35；想完全不要遮罩就删掉那个节点，面板根节点本身会吃掉点击，不会误触到地图）；
  ⚠ **位置与尺寸是代码算出来的**（`BagPanel._apply_window_geometry()`），不是 .tscn 里的数字：
  窗口高度依赖"一屏几行 + 角色区 + 标题"这些常量，写死在场景里迟早对不上，而且视口变小
  （窗口没最大化）时还要自动少显示几行，免得顶出屏幕。想调窗口就改那几个常量；
- **顶部只放标题，金币放在信息行**：标题行 = `背包 n/120`（居中）；下一行的信息行里
  **左边是金币、右边是 MessageLabel**（留给以后的"卖出/合成"提示）—— 两段信息共用一行，
  角色区就只留给形象和装备栏（早先那版把金币挂在形象下方，等于多占一行、还把侧边装备栏顶歪）；
- **两种格子尺寸是分开的（踩过的坑）**：
  · `EQUIP_SLOT_SIZE = 96` —— **装备栏**那 6 个坑位用，同时决定形象框高度
    （`PLAYER_FRAME_HEIGHT = 3×96 + 2×10 = 308`，形象框 240×308 保持**竖版**）；
  · `SLOT_SIZE = 72` —— **背包格子**用（要在一屏里塞下 7 行，只能比装备栏小）。
  一开始我把两者写成同一个数（68），结果形象区被一起压小、形象框变成 240×224 的方框，
  看着"变形/被缩小"。梦幻西游的纸娃娃里装备栏本来也比背包格子大，拆成两个常量最自然；
- **一行 8 格（而不是早先的 6 列）**：窗口宽度取"方格"与"角色区那一行"的较大者 ——
  6 列时方格只有 498 宽、角色区 584 宽，于是方格两侧各空出 50 多像素（用户报的"两边边距过大"）；
  改成 8 列后方格宽 630 > 角色区 584，方格成了宽度主导，两侧只剩内边距（窗口宽 662）。
  120 格 = 8 列 × 15 行；
- **地图右上角不再有金币标签**（按需求移除）：金币只在**背包的信息行**显示
  （`WorldMap.refresh_coins()` 现在只负责把背包那一行同步一下；`setup()` 的 `p_coins` 参数、
  `_coins` 快照字段、`world_map.tscn` 里的 `CoinsLabel` 都一并删了）；
- **和商人做买卖时各占一边，而且背包是"活的"**：交易窗口贴**最左边**、背包贴**最右边**，天然不重叠；
  交易时背包**保持可交互**（点格子 / 键盘选格子都能用），因为这就是**卖出**的入口：
  · 点背包里的一格 → `BagPanel.item_activated` → `WorldMap._on_bag_item_activated()`：
    **没开商人 = 穿**（走 `equip_requested`，见下面"六个装备栏"），
    **开着商人 = 卖**（`_sell_bag_item()`：先按 `GameRoot.item_can_sell()` 判一次，
    卖不了就只在信息行说原因，不弹框）；
  · 卖的时候再调用**交易面板**的 `ask_sell()`（复用同一个确认框，措辞换成"卖出「X」？卖价 N 金币 · 卖后共 M 金币"，
    「确定」按钮也跟着变成**「确定卖出」**，不会出现卖东西时还写着"确定购买"的错位）；
  · 确认 → `MerchantPanel.sell_requested` → `WorldMap.item_sell_requested` →
    `GameRoot._on_item_sell_requested()` → `sell_item()`：出包 + `Global.coins += 卖价`；
  · 卖价 = `int(item_cost × 0.75)`（`GameRoot.SELL_REFUND_RATIO`，**与老的 ShopPanel 一致**，截断不是四舍五入：
    12 金币卖 9）；留 25% 折旧，买进卖出会亏，堵住"低买高卖刷钱"；
  · 想卖**身上穿着**的装备要先脱下来（穿着的在某个角色的 `Global.equipment_by_character` 里，不在背包里）；
  · **单独开背包**（没开商人）时点格子不会弹框，只在信息行回一句"要跟商人交易时才能卖东西"，不会"点了没反应"；
  · 确认框算**模态**：弹出时交易货架与背包格子都临时不可聚焦（`confirm_changed` → `set_slot_focus_enabled(false)`），
    焦点只在「确定卖出 / 确定购买」与「取消」之间；`Esc` 只关确认框；
  ⚠ 交易面板**故意没有全屏遮罩**（早先那个 `Dim` 已删）：全屏 ColorRect 默认会吃掉鼠标事件、
    还会把并排的背包压暗 —— 那正是"背包看起来点不动"的元凶。世界地图的压暗由背包那一层（0.35）负责；
  ⚠ 而且交易面板的**根节点**（铺满全屏的 Control）必须 `mouse_filter = IGNORE`：Control 默认是 STOP，
    一个全屏 STOP 等于"整屏都是交易窗口的地盘"，并排背包的 `mouse_entered` / `pressed` 全被它吞掉
    （.tscn 里设了 `mouse_filter = 2`，`MerchantPanel._ready()` 里再兜一次）；
  ⚠ 还有一个更隐蔽的连带故障：`TooltipManager` 是 autoload，它 preload 的
    `scenes/ui/hover_card/*.tscn` 一旦缺失，整个 autoload 会加载失败 → `BagPanel._make_slot()` 里
    `TooltipManager.show_for_control(...)` 变成"在 null 上调用"，**GDScript 会中断整个函数** →
    `slot.pressed.connect(...)` 和 `_slots.append(slot)` 都执行不到，症状就是"背包格子点不动、也不进焦点环"。
    改这块代码时别把悬停提示那几行挪到 `pressed` 之后再指望它"反正只是提示"；
- **一屏只看 8 行**：可见区域 = `BagPanel.VISIBLE_ROWS`(8) 行，高度由代码算出来
  （`8×68 + 7×10 = 614`，写进 `ScrollContainer.custom_minimum_size`，.tscn 里手填的数字会被覆盖）——
  所以"能放 120 件"和"一屏看 64 格"是两件事，剩下的行靠**滚轮**或**键盘往下走**看
  （`follow_focus = true`，焦点一走到底部就自动滚）；
  ⚠ `SLOT_SIZE = 72` 是**按 1920×1080 反推**的：要同时装下"标题 + 角色区（308 高）+
  信息行 + 7 行方格"且不顶出屏幕（面板总高 994，1080 下 y = 70~1064）。屏幕更高时数值不变；
- **角色区**（用户要求的版面）：中间是**玩家形象**，贴图取 `UnitStats.icon`
  —— 和地图上那个小人用的是同一张（`assets/sprites/Players/Player_1.png`），没选角色时显示占位文字；
  形象**左右各 3 个装备栏**（`EQUIP_SLOTS_PER_SIDE`，运行时按 `EQUIP_LAYOUT` 生成）；
  **形象下面一行是名字牌**（`名字（i/n）`），再**两边各一个 ◀ / ▶ 箭头**用来切换团队成员：
  - 箭头在**团队名册**里前后翻页（`WorldMap._party` → `GameRoot.party`，只读），
    换的只是这个窗口展示的形象 + 名字；**不会**动 `Global.main_player_selected` /
    队长 / 上阵名单 —— 那些是"谁上场打仗"，属于 `GameRoot` 的数据，界面只读不改；
  - 打开背包时默认展示**当前主角**（`_index_of_leader()` 按引用和 `resource_path` 两重比对找他），
    找不到就展示团队第一个人；◀ 从第一个人往前翻会**回卷**到最后一个人；
  - 团队只有 1 个人（或空）时箭头**置灰** —— 没得切，也就不占键盘焦点的一站；
  - 箭头是会进焦点环的 `Button`（键盘也能切换），但 `W/S` 的走格只看背包格子（`_slots`），
    不受箭头影响：方向键用 Godot 的几何导航就能走到箭头，`Enter` / 空格 / `E` 按下它；
- **六个装备栏 = 六种固定类型**（用户要求）：**左一 头盔 / 左二 武器 / 左三 腰带 /
  右一 项链 / 右二 衣服 / 右三 鞋子**（`BagPanel.EQUIP_LAYOUT`，栏位类型枚举是
  `ItemBase.EquipType`，中文名在 `ItemBase.equip_type_name()`）：
  - **空格子**：`disabled`，画一圈暗描边 + 居中写栏位名（"头盔"/"武器"…），
    悬停有原生 tooltip 说明"这里收什么、怎么穿"；不可点、也不进焦点环；
  - **有装备**：画图标 + 按稀有度描边 + 底部保留栏位名，悬停/聚焦弹属性卡，
    **点一下（或焦点上按 E）= 脱下来放回背包**（`BagPanel.unequip_requested` →
    `WorldMap.unequip_requested` → `GameRoot.unequip_slot()`）；背包满时拒绝脱（东西没地方去）；
  - **怎么穿**：**平时**（没开商人）点背包里的一格 = 给**当前展示的角色**穿上
    （`BagPanel.item_activated` → `WorldMap._on_bag_item_activated` → 没开商店就发
    `equip_requested(character, item)` → `GameRoot.equip_item(character, item)`，
    穿到 `item.get_equip_type()` 指定的那一栏）；
    那一栏原来有东西时**自动换下来放回背包**（不需要先脱）；
  - **每人一套（用户要求）**：穿着的在 `Global.equipment_by_character`
    （`角色键 → { 栏位类型 → ItemBase }`，角色键 = `UnitStats.resource_path`，见
    `GameRoot.character_key()`），没穿的在 `Global.equipped_weapons`（**全队共用的背包**）——
    两者互补，所以"背包里没有 = 队伍里某个人身上穿着"，**卖出前要先脱**；
    背包界面用 `◀` / `▶` 切到谁，6 个装备栏就显示谁的那一套（`BagPanel.current_character()`），
    换上/脱下也只动这个人；角色离队时装备留在他名下（重新招募会看到原来的装备）；
  - **现在有什么**：26 件 `ItemEquipment`（`resources/items/equipment/`，图标在
    `assets/sprites/equipment/`），六类各 4~5 件、按 `COMMON → LEGENDARY` 分档，
    属性是随机生成后烘进 .tres 的（攻击/防御/生命/暴击/速度/格挡，口径同 `UnitStats`）；
  - **以后加新装备类型**：① 在 `ItemBase.EquipType` **末尾**追加成员；
    ② 在 `equip_type_name()` 补中文名；③ 在 `BagPanel.EQUIP_LAYOUT` 里摆进某格；
    ④ 新装备继承 `ItemBase` 并把 `equip_type` 设成那个类型（或在子类里重写
    `get_equip_type()`，自己决定栏位）。
    背包元素类型已经是 **`ItemBase`**、`BagPanel.show_bag()` / 格子也都是按 `ItemBase` 写的，
    所以新装备**不用改背包/交易面板的代码**就能进背包、被穿上；
- **没有「关闭」按钮、也没有按键提示文案**（按要求移除）：关背包只有 `ESC` 和 `B` 两条路。
  `BagPanel.close_requested` 信号保留着，以后想加「整理」/「关闭」按钮可以直接接（WorldMap 已连好）。

- **打开方式**：地图上按 `B`（随时），或 `ESC` →「背包」。两条路的 `ESC` 不同：
  从菜单进来的会退回菜单（逐级返回），按 `B` 直接开的则直接回游戏 —— 靠 `WorldMap._bag_from_menu` 记着；
- **里面是什么**：`Global.equipped_weapons`。商人买到的东西直接 append 进这个数组
  （`GameRoot.buy_item()`），所以**"买了就进背包"这条链的落点就是这个数组**；
  格数上限 `GameRoot.BAG_SLOTS = 120`，满了商人那边会置灰并给出理由；
- **看属性（重点）**：格子上挂了 `mouse_entered` → `TooltipManager.show_for_control(格子, 道具)`，
  弹出的是工程既有的 `hover_item_card`（图标 + 名字 + 类型 + 伤害/冷却/射程/暴击，按稀有度配色），
  `mouse_exited` 收起；**键盘焦点移上去也弹同一张卡**（`focus_entered`/`focus_exited`），
  所以纯键盘也能看属性 —— TooltipManager 的文档里本来就写着"手柄/键盘导航靠它"。
  ⚠ 正因为用了提示卡，格子上**不要**再设 `button.tooltip_text`（会和卡片双份显示）；
- **键盘走格**：`← ↑ → ↓` 由 Godot 的 GUI 焦点系统按几何位置走；
  `W A S D` 由 `BagPanel._unhandled_input()` 自己处理（左右 ±1 格、上下 ±一整行 = ±6）——
  这也是背包不能用 `WorldMap` 那套线性焦点环的原因（那套上下只走一格，在 8 列网格里等于"斜着走"）；
  所以 `WorldMap` 的背包分支**故意不调 `_overlay_nav()`**（调了会把 WASD 先吃掉）；
- **空格子**：`disabled = true`（画成暗色格位），既不可点也不进焦点环 ——
  方向键会自然跳过它们；
- ⚠ **还没有的**：合成没做；装备的**数值加成**也还没做（穿/脱只改数据与界面，
  战斗仍读 `UnitStats`，没读 `Global.equipment_by_character`）—— 卖出/穿脱都已经能用了。
  要加的话照招募/商店那套：面板 emit 请求信号 → `WorldMap` 转发 → `GameRoot` 改数据 →
  回调刷新（`_rebuild_bag()` 已经准备好被复用）。

## 操作菜单（Esc）与队伍管理页

两个浮层都是**独立场景**，由 `WorldMap._setup_overlays()` 运行时实例化后挂到世界地图的
`UI`（CanvasLayer）下面 —— 它们不跟着相机跑，也不参与世界的 y_sort：

| 场景 | 是什么 | 信号 → 谁处理 |
|---|---|---|
| `scenes/ui/pause_menu/pause_menu.tscn` | 操作菜单：继续游戏 / 队伍管理 / 背包 / 角色属性 / 进入战斗 / 返回主菜单 | `resume_requested` → 关菜单；`party_requested` / `bag_requested` / `stats_requested` → 开对应二级页；`battle_requested` / `title_requested` → 直接接到 `_on_battle_pressed` / `_on_back_pressed`（**与地图上那两个常驻按钮同一条通路**，不存在两份实现） |
| `scenes/ui/party_panel/party_panel.tscn` | 队伍管理页：每个成员一行（头像 + 属性 + 上阵状态 + 「上阵/下阵」+「移出团队」），标题带「团队 n 人 · 上阵 m/5」 | `deploy_requested` / `undeploy_requested` / `remove_requested` → `WorldMap.party_deploy_requested` / `party_undeploy_requested` / `party_remove_requested` → `GameRoot` 对应的三个 `_on_party_*`；`close_requested` → 退回操作菜单 |
| `scenes/ui/merchant_panel/merchant_panel.tscn` | 商人货架：顶部**居中显示 NPC 名字** + 结果提示 + **6 列方格**（84px 格子，**总共 6×20 = 120 格、一屏 6×10**，货不足补空格子；窗口 610×1038 ≈ 背包的 662×1044；贴屏幕**最左边**；**没有全屏遮罩**）；每格一个图标 + 价格角标（右下）/「持×n」角标（左上），点一下弹**确认框**（`z_index = 100`，买卖共用）。没有台词/金币/按键提示/「关闭」按钮（都按需求移除了） | `buy_requested` → `WorldMap.item_buy_requested`；`sell_requested` → `WorldMap.item_sell_requested` → `GameRoot._on_item_sell_requested()`；`confirm_changed` → WorldMap 同步背包格子焦点；`close_requested` → 关面板回游戏（并收掉并排的背包）；`cancel_confirm()` 给 WorldMap 判 Esc 层级 |
| `scenes/ui/bag_panel/bag_panel.tscn` | 背包：右下角窗口，标题「背包 n/120」+ 角色区（「◀ 形象(名字牌) ▶ + 左右各 3 个 **96px 装备栏**（头盔/武器/腰带 · 项链/衣服/鞋子）」，形象框 240×308）+ 信息行（**左金币 / 右 MessageLabel**）+ **8 列方格**（120 格，一屏 8×8 可滚动，格子 68px），格子上悬停/聚焦弹属性卡、**点一下 = 卖（交易中）/ 穿给当前角色（平时）**，装备栏点一下 = 从当前角色身上脱 | `item_activated` → `WorldMap._on_bag_item_activated()`（交易中→弹卖确认框；平时→`equip_requested(current_character, item)`）；`unequip_requested` → `WorldMap.unequip_requested(current_character, slot)` → `GameRoot._on_unequip_requested()`；`close_requested` → 关面板（当前没有按钮发它：关闭靠 Esc / B）；`set_slot_focus_enabled()` 供 WorldMap 在「确认框弹出时」临时收焦点；◀ / ▶ 只在面板内部翻团队成员（并刷新装备栏）；`current_character()` 给 WorldMap 问"现在穿给谁" |
| `scenes/ui/character_area/character_area.tscn` | **角色形象区**（属性面板上半部分用的复用场景，外观和背包那块**逐像素一致**）：◀ 形象 240×308（名字牌）▶ + 左右各 3 个 **96px 装备栏**（头盔/武器/腰带 · 项链/衣服/鞋子）。装备栏悬停弹属性卡、点已穿的 = 请求脱下（`unequip_requested`，判定仍在 `GameRoot.unequip_slot()`）；装备栏是鼠标专用、不进焦点环（背包同屏时那边已有一份可点的） | `show_party(party)` / `current_character()` / `show_character()` / `step_player(±1)` / `refresh()` / `focus_ring()`（只有 ◀ / ▶）；发 `character_changed` / `unequip_requested` |
| `scenes/ui/stats_panel/stats_panel.tscn` | 角色属性：和背包**同宽 662**、贴屏幕**左下角**（背包在右下角，天然不重叠）的窗口。**高度始终等于背包的高度**：WorldMap 打开时调 `BagPanel.refresh_panel_height()`（背包没显示也能先算出"该有多高"），所以**单开属性面板和背着背包时一样高**；高度**只按属性页算一次并缓存** —— 切到技能页不会变。下半部分是**滚动层**，只有技能页内容放不下时才出现滚动条（属性页永远不滚；算高度时留了 `CONTENT_SLACK = 8px` 余量，避免取整导致 1px 溢出的假滚动条）。**上半部分 = 上面那个 `CharacterArea`**（形象 + 六个装备栏，和背包完全一致）；它下面是一排**页签「属性 / 门派技能 / 其他技能」**（ButtonGroup 互斥，换页只重建下半部分，上半部分和暂存加点都保留；每次打开默认回到属性页）。**属性页**：仿"人物属性"的**固定两列表格**：左列 名称 / 种族 / 气血 / 魔法 / 伤害 / 法伤 / 防御 / 速度，右列 等级 / 门派 / 体质 / 力量 / 敏捷 / 魔力 / 耐力 / 自由点数（基础属性带 **＋ / －**，自由点数右边 **确认加点**）；**经验单独占一行、右边是「升级」按钮**（10 级起手动升级：扣经验升一级，成功后弹一条提示）；再隔一段直接展示 输出（暴击率 / 暴击伤害 / 封印命中率 / 治疗量）与抗性（躲避 / 格挡率 / 格挡值 / 抗暴击率 / 爆伤减免 / 抵抗封印）。**门派技能页**：一张技能表（`名称 / 等级 / 类型 / 目标 / 消耗`，每行可点），点中某行 → 下面显示该技能的「描述 / 条件（升级花费）/ 拥有」+「升级 / 升级10次」按钮。**其他技能页**：`UnitStats.skills` 里配的 SkillData（和门派技能分开）。**没有全屏遮罩** | `show_stats(party)` / `current_character()` / `show_character()` / `refresh()` / `focus_ring()`（页签 + ◀ ▶ + ＋ － + 确认加点）/ `set_linked_height()` / `points_spent` / `unequip_requested`；**加减只改面板里的暂存差值**（`_pending`），点「确认加点」才走 `GameRoot.apply_attr_deltas()` 一次性落盘；换人丢弃暂存、保留当前页签；◀ / ▶ 只改"看谁"并发 `character_view_changed`（WorldMap 让背包跟着切）；只读 `UnitStats`、`GameRoot.level_of()/exp_of()`、`GameRoot.sect_of()` / `sect_skill_level()` / `derived_stats()` / `equipment_in` |

**Esc 的逐级语义**（`WorldMap._unhandled_input()` 里的状态机，顺序即优先级）：

```
没有任何 UI          → Esc 打开操作菜单
操作菜单开着          → Esc 关掉菜单，回游戏
背包开着             → Esc（或 B）关掉背包；从菜单进来的退回菜单，按 B 开的直接回游戏；
                       C 会在旁边再打开角色属性（对齐到背包当前看的人）
角色属性面板开着      → Esc / C 只收属性面板（**背包若开着就留着**）；B 单独开关背包
商人交易中            → Esc 先关确认框（如果开着），再按才关整个交易（并收掉并排的背包）
队伍管理页开着        → Esc 退回操作菜单（上一级），面板没开时才会开菜单
NPC 对话面板开着      → Esc 关掉面板（不会顺手把菜单也打开）
```

> ⚠ 顺序即优先级：**交易 / 属性面板都排在背包前面** —— 交易打开时背包是"配件"（一起开、一起关）；
> 属性面板则和背包**完全独立**（各自开关，同时开着时共用一份焦点环）。
> 谁在前谁说了算（见 `WorldMap._unhandled_input()` 里的分支顺序与 `_bag_with_shop`）。
>
> ⚠ 背包那一支**不走 `_overlay_nav()`**：背包的 WASD 归 `BagPanel` 自己管（网格语义），
> `WorldMap` 只处理 Esc / B。角色属性面板是只读的，只接 Esc / C / B，其余输入忽略；
> 其余浮层则统一由 `WorldMap` 转发 W/S/E。

**键盘焦点是怎么工作的**（这是"整个游戏都能纯键盘玩"的关键，主菜单也用同一套）：

- 共用工具都在 **`Global`**（"UI 键盘焦点工具"一节）：`can_focus` / `collect_focusable` /
  `step_focus` / `activate_focused` / `is_interact_event`。抽到那里的原因：主菜单也要键盘操作，
  两处各写一遍的话，"置灰按钮不进焦点环"这类规则迟早分叉；
- `↑↓` / `Enter` / `空格` 走的是 **Godot 内置的 `ui_*` 动作 + GUI 焦点系统**：
  方向键换焦点、`ui_accept` 按下焦点上的按钮 —— 这些在更早的 GUI 阶段就被消费掉了，
  所以 `_unhandled_input()` 收不到，也不需要我们重复实现；
- `W S` / `E` 是工程自己的动作（`move_up` / `move_down` / 没配的交互键），GUI 不认，
  于是在 `WorldMap._overlay_nav()`（主菜单则是 `TitleScreen._unhandled_input()`）里补上：
  W/S 按"焦点环"循环、E 直接 `pressed.emit()`；
- **屏幕/浮层一出现就必须 `grab_focus()` 一个按钮** —— 按钮本身是可聚焦的，但没人给它焦点时
  方向键按下去什么也不会发生（主菜单以前就是这样）；
- **焦点环**（`WorldMap._focus_ring` / `TitleScreen._focus_ring`）是"当前界面上所有可点按钮
  按视觉顺序排成的数组"，由 `collect_focusable()` 收集 —— 它**跳过 disabled 的按钮**
  （置灰按钮 `grab_focus()` 无效，留在环里会让 W/S 卡住不动；主菜单那个恒灰的
  「继续游戏」就是这样被排除的）；
- 打开浮层时还要把地图上那两个常驻按钮设成 `FOCUS_NONE`（`_sync_world_button_focus()`），
  否则按方向键时 GUI 会按空间方向找到它们，焦点就"跑出"浮层了；
- 顺序坑：`grab_focus()` 必须排在 `show()` **之后** —— 对隐藏在不可见父节点下的控件
  设焦点是静默失败的（不报错，键盘整片失灵），这个坑在 `_open_panel()` 里有注释。
