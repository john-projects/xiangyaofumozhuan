# 世界地图（scenes/world/）

可探索的地图：**玩家自由走动 + 相机跟随 + 地图等比放大 + 固定 NPC + 跟 NPC 对话传送（双向）**。

## 操作

| 操作 | 按键 |
|---|---|
| 走动 | `W A S D`（用的是项目里已有的 `move_left/right/up/down`） |
| 加速走 | `空格`（复用 `dash` 动作），世界地图里它只是加速，不是冲刺技能 |
| 与 NPC 交谈 | `E` 或 `Enter`（靠近后底部会出现"按 E 与 XX 交谈"提示） |
| 打开操作菜单 | `ESC`（没有任何面板开着时 = 打开菜单） |
| 菜单 / 面板里选择 | `↑↓` 或 `W S`（也可以直接用鼠标点） |
| 菜单 / 面板里确认 | `Enter` / `空格` / `E` 都能按下当前高亮的按钮 |
| 关闭对话框 | `ESC` 或点「再想想」 |
| 退回上一级 | 队伍管理页按 `ESC` 退回操作菜单（不是直接回游戏） |
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
│   └── Camera (Camera2D, 带平滑跟随 + 地图边界限制)
├── （NPC 直接挂在 WorldMap 下，运行时生成）
└── UI (CanvasLayer)：地图名 / 金币 / 结果提示 / 交互提示 / 进入战斗 / 返回主菜单 / 对话框
```

> NPC 为什么没有单独的容器节点：`y_sort_enabled` 只对**兄弟节点**排序，NPC 和玩家必须是兄弟，
> 玩家才能走到 NPC 身后/身前。所以 `_add_npc()` 是直接 `add_child` 到 WorldMap 上的。

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

`AUTO` 存在的意义：老 `.tres` 只填了 `destinations`，加了 `action` 字段后它们的行为**不变**。
在 `.tres` 里 `action` 是整数（`AUTO=0 / TALK=1 / TELEPORT=2 / RECRUIT_PARTY=3`），
因为枚举整数值会落盘，**不要调整 `MapNPC.Action` 的成员顺序**。

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
  然后回调 `WorldMap.notify_party_changed()` 把台词换成"XXX 加入了团队！"并重建按钮
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

## 操作菜单（Esc）与队伍管理页

两个浮层都是**独立场景**，由 `WorldMap._setup_overlays()` 运行时实例化后挂到世界地图的
`UI`（CanvasLayer）下面 —— 它们不跟着相机跑，也不参与世界的 y_sort：

| 场景 | 是什么 | 信号 → 谁处理 |
|---|---|---|
| `scenes/ui/pause_menu/pause_menu.tscn` | 操作菜单：继续游戏 / 队伍管理 / 进入战斗 / 返回主菜单 | `resume_requested` → 关菜单；`party_requested` → 开二级页；`battle_requested` / `title_requested` → 直接接到 `_on_battle_pressed` / `_on_back_pressed`（**与地图上那两个常驻按钮同一条通路**，不存在两份实现） |
| `scenes/ui/party_panel/party_panel.tscn` | 队伍管理页：每个成员一行（头像 + 属性 + 上阵状态 + 「上阵/下阵」+「移出团队」），标题带「团队 n 人 · 上阵 m/5」 | `deploy_requested` / `undeploy_requested` / `remove_requested` → `WorldMap.party_deploy_requested` / `party_undeploy_requested` / `party_remove_requested` → `GameRoot` 对应的三个 `_on_party_*`；`close_requested` → 退回操作菜单 |

**Esc 的逐级语义**（`WorldMap._unhandled_input()` 里的状态机，顺序即优先级）：

```
没有任何 UI          → Esc 打开操作菜单
操作菜单开着          → Esc 关掉菜单，回游戏
队伍管理页开着        → Esc 退回操作菜单（上一级），面板没开时才会开菜单
NPC 对话面板开着      → Esc 关掉面板（不会顺手把菜单也打开）
```

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
