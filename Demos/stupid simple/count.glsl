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

layout(set=0, binding=0, std430) buffer StateBuf { BoidState boids[]; } state;
layout(set=0, binding=1, std430) buffer CellCount { uint counts[]; } cell_count;
// Per-team economy stats the CPU reads once per second (the econ tick):
//   [t*2]   = alive boid count        (CPU clears before dispatch)
//   [t*2+1] = dead boid id + 1 for the revival pool (0 = none this pass;
//             atomicMax keeps the LARGEST, so CPU revives one boid per
//             barrack-tick by taking the highest free boid id)
layout(set=0, binding=2, std430) buffer EconStatsBuf { uint stats[]; } econ_stats;
// Boids still following each path: one counter per (hex, team, slot).
// Indexed [((hex_id * 4) + team) * 10 + slot]; CPU clears before dispatch and
// reads it to know when a drawn path has no followers left (visual cleanup).
layout(set=0, binding=3, std430) buffer PathFollowersBuf { uint followers[]; } path_followers;
layout(push_constant) uniform PC {
    // grid_dims.w = num_teams - every team-indexed buffer/loop keys off it.
    vec4 params; vec4 world_min; ivec4 grid_dims;
    vec4 hex_params; ivec4 hex_grid;
} pc;
layout(local_size_x=64) in;

ivec3 get_cell(vec3 pos, vec3 world_min, float cell_size) {
    return ivec3(floor((pos - world_min) / cell_size));
}

// 2D cell index: team * (dims.x * dims.z) + cx + cz * dims.x
uint cell_index(int team, ivec3 cell, ivec3 dims) {
    int cx = clamp(cell.x, 0, dims.x - 1);
    int cz = clamp(cell.z, 0, dims.z - 1);
    return uint(team * dims.x * dims.z + cx + cz * dims.x);
}

void main() {
    uint id = gl_GlobalInvocationID.x;
    if (id >= uint(pc.params.y)) return;
    int team = int(state.boids[id].team) % ((pc.grid_dims.w > 0) ? pc.grid_dims.w : 4);

    if (state.boids[id].health != 0u) {
        // ALIVE: count it into its team's spatial grid (existing behavior).
        ivec3 cell = get_cell(state.boids[id].pos.xyz, pc.world_min.xyz, pc.params.z);
        uint idx = cell_index(team, cell, pc.grid_dims.xyz);
        atomicAdd(cell_count.counts[idx], 1);
        atomicAdd(econ_stats.stats[team * 2], 1u);

        // Still following a path? Count it so the CPU can tell when a drawn
        // path is fully walked (0 followers + expired = deletable). Boids in
        // the wall-bounce cooldown (slot >= 10) aren't following anything.
        uint p_hex = state.boids[id].assigned_path_hex;
        uint p_slot = state.boids[id].assigned_path_slot;
        if (p_hex != 0xFFFFFFFFu && p_slot < 10u) {
            uint f_idx = ((p_hex * uint(pc.grid_dims.w)) + uint(team)) * 10u + p_slot;
            atomicAdd(path_followers.followers[f_idx], 1u);
        }
    } else {
        // DEAD: record the largest dead id (+1 so 0 can mean "none") - the
        // CPU's barrack revival picks these up one at a time.
        atomicMax(econ_stats.stats[team * 2 + 1], id + 1u);
    }
}
