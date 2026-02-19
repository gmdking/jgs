shader_type spatial;
render_mode unshaded;

uniform sampler2D portal_texture;

void fragment() {
    vec2 uv = UV;
    ALBEDO = texture(portal_texture, uv).rgb;
}
