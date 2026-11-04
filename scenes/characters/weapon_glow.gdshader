// 武器发光：外描边 + 呼吸脉动 + 流光扫过
// 用 CanvasItem 材质挂到 s_weapon 上，不需要 WorldEnvironment / HDR。
shader_type canvas_item;

// 光色（按品质设：白/蓝/紫/粉/橙）
uniform vec4 glow_color : source_color = vec4(1.0, 0.85, 0.4, 1.0);
// 强度：0 = 无光效，3 = 很亮（品质越高越大）
uniform float glow_strength : hint_range(0.0, 3.0) = 1.0;
// 描边宽度（相对贴图，0.004 ≈ 1px@256）
uniform float glow_width : hint_range(0.0, 0.05) = 0.012;
// 脉动速度，0 = 不闪
uniform float pulse_speed = 2.0;
// 流光速度：一道亮带沿刀身往上扫，0 = 不扫
uniform float sweep_speed : hint_range(0.0, 3.0) = 0.0;

void fragment() {
	vec4 col = texture(TEXTURE, UV);

	if (glow_strength <= 0.001 && sweep_speed <= 0.001) {
		COLOR = col;
	} else {
		// ── 外发光 ──
		float rim = 0.0;
		float rr = glow_width * (0.6 + 0.4 * glow_strength);
		if (glow_strength > 0.001) {
			for (int i = 0; i < 8; i++) {
				float a = float(i) * 0.7853982;
				vec2 off = vec2(cos(a), sin(a)) * rr;
				rim = max(rim, texture(TEXTURE, UV + off).a);
			}
		}
		float edge = clamp(rim - col.a, 0.0, 1.0);

		float pulse = 1.0;
		if (pulse_speed > 0.001) {
			pulse = 0.75 + 0.25 * sin(TIME * pulse_speed);
		}

		vec3 lit = col.rgb + glow_color.rgb * edge * glow_strength * pulse;

		// ── 流光：沿刀身（UV.y）自下而上扫过 ──
		// 只在「武器实体」上亮（乘 col.a），不会在空处出现横条
		if (sweep_speed > 0.001) {
			float sy = fract(UV.y - TIME * sweep_speed * 0.35);
			float band = smoothstep(0.10, 0.0, abs(sy - 0.55)) * col.a;
			// 带一点暖白，比光色更醒目
			lit += vec3(1.0, 0.96, 0.88) * band * (0.25 + 0.30 * glow_strength);
		}

		COLOR = vec4(lit, max(col.a, edge * 0.55 * glow_strength));
	}
}
