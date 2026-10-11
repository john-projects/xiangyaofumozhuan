## ═══════════════════════════════════════════════════════════════════════════
## UpgradeCard —— 波次结算"四选一"里的一张升级卡
## ═══════════════════════════════════════════════════════════════════════════
## 系统位置：
##   升级面板 UpgradePanel 的条目（upgrade_panel.tscn 里预制了 4 张，运行时会先被清掉再重建）。
##   整条流程：Spawner 的波次计时结束 → Arena._on_spawner_on_wave_completed()
##     → await 1.5 秒 → Arena.show_upgrades() → UpgradePanel.load_upgrade(当前波数)
##     → Global.select_items_for_offer() 抽 4 个 ItemUpgrade → 每张卡设 item_data
##   → 玩家点一张卡的 CustomButton → 本文件的 _on_custom_button_pressed()
##     → ItemUpgrade.apply_upgrade() 真正加属性 → emit Global.on_upgrade_selected
##     → Arena._on_upgrade_selected() 收起升级面板、打开商店面板。
##
## 数据流：
##   ItemUpgrade（.tres 资源）→ _set_data() 填 %Icon / %Name / %Description + 稀有度描边
##   玩家点击 → 改 Global.player.stats（**就地修改共享 Resource，永久生效**）→ 广播信号
##
## 坑：
##   · %Description 是普通 **Label**（不是 RichTextLabel），所以 item_data.description
##     必须是纯文本；ItemBase.get_description() 那套 BBCode 在这里会被原样显示成标签文本。
##   · 选完卡之后本卡**不会被释放**：Arena 只是 upgrade_panel.hide()，
##     直到下一次 UpgradePanel.load_upgrade() 才把这些子节点 queue_free 掉。
##     所以卡片在隐藏期间仍然存在（但不可见、不可点）。
##   · _set_data() 没有判空；而 UpgradePanel 的写法是"先 add_child 再赋值"，
##     因为 setter 里用了 %Icon 等 @onready 变量，没入树就是 null。
extends Panel
class_name UpgradeCard

## 本卡代表的升级数据。变量名特意叫 item_data 而不是 item ——
## 避免和 UpgradePanel 里 `for random_upg: ItemUpgrade` 之类的局部名混淆，
## 也提示"这是数据（ItemUpgrade），不是节点"。
@export var item_data: ItemUpgrade: set = _set_data


## 三个 % 节点都是 unique_name_in_owner（upgrade_card.tscn 里勾了唯一名）。
## %Icon 是 TextureRect、%Name 与 %Description 都是 Label。
@onready var item_icon: TextureRect = %Icon
@onready var item_name: Label = %Name
@onready var item_description: Label = %Description

## item_data 的 setter：把升级数据灌进卡片。
## 参数 value：要展示的 ItemUpgrade（null 会崩，没有判空）。
## 返回值：无。
## 副作用：
##   · 写三个子控件；add_theme_stylebox_override("panel", ...) 按稀有度换本 Panel 的描边
##     （Global.get_tier_style 返回共享 const 资源，只挂不改）；
##   · 不 emit 信号、不改 Global —— "生效"是点击时才发生的事，见 _on_custom_button_pressed()。
## 时序：由 UpgradePanel.load_upgrade() 在 add_child() **之后**调用，保证 @onready 已有值。
func _set_data(value: ItemUpgrade) -> void:
	item_data = value
	item_icon.texture = item_data.item_icon
	item_name.text = item_data.item_name
	item_description.text = item_data.description
	
	var style := Global.get_tier_style(item_data.item_tier)
	add_theme_stylebox_override("panel", style)


## 点"选它"按钮的回调（upgrade_card.tscn 里编辑器把 CustomButton.pressed 连到这里）。
## 参数：无。返回值：无。
## 副作用（三个，顺序有意义）：
##   1) item_data.apply_upgrade()：**就地修改 Global.player.stats**（共享的 Resource），
##      属性永久增加、没有回滚。这是本卡唯一的玩法副作用；
##   2) 播一次 UI 音效；
##   3) emit Global.on_upgrade_selected（无参信号，挂在 autoload 上，比场景活得久）——
##      Arena 订阅了它，收到后 hide() 升级面板并 load_shop() + show() 商店面板。
## 为什么先 apply 后 emit：保证面板切换时数值已经是新的（StatsContainer 每帧重读，无所谓，
##   但语义上更清楚）。
## 双保险条件：`if item_data and is_instance_valid(Global.player)` ——
##   · item_data 为空说明卡片没被正确赋值，点了什么也不该发生；
##   · Global.player 是跨场景引用，理论上可能已被释放，直接访问会崩。
##   ⚠ 这两个条件都不满足时会**静默什么都不做**（连音效都不响），排查时先看这两个前提。
## 提示：本函数不会销毁卡片，也不会隐藏面板 —— 那是 Arena 收到信号后做的事。
func _on_custom_button_pressed() -> void:
	if item_data and is_instance_valid(Global.player):
		item_data.apply_upgrade()
		SoundManager.play_sound(SoundManager.Sound.UI)
		Global.on_upgrade_selected.emit()
