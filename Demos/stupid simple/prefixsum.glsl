#[compute]
#version 450
layout(set=0, binding=0, std430) buffer CellCount { uint counts[]; } cell_count;
layout(set=0, binding=1, std430) buffer CellOffset { uint offsets[]; } cell_offset;
layout(set=0, binding=2, std430) buffer WriteCursor { uint cursor[]; } write_cursor;
layout(push_constant) uniform PC {
    vec4 params; vec4 world_min; ivec4 grid_dims;
    vec4 hex_params; ivec4 hex_grid;
} pc;
layout(local_size_x=1) in;

void main() {
    uint total = 0;
    // grid_dims.y = num_teams (4), grid is 2D: dims.x * dims.y * dims.z
    uint ts = uint(pc.grid_dims.x) * uint(pc.grid_dims.y) * uint(pc.grid_dims.z);
    for (uint i = 0u; i < ts; i++) {
        cell_offset.offsets[i] = total;
        write_cursor.cursor[i] = total;
        total += cell_count.counts[i];
    }
}
