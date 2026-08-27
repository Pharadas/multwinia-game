// boid_render.glsl
//
// The render half of the boids swarm: an instanced billboard pipeline that
// draws one screen-facing quad per dot, reading each dot's position directly
// from the simulation's position SSBO (pos_buf) - no intermediate texture,
// no particle node. It runs as a CompositorEffect (boid_render_effect.gd) at
// the POST_OPAQUE stage, so the dots are depth-tested against the scene and
// drawn with additive blending.
//
// One draw call: 4 quad corners (triangle strip) instanced dot_count times.
// gl_InstanceIndex picks the dot; the corner expands into a camera-facing
// billboard of dot_scale world units. The fragment shader turns it into a
// soft disc tinted by team_color. pos_buf.w carries the hex ID (unused by
// the renderer).

#[vertex]
#version 450

layout(location = 0) in vec3 corner; // -1..1 quad corner, 4 verts

layout(set = 0, binding = 0, std430) readonly buffer Pos {
    vec4 data[]; // xyz = world position, w = hex ID (unused here)
} pos_buf;

layout(set = 0, binding = 1, std140) uniform Cam {
    mat4 view;          // world -> view
    mat4 proj;          // view -> clip (Godot's reversed-Z convention)
    vec3 cam_right;     // world-space camera right (billboard basis)
    float _pad0;
    vec3 cam_up;        // world-space camera up
    float _pad1;
    vec2 viewport;      // internal render size in px
    float dot_scale;    // billboard half-extent in world units
    float density_scale;// unused (kept for UBO compatibility)
    vec3 team_color;
    float _pad2;
} cam;

layout(location = 0) out float brightness;
layout(location = 1) out vec2 uv;

void main() {
    uint idx = gl_InstanceIndex;
    vec3 world = pos_buf.data[idx].xyz;

    // Camera-facing billboard: expand the corner along the camera's right/up
    // basis (passed in world space, so the quad always faces the viewer).
    vec3 corner_world = world + (cam.cam_right * corner.x + cam.cam_up * corner.y) * cam.dot_scale;

    gl_Position = cam.proj * cam.view * vec4(corner_world, 1.0);
    uv = corner.xy;
    brightness = 1.0;
}

#[fragment]
#version 450

layout(location = 0) in float brightness;
layout(location = 1) in vec2 uv;
layout(location = 0) out vec4 frag_color;

layout(set = 0, binding = 1, std140) uniform Cam {
    mat4 view;
    mat4 proj;
    vec3 cam_right;
    float _pad0;
    vec3 cam_up;
    float _pad1;
    vec2 viewport;
    float dot_scale;
    float density_scale;
    vec3 team_color;
    float _pad2;
} cam;

void main() {
    float r = length(uv);
    if (r > 1.0) {
        discard; // keep the billboard square invisible outside the disc
    }
    // Soft-edged disc (1 at the center, 0 at the rim). smoothstep edges
    // must be ordered low-then-high (results are undefined otherwise).
    float alpha = 1.0 - smoothstep(0.25, 1.0, r);
    // Additive blending: dense patches read as a glowing cloud.
    frag_color = vec4(cam.team_color * brightness, alpha);
}
