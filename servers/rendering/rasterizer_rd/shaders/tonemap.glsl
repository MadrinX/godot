/* clang-format off */
[vertex]

#version 450

VERSION_DEFINES

layout(location = 0) out vec2 uv_interp;
/* clang-format on */

void main() {

	vec2 base_arr[4] = vec2[](vec2(0.0, 0.0), vec2(0.0, 1.0), vec2(1.0, 1.0), vec2(1.0, 0.0));
	uv_interp = base_arr[gl_VertexIndex];
	gl_Position = vec4(uv_interp * 2.0 - 1.0, 0.0, 1.0);
}

/* clang-format off */
[fragment]

#version 450

VERSION_DEFINES

layout(location = 0) in vec2 uv_interp;
/* clang-format on */

layout(set = 0, binding = 0) uniform sampler2D source_color;
layout(set = 1, binding = 0) uniform sampler2D source_auto_exposure;
layout(set = 2, binding = 0) uniform sampler2D source_glow;
layout(set = 3, binding = 0) uniform sampler3D color_correction;

layout(push_constant, binding = 1, std430) uniform Params {
	vec3 bcs;
	bool use_bcs;

	bool use_glow;
	bool use_auto_exposure;
	bool use_color_correction;
	uint tonemapper;

	uvec2 glow_texture_size;

	float glow_intensity;
	uint glow_level_flags;
	uint glow_mode;

	float exposure;
	float white;
	float auto_exposure_grey;
}
params;

layout(location = 0) out vec4 frag_color;

#ifdef USE_GLOW_FILTER_BICUBIC
// w0, w1, w2, and w3 are the four cubic B-spline basis functions
float w0(float a) {
	return (1.0f / 6.0f) * (a * (a * (-a + 3.0f) - 3.0f) + 1.0f);
}

float w1(float a) {
	return (1.0f / 6.0f) * (a * a * (3.0f * a - 6.0f) + 4.0f);
}

float w2(float a) {
	return (1.0f / 6.0f) * (a * (a * (-3.0f * a + 3.0f) + 3.0f) + 1.0f);
}

float w3(float a) {
	return (1.0f / 6.0f) * (a * a * a);
}

// g0 and g1 are the two amplitude functions
float g0(float a) {
	return w0(a) + w1(a);
}

float g1(float a) {
	return w2(a) + w3(a);
}

// h0 and h1 are the two offset functions
float h0(float a) {
	return -1.0f + w1(a) / (w0(a) + w1(a));
}

float h1(float a) {
	return 1.0f + w3(a) / (w2(a) + w3(a));
}

vec4 texture2D_bicubic(sampler2D tex, vec2 uv, int p_lod) {
	float lod = float(p_lod);
	vec2 tex_size = vec2(params.glow_texture_size >> p_lod);
	vec2 pixel_size = vec2(1.0f) / tex_size;

	uv = uv * tex_size + vec2(0.5f);

	vec2 iuv = floor(uv);
	vec2 fuv = fract(uv);

	float g0x = g0(fuv.x);
	float g1x = g1(fuv.x);
	float h0x = h0(fuv.x);
	float h1x = h1(fuv.x);
	float h0y = h0(fuv.y);
	float h1y = h1(fuv.y);

	vec2 p0 = (vec2(iuv.x + h0x, iuv.y + h0y) - vec2(0.5f)) * pixel_size;
	vec2 p1 = (vec2(iuv.x + h1x, iuv.y + h0y) - vec2(0.5f)) * pixel_size;
	vec2 p2 = (vec2(iuv.x + h0x, iuv.y + h1y) - vec2(0.5f)) * pixel_size;
	vec2 p3 = (vec2(iuv.x + h1x, iuv.y + h1y) - vec2(0.5f)) * pixel_size;

	return (g0(fuv.y) * (g0x * textureLod(tex, p0, lod) + g1x * textureLod(tex, p1, lod))) +
		   (g1(fuv.y) * (g0x * textureLod(tex, p2, lod) + g1x * textureLod(tex, p3, lod)));
}

#define GLOW_TEXTURE_SAMPLE(m_tex, m_uv, m_lod) texture2D_bicubic(m_tex, m_uv, m_lod)

