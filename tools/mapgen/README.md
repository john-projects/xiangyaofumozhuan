# mapgen —— 布局草图 → Godot 大地图素材

一张 4096×2304 的大图不适合整张加载，也不适合一次画完。这个脚本把工作拆成两半：

- **你只画"布局草图"**（低分辨率色块：水、路、房、树、桥）；
- **脚本产出**成图、碰撞掩膜、运行时切片、JSON 元数据、验收预览。

美术细化（AI 上色/手绘）产出的成图可以直接喂进来，**掩膜始终以草图为准**，这样美术怎么改都不会让碰撞和图错位。

## 依赖

Python 3.10+ 且装了 `pillow`、`numpy`：

```bash
pip install pillow numpy
```

Windows 上不用管 Python 在哪，直接用启动器（会自动挑一个装了依赖的解释器）。

**推荐 `run.cmd`**（cmd / PowerShell 都能直接跑，不受 PowerShell 执行策略影响）：

```powershell
.\run.cmd demo --out out\demo
```

`run.ps1` 功能一样，但 Windows 默认禁止跑 .ps1，会报 `UnauthorizedAccess`。要嘛用 `run.cmd`，要嘛临时绕过：

```powershell
powershell -ExecutionPolicy Bypass -File .\run.ps1 demo --out out\demo
```

或者永久放开当前用户的脚本策略（一次即可）：

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

也可以完全不用启动器：

```powershell
python mapgen.py demo --out out\demo
```

## 快速开始（不需要任何素材）

```bash
python mapgen.py demo --out out/demo
```

会生成一张演示草图并跑完整流程，输出在 `out/demo/`。

## 正式用法

**只用草图放大**（还没上色，先看结构）：

```bash
python mapgen.py build \
  --sketch layout.png \
  --id taohuacun \
  --out out/taohuacun \
  --scale 4          # 1024×576 → 4096×2304
```

**草图定碰撞、AI 出图定美术**（推荐）：

```bash
python mapgen.py build \
  --sketch layout.png \
  --image  ai_final.png \
  --id taohuacun \
  --out out/taohuacun
```

`--image` 和 `--sketch` 尺寸不一致时，草图会用 NEAREST 放大到成图尺寸再算掩膜（保持色块边界锐利）。

常用参数：

| 参数 | 默认 | 说明 |
|---|---|---|
| `--chunk` | 1024 | 切片尺寸；世界 4096×2304 会切成 4×3=12 块 |
| `--scale` | 4 | 无 `--image` 时的放大倍数 |
| `--tolerance` | 32 | 调色板容差，只用于提示"草稿里有杂色" |
| `--spawn` | 0.5 0.62 | 出生点（归一化） |

## 草图调色板（必须用这些纯色）

| 用途 | 颜色 | Hex | 可走 |
|---|---|---|---|
| 草地 | 绿 | `#6FA35B` | ✅ |
| 沙地 | 浅黄 | `#D6C496` | ✅ |
| 道路 | 土黄 | `#C8A96E` | ✅ |
| 桥 | 棕 | `#A67C52` | ✅ |
| 水 | 蓝 | `#3E7CB1` | ❌ |
| 深水 | 深蓝 | `#235078` | ❌ |
| 房屋 | 深棕 | `#8B5A2B` | ❌ |
| 岩石 | 灰 | `#7A7A7A` | ❌ |
| 树 | 深绿 | `#2E6E3C` | ❌ |

> 想在 Krita/PS 里画：把这张表存成色板，只允许这 9 色。桥要压在河上，掩膜才会出现"可通行的白缝"。

## 输出目录

```
out/taohuacun/
├─ map_taohuacun.png   成图（直接当 MapData.texture）
├─ walk_mask.png       碰撞掩膜（255=可走 / 0=阻挡，和成图同尺寸）
├─ chunks/             运行时切片（chunk_0_0.png …）
├─ preview.png         缩略总览：左图右掩膜 + 块网格（验收用）
└─ map.json            元数据
```

`map.json` 结构：

```json
{
  "id": "taohuacun",
  "width": 4096, "height": 2304,
  "chunk_size": 1024, "cols": 4, "rows": 3,
  "chunks": ["chunks/chunk_0_0.png", "..."],
  "image": "map_taohuacun.png",
  "walk_mask": "walk_mask.png",
  "spawn": [0.5, 0.62],
  "pois": [],
  "report": { "walkable_ratio": 0.806, "unknown_color_ratio": 0.007, "palette": { } }
}
```

## 接进 Godot

拿到 `walk_mask.png` 后，`MapData` 加两个字段：

```gdscript
@export var walk_mask: Texture2D          ## 白色可走、黑色阻挡
@export var chunk_meta: String = ""       ## map.json 的 res:// 路径（可选，按块加载时用）
```

移动处（`world_map.gd` 的 `_process` 里改 `player.position` 那行）加一次采样：

```gdscript
## 采样掩膜：像素为黑 = 不能走。world_pos 是地图世界坐标（0,0 = 图左上角）。
func _is_walkable(world_pos: Vector2) -> bool:
    if _map == null or _map.walk_mask == null:
        return true
    var img := _map.walk_mask.get_image()
    var px := Vector2i(world_pos / _map.map_scale)      # 世界坐标 → 图片像素
    if px.x < 0 or px.y < 0 or px.x >= img.get_width() or px.y >= img.get_height():
        return false
    return img.get_pixelv(px).r > 0.5
```

> 性能提示：`get_image()` 每次都会取一次 Image，实际项目里在 `setup()` 时缓存成成员变量。

按块加载（可选，大图必须）：

```gdscript
## 相机视野内的块才显示，其余隐藏 —— 4096×2304 全显示会吃掉 40MB+ 显存。
func _refresh_chunks() -> void:
    var view := camera.get_viewport_rect()
    var cam := camera.get_screen_center_position()
    for item in _chunk_nodes:
        var rect: Rect2 = item["rect"]
        item["sprite"].visible = rect.grow(256.0).has_point(cam)
```

## 已知限制

- 掩膜用 NEAREST 放大，**边界是硬的**；想要"贴边滑动"手感，在 `_is_walkable` 里做轴分离（x、y 分别判定）。
- 只认 9 种纯色，草稿里手抖的抗锯齿边缘会被算成"最近色"，所以尽量用硬边笔刷。
- 不做 POI 自动识别；`pois` 目前是空数组，需要的话按"道路交叉点 / 桥中心"再写一个检测函数。
- 切片是**无重叠**的；如果你要先分块给 AI 细化再加回来，那是另一个 `--mode refine` 流程（还没做，需要就叫）。
