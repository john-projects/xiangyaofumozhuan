# 世界地图（scenes/world/）

可探索的地图：**玩家自由走动 + 相机跟随 + 地图等比放大 + 固定 NPC + 跟 NPC 对话传送（双向）**。

## 操作

| 操作 | 按键 |
|---|---|
| 走动 | `W A S D`（用的是项目里已有的 `move_left/right/up/down`） |
| 加速走 | `空格`（复用 `dash` 动作），世界地图里它只是加速，不是冲刺技能 |
| 与 NPC 交谈 | `E` 或 `Enter`（靠近后底部会出现"按 E 与 XX 交谈"提示） |
| 关闭对话框 | `ESC` 或点「再想想」 |
| 进入战斗 | 右下角「进入战斗」按钮（打当前地图的敌人） |
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

## 招募队友（队伍系统）

- **候选来源**：`MapNPC.recruit_pool`（显式列表）优先；留空 → `Global.get_recruitable_players()`
  扫 `res://resources/units/players/`（就是选人界面那 5 个 `stats_player_*.tres`）；
  往那个目录丢一个新 `UnitStats` 的 `.tres`，它就能被招募，不用改 NPC；
- **点击之后**：`WorldMap.recruit_requested(stats)` → `GameRoot._on_recruit_requested()`
  → `GameRoot.add_party_member()`（上限 `GameRoot.MAX_PARTY_SIZE = 5`，与 Battle 的
  `Stage/PlayerSlots` 五个站位、选人界面 5 个角色一致）→ 回调 `WorldMap.notify_party_changed()`
  把面板台词换成"XXX 加入了队伍！"并重建按钮（那个按钮随即变成灰的"已在队伍中"）；
- **规则只有一份**：`GameRoot.party_count / party_has / party_can_join` 是静态函数，
  面板画按钮和真正入队用的是同一套判定，不会出现"按钮能点但加不进去"；
- **界面同步**：`GameRoot.party` 是引用语义的数组，`WorldMap._party` 是同一个实例，
  所以数据立刻同步，需要的只是"刷新文字"这一步（面板底部那行「当前队伍（n/5）：…」）；
- **战斗里怎么体现**：`_make_player_team()` 把 `party` 逐项 `duplicate()` 后交给
  `Battle.start_battle()`，每个队友就是一个额外的 `BattleUnit` —— 贴图取 `UnitStats.icon`、
  数值全取自 `.tres`，所以**队友不需要额外的角色场景**（只有"当主角"才需要
  `Global.available_players` 里那把 `name → PackedScene` 的映射）；
- **出队**：`GameRoot.remove_party_member()` 已经实现（主角不允许移除），但暂时没有 UI 调它。

**加一个新的招募 NPC**：复制 `map_jianyecheng.tres` 里 `duiyou` 那条子资源 → 改 `id` /
`display_name` / `position` / `texture` → 把 `action` 设成 `3`（`RECRUIT_PARTY`）即可。