#else

#define GLOW_TEXTURE_SAMPLE(m_tex, m_uv, m_lod) textureLod(m_tex, m_uv, float(m_lod))

#endif

vec3 tonemap_filmic(vec3 color, float white) {
	// exposure bias: input scale (color *= bias, white *= bias) to make the brightness consistent with other tonemappers
	// also useful to scale the input to the range that the tonemapper is designed for (some require very high input values)
	// has no effect on the curve's general shape or visual properties
	const float exposure_bias = 2.0f;
	const float A = 0.22f * exposure_bias * exposure_bias; // bias baked into constants for performance
	const float B = 0.30f * exposure_bias;
	const float C = 0.10f;
	const float D = 0.20f;
	const float E = 0.01f;
	const float F = 0.30f;

	vec3 color_tonemapped = ((color * (A * color + C * B) + D * E) / (color * (A * color + B) + D * F)) - E / F;
	float white_tonemapped = ((white * (A * white + C * B) + D * E) / (white * (A * white + B) + D * F)) - E / F;

	return color_tonemapped / white_tonemapped;
}

vec3 tonemap_aces(vec3 color, float white) {
	const float exposure_bias = 0.85f;
	const float A = 2.51f * exposure_bias * exposure_bias;
	const float B = 0.03f * exposure_bias;
	const float C = 2.43f * exposure_bias * exposure_bias;
	const float D = 0.59f * exposure_bias;
	const float E = 0.14f;

	vec3 color_tonemapped = (color * (A * color + B)) / (color * (C * color + D) + E);
	float white_tonemapped = (white * (A * white + B)) / (white * (C * white + D) + E);

	return color_tonemapped / white_tonemapped;
}

vec3 tonemap_reinhard(vec3 color, float white) {
	return (white * color + color) / (color * white + white);
}

vec3 linear_to_srgb(vec3 color) {
	//if going to srgb, clamp from 0 to 1.
	color = clamp(color, vec3(0.0), vec3(1.0));
	const vec3 a = vec3(0.055f);
	return mix((vec3(1.0f) + a) * pow(color.rgb, vec3(1.0f / 2.4f)) - a, 12.92f * color.rgb, lessThan(color.rgb, vec3(0.0031308f)));
}

#define TONEMAPPER_LINEAR 0
#define TONEMAPPER_REINHARD 1
#define TONEMAPPER_FILMIC 2
#define TONEMAPPER_ACES 3

vec3 apply_tonemapping(vec3 color, float white) { // inputs are LINEAR, always outputs clamped [0;1] color

	if (params.tonemapper == TONEMAPPER_LINEAR) {
		return color;
	} else if (params.tonemapper == TONEMAPPER_REINHARD) {
		return tonemap_reinhard(color, white);
	} else if (params.tonemapper == TONEMAPPER_FILMIC) {
		return tonemap_filmic(color, white);
	} else { //aces
		return tonemap_aces(color, white);
	}
}

vec3 gather_glow(sampler2D tex, vec2 uv) { // sample all selected glow levels
	vec3 glow = vec3(0.0f);

	if (bool(params.glow_level_flags & (1 << 0))) {
		glow += GLOW_TEXTURE_SAMPLE(tex, uv, 0).rgb;
	}

	if (bool(params.glow_level_flags & (1 << 1))) {
		glow += GLOW_TEXTURE_SAMPLE(tex, uv, 1).rgb;
	}

	if (bool(params.glow_level_flags & (1 << 2))) {
		glow += GLOW_TEXTURE_SAMPLE(tex, uv, 2).rgb;
	}

	if (bool(params.glow_level_flags & (1 << 3))) {
		glow += GLOW_TEXTURE_SAMPLE(tex, uv, 3).rgb;
	}

	if (bool(params.glow_level_flags & (1 << 4))) {
		glow += GLOW_TEXTURE_SAMPLE(tex, uv, 4).rgb;
	}

	if (bool(params.glow_level_flags & (1 << 5))) {
		glow += GLOW_TEXTURE_SAMPLE(tex, uv, 5).rgb;
	}

	if (bool(params.glow_level_flags & (1 << 6))) {
		glow += GLOW_TEXTURE_SAMPLE(tex, uv, 6).rgb;
	}

	return glow;
}

