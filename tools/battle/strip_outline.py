# -*- coding: utf-8 -*-
"""把"描边高亮"换成"脚下光环"，并让行动者轻微呼吸。

改动范围：
1. battle_unit.tscn：删掉 Outline 节点 + 轮廓 shader 两个 sub_resource；
2. battle_unit.gd：删掉 set_outline/_refresh_outline 与 OUTLINE_* 常量，
   改成代码生成的椭圆光环（两圈 Line2D：内圈实、外圈柔光），带呼吸脉动。
"""

import os
import re

ROOT = r"E:\dream\godot\xiangyaofumozhuan"

# ── 1. 场景：去掉 Outline 节点与 shader ──
tscn = os.path.join(ROOT, "scenes", "battle", "battle_unit.tscn")
text = open(tscn, encoding="utf-8").read()

# 删 Outline 节点块
text = re.sub(
    r'\n\[node name="Outline" type="Sprite2D" parent="Sprite"\]\n(?:[^\[\n][^\n]*\n)*',
    "\n", text)
# 删两个 shader sub_resource 块
text = re.sub(r'\[sub_resource type="Shader" id="Shader_outline"\]\n(?:.*\n)*?\n', "", text, count=1)
text = re.sub(r'\[sub_resource type="ShaderMaterial" id="ShaderMaterial_outline"\]\n(?:.*\n)*?\n', "", text, count=1)
# load_steps 从 6 → 4（script + health_bar + CircleShape2D + 本身）
text = text.replace("[gd_scene load_steps=6 format=3]", "[gd_scene load_steps=4 format=3]")
open(tscn, "w", encoding="utf-8", newline="\n").write(text)
print("场景已去掉 Outline:", "Outline" in text)

# ── 2. 脚本：删描边相关 ──
gd = os.path.join(ROOT, "scenes", "battle", "battle_unit.gd")
code = open(gd, encoding="utf-8").read()

# 删 OUTLINE_* 常量块
code = re.sub(
    r'# ── 轮廓配色 ──\n(?:.*\n)*?const OUTLINE_TARGET_COLOR[^\n]*\n',
    "", code, count=1)

# 删 @onready var outline 与 set_outline / _refresh_outline 两个函数
code = code.replace('@onready var outline: Sprite2D = %Outline\n', "")
code = re.sub(
    r'## 底层接口：直接开关轮廓并指定颜色.*?\nfunc set_outline\(active: bool, color: Color\) -> void:\n(?:.*\n)*?\toutline\.visible = show_it\n\n\n',
    "", code, count=1, flags=re.S)
code = re.sub(
    r'## 轮廓的唯一真相出口：.*?\nfunc _refresh_outline\(\) -> void:\n(?:.*\n)*?\t\tset_outline\(false, Color\.WHITE\)\n',
    "", code, count=1, flags=re.S)

# 调用点：_refresh_outline() → _update_selection()
code = code.replace("\t_update_selection()\n\t_refresh_outline()\n", "\t_update_selection()\n")
code = code.replace("\t_update_selection()\n\n\n## 设置\"可被选为目标\"红圈", "\t_update_selection()\n\n\n## 设置\"可被选为目标\"红圈")

open(gd, "w", encoding="utf-8", newline="\n").write(code)
print("脚本残留 outline 引用:", code.count("outline"))
