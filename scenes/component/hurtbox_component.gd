## HurtboxComponent —— 单位的"受击判定框"（挨打的那一侧）。
##
## ── 在系统里的位置 ──
##   伤害系统成对出现：HitboxComponent（打人）+ HurtboxComponent（挨打），两者都是 Area2D。
##   本组件是纯粹的"信号转发器"：它自己**不扣血**，血量在 HealthComponent 里，
##   被打的反应在 Unit._on_hurtbox_component_on_damaged() 里（白闪、格挡判定、扣血、飘伤害数字）。
##   这样拆的好处：一个单位只需要一个 Hurtbox，却能同时被近战 Hitbox 和投射物 Hitbox 打。
##
## ── 数据流 ──
##   攻击方的 HitboxComponent.area_entered
##     → 命中本 Hurtbox（靠 collision_layer / collision_mask 配对，见 project.godot 的 layer_names）
##       → 本节点 _on_area_entered() 判断类型 → emit on_damaged(hitbox)
##         → 场景里连到父节点 Unit._on_hurtbox_component_on_damaged(hitbox)
##           → hitbox.damage 扣 HealthComponent.current_health → Global.on_create_damage_text.emit()
##           → 敌人还会读 hitbox.knockback_power / hitbox.source 做击退
##
## ── 碰撞层约定（project.godot [layer_names]，值是 2^(层号-1) 的位掩码） ──
##   1=Player 2=Enemy 3=HitboxEnemy(4) 4=HurtboxEnemy(8) 5=HitboxPlayer(16) 6=HurtboxPlayer(32)
##   敌人单位的 Hurtbox：layer 8（HurtboxEnemy）+ mask 16（HitboxPlayer）→ 只认玩家攻击；
##   玩家的 Hurtbox：   layer 32（HurtboxPlayer）+ mask 4（HitboxEnemy）  → 只认敌人攻击。
##   所以 hitbox 能不能打中，取决于**场景里配的层位**，本脚本一行都不用改。
##   改层位后如果"打不掉血"，先来核对这里，而不是怀疑这个脚本。

extends Area2D
class_name HurtboxComponent

## 被打中时对外发的唯一信号，参数是"打中我的那个 Hitbox"。
## 为什么不直接传伤害数值？因为接收方（Unit / Enemy）还需要 critical、
## knockback_power、source 这些附加值（Enemy 用它算击退方向），所以整包传引用更灵活。
## ⚠ 连接写在场景文件里（unit.tscn 的 [connection signal="on_damaged" ...]），不是在代码里 connect；
##   把 HurtboxComponent 从场景里删掉或改名，这条连接就断了，表现为"完全不掉血且没有任何报错"。
signal on_damaged(hitbox: HitboxComponent)


## Area2D 的 area_entered 回调：有别的 Area2D 进入我的范围时触发。
## 参数 area：进入的 Area2D。它的实际类型可能是任何 Area2D（视碰撞层配对而定），
##   所以要 is 判断，只认 Hurtbox 协议的对家。
## 返回值：无。
## 副作用：命中合法 Hitbox 时 **emit on_damaged(hitbox)** —— 这会在物理步进的回调途中
##   同步执行接收方的扣血、飘字、甚至死亡（进而 queue_free / 掉落金币）；
##   所以接收方那边任何"改碰撞状态"的操作都必须用 set_deferred 延后，否则 Godot 会报
##   "Can't change this state while flushing queries"。
## ⚠ 本函数不改自身 collision、不 queue_free、不写 Global、不播声音（音效在 Hitbox 侧播，
##   见 hitbox_component.gd —— 谁主动谁出声，避免一次命中出两声）。
## ⚠ 同一物理帧内多个 Hitbox 进入时本函数会被调多次：扣血会逐次累加（Unit 侧只判断
##   current_health <= 0 时提前 return），所以单帧多次命中是"多段伤害"而不是"免疫"。
## ⚠ area_entered 的信号连接同样写在 hurtbox_component.tscn 里（to="." method="_on_area_entered"），
##   而 HurtboxComponent 默认 monitoring/monitorable 取决于各场景的层位配置，删了连接就彻底哑掉。
func _on_area_entered(area: Area2D) -> void:
	if area is HitboxComponent:
		on_damaged.emit(area)
