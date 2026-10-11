## ═══════════════════════════════════════════════════════════════════════════
## SelectionCard —— 选人界面里的一张"图卡"（角色头像 / 初始武器图标）
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   选人面板（SelectionPanel）用 Global.SELECTION_CARD_SCENE 批量实例化它两排：
##     上一排 %PlayerContainer（角色，5 个）、下一排 %WeaponContainer（初始武器，12 个）。
##   注意 .tscn 里那些容器本来就摆好了一堆 SelectionCard 节点（为了让编辑器里能看到版式），
##   SelectionPanel._ready() 会先把它们全部 queue_free() 再重新生成 —— 所以编辑器里看到的
##   都是占位预览，真正显示的是运行时创建的那些（它们的 owner 是 null，见 SelectionPanel 注释）。
##
## 数据流：
##   角色/武器资源（UnitStats / ItemWeapon）→ 调用方把它的 icon 交给本卡
##     · 角色走 set_icon(player.icon)
##     · 武器直接写 card.icon = weapon.item_icon
##   → 点击 → Button.pressed → SelectionPanel 里用 bind 接的回调（_on_player_selected /
##     _on_weapon_selected）把选中的资源写进 Global.main_player_selected / main_weapon_selected
##   → 悬停 → Button.mouse_entered → TooltipManager 弹提示卡
##
## 本文件很薄：只做"显示图标 + 放音效"，不知道也管不着选中的是谁 —— 选中逻辑全在 SelectionPanel。
##
## 坑：
##   · 根节点是 **Button**，所以按钮上显示的图片用的是 Button 自带的 `icon` 属性
##     （配合场景里配好的 icon_alignment / expand_icon 决定怎么缩放对齐），
##     不是 TextureRect —— 所以没有单独的图标节点可以取。
##   · .tscn 已把 pressed / mouse_entered 自连到本脚本的两个回调（放音效），
##     而 SelectionPanel 又用代码给同一个 pressed 信号加了一个订阅者（业务回调）。
##     也就是说按一下会**同时**触发两条连接 —— 这是刻意的，别以为是重复连接 bug。
##   · 本类不缓存任何数据：卡片被 queue_free 掉也不影响选中结果，因为结果已经写进 Global。
extends Button
class_name SelectionCard

## 设置按钮上显示的图标（转调 Button.icon）。
## 参数 texture：图标贴图；传 null 会让按钮变成空的（不报错，也不会清掉已选中的状态）。
## 返回值：无。
## 副作用：只改本按钮的 icon 属性，不 emit 信号、不碰 Global。
## 为什么要有这个包装：SelectionPanel 处理角色时用它，而处理武器时是直接写 `card.icon = ...` 的
##   —— 两条路径效果完全一样，只是历史写法不统一；想统一的话去掉本函数、两处都直接赋值即可。
func set_icon(texture: Texture2D) -> void:
	icon = texture


## 点击回调（.tscn 编辑器自连的 Button.pressed）。只负责放音效。
## 参数的"业务意义"（点了谁）不在本函数里 —— 它是 SelectionPanel 用 bind 接的另一条连接。
## 副作用：播一次 UI 音效；不 emit 任何信号。
func _on_pressed() -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)

## 鼠标进入回调（.tscn 编辑器自连的 Button.mouse_entered）。只负责放音效。
## 副作用：播一次 UI 音效（划过一排卡片会连着响，这是当前的预期效果，没有做节流）。
## 顺带说明：TooltipManager 的提示卡是挂在另一个订阅者（SelectionPanel 用代码连的
##   TooltipManager.show_for_control）上的，和本函数无关。
func _on_mouse_entered() -> void:
	SoundManager.play_sound(SoundManager.Sound.UI)
	
