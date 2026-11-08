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
// 品质染色（加色）：0 = 不染，0.3 = 整把武器透出明显的光色
uniform float tint_amount : hint_range(0.0, 1.0) = 0.0;
// 流光亮度（1.5 = 明显的一道亮带）
uniform float sweep_strength : hint_range(0.0, 4.0) = 1.0;

// 扇、爪按手持图的局部坐标布光，动画图集切帧时坐标也保持稳定。
uniform int style_mode = 0; // 0 通用，1 扇，2 爪
uniform vec2 style_origin = vec2(0.0);
uniform vec2 style_size = vec2(1.0);
uniform float style_phase = 0.0;
uniform float style_clock = 0.0;
uniform vec4 style_color : source_color = vec4(1.0);
uniform vec3 fan_axis = vec3(0.5, 0.7, 0.4);
uniform vec4 claw_path_0;
uniform vec4 claw_path_1;
uniform vec4 claw_path_2;
varying vec2 style_uv;

void vertex() {
	style_uv = (VERTEX - style_origin) / max(style_size, vec2(1.0));
}

float point_light(vec2 position, vec2 center, float size) {
	vec2 distance = abs(position - center) / size;
	float core = 1.0 - smoothstep(0.0, 1.0, length(distance));
	float rays = (1.0 - smoothstep(0.0, 2.2, max(distance.x, distance.y)))
		* (1.0 - smoothstep(0.0, 0.22, min(distance.x, distance.y)));
	return max(core, rays * 0.55);
}

// 返回扇面高光与扇沿点光。大部分时间留给武器原画。
vec2 fan_light(float elapsed) {
	vec2 rel = (style_uv - fan_axis.xy) / max(fan_axis.z, 0.02);
	float radius = length(rel);
	float active = smoothstep(0.0, 0.10, elapsed) * (1.0 - smoothstep(0.93, 1.38, elapsed));
	float front = clamp(elapsed / 1.12, 0.0, 1.0);
	float wave_distance = abs(radius - front);
	float wave = 0.60 * (1.0 - smoothstep(0.0, 0.19, wave_distance))
		+ 0.40 * (1.0 - smoothstep(0.0, 0.046, wave_distance));
	float sector = smoothstep(0.02, 0.22, -rel.y);
	float angle = atan(rel.y, rel.x + 0.00001);
	float ribs = 0.6 + 0.4 * pow(0.5 + 0.5 * cos(angle * 20.0), 2.0);
	float surface = wave * active * sector * ribs;
	float rim = (1.0 - smoothstep(0.0, 0.11, abs(radius - 0.97)))
		* smoothstep(0.78, 1.06, elapsed) * (1.0 - smoothstep(1.13, 1.48, elapsed));
	float sparks = 0.0;
	for (int i = 0; i < 3; i++) {
		float life = elapsed - 1.01 - float(i) * 0.08;
		float direction = -2.38 + float(i) * 0.72;
		vec2 ray = vec2(cos(direction), sin(direction));
		vec2 center = fan_axis.xy + ray * fan_axis.z * (0.94 + life * 0.26);
		float fade = smoothstep(0.0, 0.08, life) * (1.0 - smoothstep(0.10, 0.46, life));
		sparks = max(sparks, point_light(style_uv, center, 0.010) * fade);
	}
	return vec2(surface + rim * sector * 0.36, sparks);
}

