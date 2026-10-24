#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""blender_bridge.py —— 直连 BlenderMCP 插件的 socket，在 Blender 里执行代码。

Blender 端：偏好设置里启用 "BlenderMCP" 插件 → 侧边栏 MCP 面板点 "Start MCP Server"
（默认 localhost:9876）。本脚本就是那个 socket 的客户端，不需要 MCP 协议层。

用法：
    python tools/blender/blender_bridge.py ping
    python tools/blender/blender_bridge.py info
    python tools/blender/blender_bridge.py py "import bpy; print(len(bpy.data.objects))"
    python tools/blender/blender_bridge.py shot  out.png
    python tools/blender/blender_bridge.py file  script.py      # 跑一个 .py 文件
"""

from __future__ import annotations

import base64
import json
import socket
import sys
import time

HOST, PORT = "127.0.0.1", 9876


def send(command: dict, timeout: float = 120.0) -> dict:
    with socket.create_connection((HOST, PORT), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall(json.dumps(command).encode("utf-8"))
        chunks = []
        while True:
            data = sock.recv(65536)
            if not data:
                break
            chunks.append(data)
            try:
                return json.loads(b"".join(chunks).decode("utf-8"))
            except json.JSONDecodeError:
                continue
    raise RuntimeError("Blender 没返回数据（插件没启动？）")


def main() -> None:
    if len(sys.argv) < 2:
        print(__doc__)
        return
    action = sys.argv[1]

    if action == "ping":
        print(send({"type": "ping"}))
    elif action == "info":
        r = send({"type": "get_scene_info"})
        print(json.dumps(r, ensure_ascii=False, indent=2)[:4000])
    elif action == "py":
        code = sys.argv[2]
        r = send({"type": "execute_code", "params": {"code": code}})
        print(json.dumps(r, ensure_ascii=False, indent=2)[:8000])
    elif action == "file":
        with open(sys.argv[2], encoding="utf-8") as f:
            code = f.read()
        r = send({"type": "execute_code", "params": {"code": code}})
        print(json.dumps(r, ensure_ascii=False, indent=2)[:8000])
    elif action == "shot":
        out = sys.argv[2] if len(sys.argv) > 2 else "shot.png"
        r = send({"type": "get_viewport_screenshot",
                  "params": {"max_size": 1600, "filepath": out}}, timeout=180)
        print(json.dumps({k: v for k, v in r.items() if k != "result"},
                         ensure_ascii=False))
        res = r.get("result") or {}
        if isinstance(res, dict) and res.get("image"):
            with open(out, "wb") as f:
                f.write(base64.b64decode(res["image"]))
            print(f"截图已保存：{out}")
        else:
            print(str(res)[:800])
    else:
        print(f"未知动作：{action}")


if __name__ == "__main__":
    main()
