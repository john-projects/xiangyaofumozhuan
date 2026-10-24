# Blender MCP 配置说明

## 已装好的三件东西

| 组件 | 位置 | 作用 |
|---|---|---|
| **MCP 插件（Blender 端）** | `%APPDATA%\Blender Foundation\Blender\5.2\scripts\addons\blender_mcp.py` | 在 Blender 里开一个 socket 服务（`localhost:9876`），接收指令 |
| **MCP 服务端** | `C:\Users\yong\.dsh\tools\blender-mcp\.venv\Scripts\blender-mcp.exe` | 把 MCP 协议翻译成上面那个 socket 协议 |
| **DSH 侧配置** | `C:\Users\yong\.dsh\profiles\desktop\cordis.patch.yml` 的 `mcp-blender` 条目 | 让 DSH 启动这个 MCP 服务，工具名变成 `mcp__blender__*` |

> 注：PyPI 上的 `blender-mcp` 已经改名 `mcp-for-blender`，装的是 2.x；
> 它仍然通过 9876 端口跟 Blender 通信，协议没变。

## 每次使用前（Blender 侧）

Blender 打开后 **必须点一次 Start MCP Server**：

- 3D 视图按 `N` → 侧边栏找到 **MCP** 标签 → **Start MCP Server**
- 或者命令行启动时自动开：
  ```powershell
  & "E:\dream\blender-5.2.0-windows-x64\blender-5.2.0-windows-x64\blender.exe" `
      --python-expr 'import addon_utils, bpy; addon_utils.enable("blender_mcp", default_set=True); bpy.ops.blendermcp.start_server()'
  ```

## 在 DSH 里用

1. 重启 DSH（托盘退出再打开）——配置在启动时加载；
2. 之后我这边会多出 `mcp__blender__*` 工具，例如：
   - `mcp__blender__get_scene_info`：看场景里有什么
   - `mcp__blender__execute_blender_code`：在 Blender 里跑任意 `bpy` 代码
   - `mcp__blender__look`：截图看结果

## 不想重启 DSH 时的替代方案

现成的直连脚本，能立刻用（不经过 MCP 协议层，直接打 9876）：

```powershell
$py = "C:\Users\yong\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"

& $py tools\blender\blender_bridge.py ping
& $py tools\blender\blender_bridge.py info
& $py tools\blender\blender_bridge.py py "import bpy; print(len(bpy.data.objects))"
& $py tools\blender\blender_bridge.py file some_script.py
& $py tools\blender\blender_bridge.py shot out.png
```

协议很简单：`{"type": "...", "params": {...}}` 的 JSON，一行一个请求。
支持的命令类型：`ping` / `get_scene_info` / `get_object_info` / `execute_code` /
`get_viewport_screenshot` / `list_scene_items` 等（见插件源码里的 handlers 表）。

## 排错

| 现象 | 原因 |
|---|---|
| `Connection refused` | Blender 没开，或没点 Start MCP Server |
| `Address already in use` | 开了两个 Blender，都抢 9876；关掉一个 |
| DSH 里没有 `mcp__blender__` 工具 | 没重启 DSH，或 `cordis.patch.yml` 缩进/路径写错 |
| 工具报 Blender 版本不匹配 | 插件版本旧了：`blender-mcp install-addon` 覆盖安装 |