vec2 claw_light(vec4 path, float elapsed, float lane) {
	float life = elapsed - lane * 0.065;
	float progress = clamp(life / 0.38, 0.0, 1.0);
	vec2 axis = path.zw - path.xy;
	// 弯刃的中段向外拱，亮点从指节向尖端滑过去。
	vec2 bow = vec2(axis.y, -axis.x) * 0.31;
	vec2 center = mix(path.xy, path.zw, progress) + bow * (4.0 * progress * (1.0 - progress));
	vec2 tangent = normalize(axis + bow * (4.0 - 8.0 * progress));
	vec2 delta = style_uv - center;
	float along = dot(delta, tangent);
	float across = dot(delta, vec2(-tangent.y, tangent.x));
	float lengthwise = 1.0 - smoothstep(0.0, 0.066, abs(along));
	float crosswise = 1.0 - smoothstep(0.003, 0.026, abs(across));
	float fade = smoothstep(0.0, 0.055, life) * (1.0 - smoothstep(0.30, 0.42, life));
	float spark_life = life - 0.34;
	vec2 spark_pos = path.zw + vec2(-0.035, 0.045) * spark_life;
	float spark_fade = smoothstep(0.0, 0.035, spark_life) * (1.0 - smoothstep(0.075, 0.27, spark_life));
	return vec2(lengthwise * crosswise * fade, point_light(style_uv, spark_pos, 0.011) * spark_fade);
}

void fragment() {
	vec4 col = texture(TEXTURE, UV);

	if (style_mode == 0 && glow_strength <= 0.001 && sweep_speed <= 0.001) {
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

		// ── 品质染色：加色而不是乘色，避免把原画压暗 ──
		if (tint_amount > 0.001) {
			lit += glow_color.rgb * tint_amount * col.a;
		}

		// ── 流光：沿刀身（UV.y）自下而上扫过 ──
		// 只在「武器实体」上亮（乘 col.a），不会在空处出现横条
		if (style_mode == 0 && sweep_speed > 0.001) {
			// Frame-local coordinates keep the sweep continuous across atlas frames.
			float sy = fract(style_uv.y - TIME * sweep_speed * 0.35);
			float band = smoothstep(0.10, 0.0, abs(sy - 0.55)) * col.a;
			// 带一点暖白，比光色更醒目
			// 流光用品质色（提亮 35% 让它比光晕更醒目），不再是固定的暖白
			vec3 sweep_col = mix(glow_color.rgb, vec3(1.0), 0.18);   // 品质色 + 一点白
			// ⚠ 用 mix 而不是加法：加法会让主通道冲到 1.0，橙/粉就变白了
			float b = clamp(band * sweep_strength, 0.0, 1.0);
			lit = mix(lit, sweep_col, b * 0.85);
		}

		float alpha = max(col.a, edge * 0.55 * glow_strength);
		if (style_mode != 0) {
			vec2 light = vec2(0.0);
			if (style_mode == 1) {
				float elapsed = mod(style_clock + 0.12, 2.4);
				if (elapsed < 1.6) {
					light = fan_light(elapsed) * vec2(0.82, 0.88);
				}
			} else {
				float clock = (style_clock + 0.045) / 1.6;
				float elapsed = fract(clock) * 1.6;
				if (elapsed < 0.76) {
					// 每轮换一条可能略过的刃口，形成两到三条错峰闪光。
					float cycle = floor(clock);
					float pattern = floor(fract(sin(cycle * 93.13 + style_phase * 43.2) * 43758.5453) * 4.0);
					if (pattern != 0.0) {
						light = claw_light(claw_path_0, elapsed, 0.0);
					}
					if (pattern != 1.0) {
						light = max(light, claw_light(claw_path_1, elapsed, 1.0));
					}
					if (pattern != 2.0) {
						light = max(light, claw_light(claw_path_2, elapsed, 2.0));
					}
				}
			}
			// 有颜色的亮纹在冰白扇面和浅色金属上也能看清。
			vec3 highlight = mix(style_color.rgb, vec3(1.0), style_mode == 1 ? 0.12 : 0.52);
			float sweep = clamp(light.x * col.a, 0.0, 1.0);
			lit = mix(lit, highlight, sweep * 0.73) + sweep * 0.13;
			lit = mix(lit, mix(style_color.rgb, vec3(1.0), 0.66), light.y);
			alpha = max(alpha, light.y);
		}
		COLOR = vec4(lit, alpha);
	}
}
