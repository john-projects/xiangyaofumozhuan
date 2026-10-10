extends HBoxContainer
class_name CoinsBag

@onready var coins: Label = $Coins


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	coins.text = str(Global.coins)
