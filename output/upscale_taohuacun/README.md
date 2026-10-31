# 桃花村 4 倍超分测试

日期：2026-11-01。输入为新生成的 `E:/dream/godot/各种UI图/map/01_桃花村-ai.png`，与当前正式游戏地图布局不同，因此没有替换正式地图或调整 NPC、传送点。

- 模型：[Real-ESRGAN 官方动漫插图模型](https://github.com/xinntao/Real-ESRGAN/blob/master/docs/anime_model.md)，`RealESRGAN_x4plus_anime_6B`。
- 输入 1448 × 1086，输出 5792 × 4344，RGBA PNG。
- 本地 GTX 960 推理，192 像素分块、16 像素重叠、FP32。透明通道由原图三次插值，已逐像素校验。
- 局部边缘更清楚；花叶有明显的平滑、块面化效果，不能视为恢复了真实缺失细节。
- `detail_comparison.png`：同坐标局部对比，左为原图普通放大，右为超分。
- `game_comparison.png`：实际 WorldMap 场景的相同镜头对比，左为原图，右为超分。
- `game_base.log`、`game_sr.log`：两次 Godot 预览均成功退出，世界尺寸一致为 4349.952 × 3262.464。
- 预览地图缩放从 3.0041106 降为 0.75102765，抵消像素尺寸的 4 倍变化。正式地图配置未修改。
- 最终图已另存至 `E:/dream/godot/各种UI图/map/01_桃花村-ai-4x.png`，原图保留。

复现：使用本机 Stable Diffusion WebUI 的 Python 环境运行 `tools/img/upscale_map.py --source 输入图 --model 本目录模型文件 --output 输出图`。游戏预览运行 `tools/preview_map_upscale.tscn -- --variant=base` 或 `--variant=sr`。
