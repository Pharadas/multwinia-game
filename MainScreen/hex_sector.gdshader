shader_type spatial;

float random(vec3 pos) {
    return fract(sin(dot(pos, vec3(12.9898, 78.233, 45.164))) * 43758.5453123);
}

varying vec3 world_position;
varying vec3 n;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    n = mat3(MODEL_MATRIX) * NORMAL;
    n = normalize(n);
}

void fragment() {
	vec4 flat_color = vec4(0.0, 0.7, 0.2, 1.0);
	vec4 steep_color = vec4(0.3607, 0.2510, 0.2000, 1.0);
	float slope_threshold = 0.7;
	float blend_smoothness = 0.1;

	//// Flat per-triangle normal from screen-space derivatives - gives each
	//// hex/wedge triangle its own faceted shading instead of smooth blending.
	////NORMAL = normalize(cross(dFdx(world_position), dFdy(world_position)));
	////float rnd = random(NORMAL) * 0.2;
	////NORMAL = NORMAL * rnd;
//
	//float normalized_world_position = 0.5 / (float(int((20.0 / (world_position.y)) * 10.0)) / 10.0);
//
	//// Use the per-vertex sector color (set via SurfaceTool.set_color) as albedo.
	////ALBEDO = COLOR.rgb * dot(n, vec3(0.0, 1.0, 0.0));
	//float f = dot(n, vec3(0.0, 1.0, 0.0));
	//ALBEDO = COLOR.rgb * n.y;
    
    // n.y is now ALWAYS world-up (1.0 = flat ground, 0.0 = cliff face)
    float slope = n.y;
    
    // Blend the colors smoothly
    float weight = smoothstep(slope_threshold - blend_smoothness, slope_threshold + blend_smoothness, slope);
    
    ALBEDO = mix(steep_color.rgb, flat_color.rgb, weight)  * COLOR.rgb;
}

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
