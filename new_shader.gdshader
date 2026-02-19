shader_type spatial;

uniform sampler2D portal_texture;

void fragment() {
    vec2 uv = UV;
    ALBEDO = texture(portal_texture, uv).rgb;
}
