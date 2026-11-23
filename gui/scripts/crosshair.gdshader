shader_type canvas_item;

// Samples the screen as it exists before this overlay is drawn, so the
// inverted crosshair matches the pixel directly behind it (Minecraft-style).
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform int style = 2;
uniform vec4 cross_color : source_color = vec4(1.0, 1.0, 1.0, 0.9);
uniform float cross_size = 10.0;
uniform float thickness = 2.0;
uniform float gap = 3.0;
uniform bool inverted = false;

float sd_segment(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a;
	vec2 ba = b - a;
	float h = clamp(dot(pa, ba) / max(dot(ba, ba), 0.0001), 0.0, 1.0);
	return length(pa - ba * h);
}

float circle_fill(float dist, float radius, float aa) {
	return 1.0 - smoothstep(radius - aa, radius + aa, dist);
}

void fragment() {
	if (style == 0) {
		discard;
	}

	// Work in screen pixels so size/gap/thickness stay consistent at any
	// resolution or window scale.
	vec2 pixel_size = max(SCREEN_PIXEL_SIZE, vec2(0.000001));
	vec2 p = SCREEN_UV / pixel_size - 0.5 / pixel_size;

	float aa = 1.0;
	float half_width = max(0.5, thickness * 0.5);
	float shape = 0.0;

	if (style == 1) {
		// Dot.
		shape = circle_fill(length(p), max(1.0, cross_size * 0.15), aa);
	} else if (style == 2 || style == 4) {
		// Cross (style 2 has a center gap, style 4 starts at the center).
		float g = 0.0;
		if (style == 2) {
			g = gap;
		}
		float reach = g + max(1.0, cross_size);
		float d = min(
			min(
				sd_segment(p, vec2(g, 0.0), vec2(reach, 0.0)),
				sd_segment(p, vec2(-g, 0.0), vec2(-reach, 0.0))
			),
			min(
				sd_segment(p, vec2(0.0, g), vec2(0.0, reach)),
				sd_segment(p, vec2(0.0, -g), vec2(0.0, -reach))
			)
		);
		shape = 1.0 - smoothstep(half_width - aa, half_width + aa, d);
	} else if (style == 3) {
		// Ring.
		float radius = max(2.0, cross_size * 0.5);
		shape = 1.0 - smoothstep(half_width - aa, half_width + aa, abs(length(p) - radius));
	}

	if (shape <= 0.001) {
		discard;
	}

	vec3 color = cross_color.rgb;
	float alpha = clamp(cross_color.a, 0.0, 1.0);
	if (inverted) {
		vec3 behind = texture(screen_tex, SCREEN_UV).rgb;
		color = vec3(1.0) - behind;
		alpha = 1.0;
	}

	COLOR = vec4(color, alpha * shape);
}
