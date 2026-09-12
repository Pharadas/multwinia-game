#[compute]
#version 450

struct BoidState {
    vec4 pos;
    vec4 vel;
    uint state;
    uint assigned_path_hex;
    uint assigned_path_slot;
    uint team;
    uint health;
    int home_hex;
};

#define STATE_CHARGING 0x00000040u  // dying dot about to explode (matches sim.glsl)

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

    if (state.boids[id].health == 0u) {
        mm_buffer.instances[id].row1 = vec4(0.0);
        mm_buffer.instances[id].row2 = vec4(0.0);
        mm_buffer.instances[id].row3 = vec4(0.0);
        mm_buffer.instances[id].color = vec4(0.0);
        return;
    }

    vec3 pos = state.boids[id].pos.xyz;
    vec3 vel = state.boids[id].vel.xyz;

    vec3 fwd = length(vel) > 0.001 ? normalize(vel) : vec3(0.0, 0.0, 1.0);
    vec3 up_hint = abs(fwd.y) > 0.99 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
    vec3 right = normalize(cross(up_hint, fwd));
    vec3 up = cross(fwd, right);

    // Godot's MultiMesh transform buffer is 12 floats in Transform3D
    // constructor order: basis row 0, origin.x, basis row 1, origin.y,
    // basis row 2, origin.z. Each vec4 is one 4-float group (std430 vec4
    // stride = 16B, no padding), so origin lands in each vec4's .w.
    mm_buffer.instances[id].row1 = vec4(right.x, up.x, fwd.x, pos.x);
    mm_buffer.instances[id].row2 = vec4(right.y, up.y, fwd.y, pos.y);
    mm_buffer.instances[id].row3 = vec4(right.z, up.z, fwd.z, pos.z);

    // Color by team index. First 4 teams get fixed recognizable colors;
    // teams 4+ get evenly spaced hues so any team count works. Team id is
    // masked to num_teams first so a corrupt id can't index out of range.
    // The LAST team index is the NPC horde (deserters) - always rendered
    // dark gray-violet regardless of team count, so it never collides with
    // a player team's generated hue.
    uint boid_team = state.boids[id].team;
    uint nt = uint((pc.grid_dims.w > 0) ? pc.grid_dims.w : 4);
    uint t = boid_team % nt;
    vec4 c;
    if (t == nt - 1u) c = vec4(0.42, 0.38, 0.46, 1.0); // NPC horde: rogue
    else if (t == 0u) c = vec4(0.9, 0.2, 0.2, 1.0);    // Team 0: Red
    else if (t == 1u) c = vec4(0.2, 0.8, 0.2, 1.0);    // Team 1: Green
    else if (t == 2u) c = vec4(0.2, 0.4, 0.9, 1.0);    // Team 2: Blue
    else if (t == 3u) c = vec4(0.9, 0.8, 0.2, 1.0);    // Team 3: Yellow
    else {
        // Evenly spaced hue around the wheel for teams 4..nt-2.
        float frac = float(t - 4u) / float(max(nt - 5u, 1u));
        c = vec4(fract(frac + 0.08), 0.75, 0.55, 1.0);
    }

    // CHARGING (about to explode): strobe white faster as the fuse burns
    // down - the classic warning blink. The fuse deadline (sim seconds)
    // is packed in the slot field; flash period shrinks as time runs out.
    if ((state.boids[id].state & STATE_CHARGING) != 0u) {
        float remaining = float(state.boids[id].assigned_path_slot) - pc.params.w;
        float period = clamp(remaining * 0.4, 0.1, 0.4);
        float flash = fract(pc.params.w / period) < 0.5 ? 1.0 : 0.25;
        c = vec4(flash, flash, flash, 1.0);
    }
    mm_buffer.instances[id].color = c;
}