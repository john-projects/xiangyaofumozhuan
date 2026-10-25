# -*- coding: utf-8 -*-
"""给玩家 .tres 绑定 portrait（全身立绘 fullbody/<中文名>.png）。"""

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
    png = os.path.join(ROOT, "assets", "sprites", "units", "players", "fullbody", f"{name}.png")
    uid = uid_of(png)
    text = open(tres, encoding="utf-8").read()
    if "id=\"2_portrait\"" in text:
        continue
    if uid:
        line = f'[ext_resource type="Texture2D" uid="{uid}" path="res://assets/sprites/units/players/fullbody/{name}.png" id="2_portrait"]'
    else:
        line = f'[ext_resource type="Texture2D" path="res://assets/sprites/units/players/fullbody/{name}.png" id="2_portrait"]'
    text = text.replace("[resource]", line + "\n\n[resource]")
    text = re.sub(r"^(model_glb = .*)$", r'\1\nportrait = ExtResource("2_portrait")', text, flags=re.M)
    if 'portrait = ExtResource' not in text:
        text = text.replace('icon = ExtResource("1_avatar")', 'icon = ExtResource("1_avatar")\nportrait = ExtResource("2_portrait")')
    with open(tres, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    print("已绑定 portrait:", name)
