shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

// Bind the EXACT SAME buffer RID that the compute shader writes to
layout(set = 0, binding = 0, std430) restrict readonly buffer UnitData {
    vec4 unit_data[]; // xyz = position, w = unit_type (0.0 to 1.0)
} units;

// We use a simple base mesh (like a small Cone or Box centered at 0,0,0)
void vertex() {
    // INSTANCE_ID is automatically provided by Godot for each drawn instance
    uint id = uint(INSTANCE_ID);
    
    // Safety check to prevent out-of-bounds reads if instance count > buffer size
    if (id >= uint(length(unit_data))) {
        POSITION = vec4(0.0, -1000.0, 0.0, 1.0); // Hide off-screen
        return;
    }

    vec4 data = units.unit_data[id];
    vec3 pos = data.xyz;
    float type = data.w;

    // Build a simple translation matrix for this instance
    // (For advanced armies, you can store a full mat4 in the buffer instead of vec4)
    mat4 instance_transform = mat4(
        vec4(1.0, 0.0, 0.0, 0.0),
        vec4(0.0, 1.0, 0.0, 0.0),
        vec4(0.0, 0.0, 1.0, 0.0),
        vec4(pos, 1.0)
    );

    // Apply transform
    POSITION = (PROJECTION_MATRIX * VIEW_MATRIX * instance_transform * vec4(VERTEX, 1.0)).xyzw;
    
    // Color units based on their 'type' or health (w component)
    // e.g., type 0.0 = Blue (friendly), 1.0 = Red (enemy)
    COLOR = mix(vec4(0.2, 0.5, 1.0, 1.0), vec4(1.0, 0.2, 0.2, 1.0), type);
}

void fragment() {
    ALBEDO = COLOR.rgb;
}