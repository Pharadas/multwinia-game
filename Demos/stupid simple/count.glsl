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
layout(push_constant) uniform PC {
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
    if (state.boids[id].health == 0u) return;
    int team = int(state.boids[id].team) % 4;
    ivec3 cell = get_cell(state.boids[id].pos.xyz, pc.world_min.xyz, pc.params.z);
    uint idx = cell_index(team, cell, pc.grid_dims.xyz);
    atomicAdd(cell_count.counts[idx], 1);
}