#define GLOW_MODE_ADD 0
#define GLOW_MODE_SCREEN 1
#define GLOW_MODE_SOFTLIGHT 2
#define GLOW_MODE_REPLACE 3
#define GLOW_MODE_MIX 4

vec3 apply_glow(vec3 color, vec3 glow) { // apply glow using the selected blending mode
	if (params.glow_mode == GLOW_MODE_ADD) {
		return color + glow;
	} else if (params.glow_mode == GLOW_MODE_SCREEN) {
		//need color clamping
		return max((color + glow) - (color * glow), vec3(0.0));
	} else if (params.glow_mode == GLOW_MODE_SOFTLIGHT) {
		//need color clamping
		glow = glow * vec3(0.5f) + vec3(0.5f);

		color.r = (glow.r <= 0.5f) ? (color.r - (1.0f - 2.0f * glow.r) * color.r * (1.0f - color.r)) : (((glow.r > 0.5f) && (color.r <= 0.25f)) ? (color.r + (2.0f * glow.r - 1.0f) * (4.0f * color.r * (4.0f * color.r + 1.0f) * (color.r - 1.0f) + 7.0f * color.r)) : (color.r + (2.0f * glow.r - 1.0f) * (sqrt(color.r) - color.r)));
		color.g = (glow.g <= 0.5f) ? (color.g - (1.0f - 2.0f * glow.g) * color.g * (1.0f - color.g)) : (((glow.g > 0.5f) && (color.g <= 0.25f)) ? (color.g + (2.0f * glow.g - 1.0f) * (4.0f * color.g * (4.0f * color.g + 1.0f) * (color.g - 1.0f) + 7.0f * color.g)) : (color.g + (2.0f * glow.g - 1.0f) * (sqrt(color.g) - color.g)));
		color.b = (glow.b <= 0.5f) ? (color.b - (1.0f - 2.0f * glow.b) * color.b * (1.0f - color.b)) : (((glow.b > 0.5f) && (color.b <= 0.25f)) ? (color.b + (2.0f * glow.b - 1.0f) * (4.0f * color.b * (4.0f * color.b + 1.0f) * (color.b - 1.0f) + 7.0f * color.b)) : (color.b + (2.0f * glow.b - 1.0f) * (sqrt(color.b) - color.b)));
		return color;
	} else { //replace
		return glow;
	}
}

vec3 apply_bcs(vec3 color, vec3 bcs) {
	color = mix(vec3(0.0f), color, bcs.x);
	color = mix(vec3(0.5f), color, bcs.y);
	color = mix(vec3(dot(vec3(1.0f), color) * 0.33333f), color, bcs.z);

	return color;
}

vec3 apply_color_correction(vec3 color, sampler3D correction_tex) {
	return texture(correction_tex, color).rgb;
}

void main() {
	vec3 color = textureLod(source_color, uv_interp, 0.0f).rgb;

	// Exposure

	if (params.use_auto_exposure) {
		color /= texelFetch(source_auto_exposure, ivec2(0, 0), 0).r / params.auto_exposure_grey;
	}

	color *= params.exposure;

	// Early Tonemap & SRGB Conversion

	if (params.use_glow && params.glow_mode == GLOW_MODE_MIX) {

		vec3 glow = gather_glow(source_glow, uv_interp);
		color.rgb = mix(color.rgb, glow, params.glow_intensity);
	}

	color = apply_tonemapping(color, params.white);

	color = linear_to_srgb(color); // regular linear -> SRGB conversion

	// Glow

	if (params.use_glow && params.glow_mode != GLOW_MODE_MIX) {

		vec3 glow = gather_glow(source_glow, uv_interp) * params.glow_intensity;

		// high dynamic range -> SRGB
		glow = apply_tonemapping(glow, params.white);
		glow = linear_to_srgb(glow);

		color = apply_glow(color, glow);
	}

	// Additional effects

	if (params.use_bcs) {
		color = apply_bcs(color, params.bcs);
	}

	if (params.use_color_correction) {
		color = apply_color_correction(color, color_correction);
	}

	frag_color = vec4(color, 1.0f);
}
