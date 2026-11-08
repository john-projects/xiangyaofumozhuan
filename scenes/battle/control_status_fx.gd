extends Node2D
## Plays the entry, sustained loop and release of a control status atlas.

const SEAL_SHEET := preload("res://assets/sprites/skills/status_taixu_seal_v2.png")
const SILENCE_SHEET := preload("res://assets/sprites/skills/status_fengling_lock_v2.png")
const FPS := 16.0
const ENTRY_FRAMES := 4
const LOOP_FRAMES := 8
const RELEASE_FRAMES := 4
const GRID := 4
const SEAL_FRONT_START := 0.43
const SEAL_GROUND_START := 0.735

var is_seal := false
var body_height := 210.0
var status_active: Callable
var unit_alive: Callable

var _age := 0.0
var _release_age := -1.0
var _frame := -1
var _cell: Vector2
var _top_left: Vector2
var _atlas_scale: float
var _slices: Array[Sprite2D] = []
var _ranges: Array[Vector2] = []


func _ready() -> void:
	var sheet := SEAL_SHEET if is_seal else SILENCE_SHEET
	_cell = sheet.get_size() / float(GRID)
	var width := body_height * (0.90 if is_seal else 0.84)
	_atlas_scale = width / _cell.x
	var foot_anchor := Vector2(0.5, 0.81)
	if is_seal:
		# The far arcs and ground seal sort behind the portrait. The near
		# arcs share the same atlas, frame and transform above the portrait.
		_top_left = -foot_anchor * _cell * _atlas_scale
		_add_slice(sheet, 0.0, SEAL_FRONT_START, 0)
		_add_slice(sheet, SEAL_FRONT_START, SEAL_GROUND_START, 1)
		_add_slice(sheet, SEAL_GROUND_START, 1.0, 0)
	else:
		_top_left = Vector2(0.0, -body_height * 0.49) - _cell * _atlas_scale * 0.5
		_add_slice(sheet, 0.0, 1.0, 1)
	_show_frame(0)


func _process(delta: float) -> void:
	if not unit_alive.call():
		hide()
		queue_free()
		return
	if status_active.call():
		if _release_age >= 0.0:
			_age = 0.0
			_release_age = -1.0
		var step := floori(_age * FPS)
		_show_frame(step if step < ENTRY_FRAMES else ENTRY_FRAMES + (step - ENTRY_FRAMES) % LOOP_FRAMES)
		_age += delta
	else:
		var release_frame := floori(maxf(_release_age, 0.0) * FPS)
		if release_frame >= RELEASE_FRAMES:
			queue_free()
			return
		_show_frame(ENTRY_FRAMES + LOOP_FRAMES + release_frame)
		_release_age = maxf(_release_age, 0.0) + delta


func _add_slice(sheet: Texture2D, from: float, to: float, layer: int) -> void:
	var sprite := Sprite2D.new()
	sprite.texture = sheet
	sprite.centered = false
	sprite.region_enabled = true
	sprite.region_filter_clip_enabled = true
	sprite.scale = Vector2.ONE * _atlas_scale
	sprite.position = _top_left + Vector2(0.0, from * _cell.y * _atlas_scale)
	if is_seal and from < SEAL_GROUND_START:
		sprite.position.y -= body_height * 0.09
	sprite.z_index = layer
	add_child(sprite)
	_slices.append(sprite)
	_ranges.append(Vector2(from, to))


func _show_frame(frame: int) -> void:
	if _frame == frame:
		return
	_frame = frame
	var origin := Vector2(frame % GRID, floori(float(frame) / GRID)) * _cell
	for i in range(_slices.size()):
		var span := _ranges[i]
		_slices[i].region_rect = Rect2(origin + Vector2(0.0, span.x * _cell.y),
			Vector2(_cell.x, (span.y - span.x) * _cell.y))
