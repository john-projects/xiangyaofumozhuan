extends Node2D
## One-shot critical impact. Independent instances support simultaneous hits.
const DURATION := 0.85
var elapsed := 0.0

func _ready() -> void:
	z_index = 60
	scale = Vector2.ONE * 0.75

func _process(delta: float) -> void:
	elapsed += delta
	if elapsed >= DURATION:
		queue_free()
		return
	queue_redraw()

func _draw() -> void:
	# Three staggered waves, with a broad glow and a bright narrow rim.
	for layer in range(3):
		var age := elapsed - float(layer) * 0.065
		if age < 0.0 or age >= 0.52:
			continue
		var progress := age / 0.52
		var eased := 1.0 - pow(1.0 - progress, 3.0)
		var radius := lerpf(12.0, 205.0 - float(layer) * 29.0, eased)
		var fade := pow(1.0 - progress, 1.35)
		var outline := PackedVector2Array()
		for segment in range(129):
			var angle := float(segment) * TAU / 128.0
			# Fixed angular waves evolve smoothly; never randomize each frame.
			var ripple := sin(angle * 13.0 + float(layer) * 1.7 + progress * 2.0) * 0.045
			ripple += sin(angle * 29.0 - progress * 3.0) * 0.028
			ripple += sin(angle * 47.0 + float(layer)) * 0.018
			outline.append(Vector2.from_angle(angle) * radius * (1.0 + ripple))
		draw_polyline(outline, Color(1.0, 0.27, 0.025, fade * 0.24),
			68.0 * (1.0 - progress) + 6.0, true)
		draw_polyline(outline, Color(1.0, 0.65, 0.12, fade * 0.9),
			28.0 * (1.0 - progress) + 4.0, true)
		draw_polyline(outline, Color(1.0, 0.95, 0.67, fade * 0.9), 7.2, true)

	# Explicit bright embers with thick tails remain legible at game scale.
	# Their trajectories do not consume the combat random-number sequence.
	for i in range(36):
		var delay := float(i % 4) * 0.018
		var age := elapsed - delay
		if age < 0.0 or age > 0.72:
			continue
		var angle := float(i) * 2.399963 + sin(float(i) * 7.13) * 0.16
		var axis := Vector2.from_angle(angle)
		var speed := 240.0 + float((i * 73) % 230)
		var travel := 20.0 + speed * age * (1.0 - age * 0.35)
		var head := axis * travel + Vector2(0.0, 65.0 * age * age)
		var tail := head - axis * (16.0 + speed * 0.045)
		var fade := 1.0 - smoothstep(0.32, 0.72, age)
		var width := 5.0 + float(i % 3) * 1.5
		draw_line(tail, head, Color(1.0, 0.25, 0.025, fade * 0.35), width * 2.4, true)
		draw_line(tail, head, Color(1.0, 0.65, 0.12, fade), width, true)
		draw_line(head - axis * 8.0, head, Color(1.0, 0.98, 0.78, fade), width * 0.55, true)
		draw_circle(head, width * 0.55, Color(1.0, 0.9, 0.45, fade))

	# Radial tapered streaks provide an explosive silhouette.
	var burst := clampf(elapsed / 0.48, 0.0, 1.0)
	var burst_fade := pow(1.0 - burst, 1.6)
	if burst_fade > 0.0:
		for i in range(16):
			var angle := float(i) * TAU / 16.0 + 0.12
			var axis := Vector2.from_angle(angle)
			var side := axis.orthogonal()
			var inner := axis * lerpf(18.0, 145.0, burst)
			var outer := axis * lerpf(80.0 + float(i % 3) * 25.0, 225.0, burst)
			var width := (4.0 + float(i % 3)) * (1.0 - burst)
			draw_colored_polygon(PackedVector2Array([
				inner - side * width, outer, inner + side * width
			]), Color(1.0, 0.77, 0.28, burst_fade * 0.8))
	var flash := maxf(0.0, 1.0 - elapsed / 0.15)
	if flash > 0.0:
		for halo in range(5, 0, -1):
			draw_circle(Vector2.ZERO, float(halo) * 12.0 + elapsed * 70.0,
				Color(1.0, 0.63, 0.16, flash * 0.07))
		draw_circle(Vector2.ZERO, 10.0 + elapsed * 85.0,
			Color(1.0, 0.96, 0.75, flash * 0.85))