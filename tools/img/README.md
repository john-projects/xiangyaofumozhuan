# 印章 / 克隆工具

修 AI 图里"不合理"的地方（文字糊成乱码、物件重复、边缘断裂）：
**找一块本来正常的纹理 → 盖到坏的地方 → 边缘羽化融合。**

## 用法

```powershell
$py = "C:\Users\yong\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"

# 单次盖章：把 (100,400)-(180,470) 这块盖到 (120,520)
& $py tools\img\stamp.py --src in.png --out out.png `
	--from 100,400,180,470 --to 120,520 --feather 6

# 批量（推荐：可以多次叠盖，把接缝藏住）
& $py tools\img\stamp.py --src in.png --out out.png --ops ops.json
```

`ops.json`：

```json
[
  {"from": [111, 498, 140, 572], "to": [133, 512], "feather": 4,  "opacity": 1.0},
  {"from": [113, 502, 142, 576], "to": [135, 516], "feather": 9,  "opacity": 0.75},
  {"from": [110, 494, 139, 568], "to": [131, 508], "feather": 12, "opacity": 0.55}
]
```

| 字段 | 作用 |
|---|---|
| `from` | 采样区域 `[x0, y0, x1, y1]` |
| `to` | 目标左上角；也可用 `to_center: [x, y]` 按中心放 |
| `scale` | 采样块缩放（>1 放大） |
| `flip` / `rotate` | 水平翻转 / 旋转，避免"一眼看出是复制的" |
| `feather` | 边缘羽化像素，接缝明显就调大 |
| `opacity` | 叠盖时用 0.5~0.8，能柔和过渡 |

## 经验

- **一次盖不干净很正常**：同一块地方盖 2~3 次、每次 `to` 偏移几个像素、`opacity` 递减，接缝会消失；
- **采样区要选"光照方向一致"的地方**（同一块石头的另一侧、同一条路的旁边）；
- 修的如果是**大面积**（比如整栋悬空的房子），先找一块相似的地面/山体盖上去，再在边缘补几笔草和石头。

---

# fix_map.py：给整张地图"补路 + 修乱码"

```powershell
$py = "C:\Users\yong\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
& $py tools\img\fix_map.py --src 原图.jpg --out 修好.png --compare 对比图.png
```

它做三件事：

1. **磨平乱码文字**：`erase_text(box, radius, opacity)` —— 中值模糊 + 少量噪声，
   比整块克隆自然（石碑上的 AI 乱码就是用它抹的）；
2. **补路**：`paint_path(pts, width, brightness)` —— 从现有路面采样一块石板纹理，
   沿折线镜像平铺 + 羽化边缘，视觉上像"路延伸过去"；
3. **印章修补**：`stamp(...)`，和上面 `stamp.py` 同一套参数。

要改哪条路，直接改脚本里的 `ROADS` 列表（坐标是在 1200×896 这张图上量的）：

```python
ROADS = [
	dict(pts=[(742, 700), (768, 716), (790, 726)], width=26),   # 小桥左端接路
	dict(pts=[(930, 728), (972, 714), (1010, 700)], width=26),  # 小桥右端接路
	dict(pts=[(1010, 700), (1064, 676), (1108, 648)], width=28),# 右下横路接右岸
]
```

> 注意：`paint_path` 的采样纹理尺度要跟周围路面接近（默认取桥边那块），
> 否则会像"贴了一块新石板"。亮度用 `brightness` 微调（0.98~1.03）。
