# 手持武器外观

行修使用 `assets/models/players/行修.glb`，右手骨骼下的 `WeaponSocket` 跟随动画。

木剑、精铁剑目前使用简单几何模型验证换装，后续可替换为正式 `.glb` 或 `.tscn`。

- 武器场景根节点为 `Node3D`，原点位于握柄中部，局部 `+Y` 指向剑尖；单位为米。
- 在武器的 `ItemEquipment` 资源中设置 `weapon_scene`。
- 用 `weapon_position`、`weapon_rotation_degrees`、`weapon_scale` 校准手中的位置。
- 未装备武器或 `weapon_scene` 留空时不显示手持模型。当前仅木剑、精铁剑配置了模型。
- 背包装备/卸下会更新地图上的队长与队友，战斗从原角色装备栏取得外观快照。
- 目前复用原模型自带动画；长枪、弓等不同握法需要另外制作对应动作。

验证：`Godot --headless --path . res://tools/check_xingxiu_3d.tscn`。
