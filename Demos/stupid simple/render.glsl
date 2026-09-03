#[compute]
#version 450

struct BoidState {
    vec4 pos;
    vec4 vel;
    uint state;
    uint assigned_path_hex;
    uint assigned_path_slot;
    uint team;
};

struct InstanceData {
    vec4 row1; vec4 row2; vec4 row3; vec4 color;
};

layout(set=0, binding=0, std430) buffer StateBuf { BoidState boids[]; } state;
layout(set=0, binding=1, std430) buffer MultiMeshBuffer { InstanceData instances[]; } mm_buffer;
layout(push_constant) uniform PC {
    vec4 params; vec4 world_min; ivec4 grid_dims;
    vec4 hex_params; ivec4 hex_grid;
} pc;
layout(local_size_x=64) in;

void main() {
    uint id = gl_GlobalInvocationID.x;
    if (id >= uint(pc.params.y)) return;

    vec3 pos = state.boids[id].pos.xyz;
    vec3 vel = state.boids[id].vel.xyz;

    vec3 fwd = length(vel) > 0.001 ? normalize(vel) : vec3(0.0, 0.0, 1.0);
    vec3 up_hint = abs(fwd.y) > 0.99 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
    vec3 right = normalize(cross(up_hint, fwd));
    vec3 up = cross(fwd, right);

    mm_buffer.instances[id].row1 = vec4(right.x, up.x, fwd.x, pos.x);
    mm_buffer.instances[id].row2 = vec4(right.y, up.y, fwd.y, pos.y);
    mm_buffer.instances[id].row3 = vec4(right.z, up.z, fwd.z, pos.z);

    // Color by team index (0..3)
    uint boid_team = state.boids[id].team;
    vec4 team_colors[4] = vec4[4](
        vec4(0.9, 0.2, 0.2, 1.0), // Team 0: Red
        vec4(0.2, 0.8, 0.2, 1.0), // Team 1: Green
        vec4(0.2, 0.4, 0.9, 1.0), // Team 2: Blue
        vec4(0.9, 0.8, 0.2, 1.0)  // Team 3: Yellow
    );
    mm_buffer.instances[id].color = team_colors[boid_team % 4u];
}