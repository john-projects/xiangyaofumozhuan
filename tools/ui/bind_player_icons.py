# -*- coding: utf-8 -*-
"""把玩家 .tres 的 icon 换成新裁的头像（portraits/<中文名>.png）。"""

import os
import re

ROOT = r"E:\dream\godot\xiangyaofumozhuan"
PLAYERS = os.path.join(ROOT, "resources", "units", "players")
NAMES = ["厉狂澜", "夜魑", "燕如意", "行修", "陆孤鸣", "霓裳"]


def uid_of(png: str) -> str:
    imp = png + ".import"
    if not os.path.exists(imp):
        return ""
    m = re.search(r'^uid="(uid://[^"]+)"', open(imp, encoding="utf-8", errors="ignore").read(), re.M)
    return m.group(1) if m else ""


for name in NAMES:
    tres = os.path.join(PLAYERS, f"{name}.tres")
    if not os.path.exists(tres):
        print("缺少", tres)
        continue
    png = os.path.join(ROOT, "assets", "sprites", "units", "players", "portraits", f"{name}.png")
    uid = uid_of(png)
    text = open(tres, encoding="utf-8").read()
    # 删掉旧的 icon 贴图 ext_resource（只删 Texture2D 那条），再插新的
    text = re.sub(r'^\[ext_resource type="Texture2D"[^\n]*\n', "", text, flags=re.M)
    if uid:
        line = f'[ext_resource type="Texture2D" uid="{uid}" path="res://assets/sprites/units/players/portraits/{name}.png" id="1_avatar"]'
    else:
        line = f'[ext_resource type="Texture2D" path="res://assets/sprites/units/players/portraits/{name}.png" id="1_avatar"]'
    text = text.replace('[resource]', line + "\n\n[resource]")
    text = re.sub(r"^icon = ExtResource\([^\)]*\)$", 'icon = ExtResource("1_avatar")', text, flags=re.M)
    with open(tres, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    print("已更新", name, "uid=", uid or "(无，用路径)")
