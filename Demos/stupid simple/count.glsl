#[compute]
#version 450

struct BoidState { vec4 pos; vec4 vel; uint state; uint path_count; };

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
uint cell_index(ivec3 cell, ivec3 dims) {
    ivec3 c = clamp(cell, ivec3(0), dims - ivec3(1));
    return uint(c.x + c.y * dims.x + c.z * dims.x * dims.y);
}

void main() {
    uint id = gl_GlobalInvocationID.x;
    if (id >= uint(pc.params.y)) return;
    ivec3 cell = get_cell(state.boids[id].pos.xyz, pc.world_min.xyz, pc.params.z);
    uint idx = cell_index(cell, pc.grid_dims.xyz);
    atomicAdd(cell_count.counts[idx], 1);
}