#[compute]
#version 450
struct BoidState { vec4 pos; vec4 vel; };
layout(set=0, binding=0, std430) buffer ReadState { BoidState boids[]; } read_s;
layout(set=0, binding=1, std430) buffer WriteState { BoidState boids[]; } write_s;
layout(set=0, binding=2, std430) buffer CellOffset { uint offsets[]; } cell_offset;
layout(set=0, binding=3, std430) buffer CellCount { uint counts[]; } cell_count;
layout(set=0, binding=4, std430) buffer SortedIdx { uint idx[]; } sorted;
layout(push_constant) uniform PC {
    vec4 params; vec4 world_min; ivec4 grid_dims;
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

    vec3 pos = read_s.boids[id].pos.xyz;
    vec3 vel = read_s.boids[id].vel.xyz;
    float cell_size = pc.params.z;
    ivec3 dims = pc.grid_dims.xyz;
    ivec3 my_cell = get_cell(pos, pc.world_min.xyz, cell_size);

    vec3 sep = vec3(0.0), align = vec3(0.0), coh = vec3(0.0);
    int neighbors = 0;
    float perception = cell_size;

    for (int dx = -1; dx <= 1; dx++)
    for (int dy = -1; dy <= 1; dy++)
    for (int dz = -1; dz <= 1; dz++) {
        ivec3 neighbor_cell = my_cell + ivec3(dx, dy, dz);
        if (any(lessThan(neighbor_cell, ivec3(0))) || any(greaterThanEqual(neighbor_cell, dims))) continue;
        uint h = cell_index(neighbor_cell, dims);
        uint start = cell_offset.offsets[h];
        uint count = cell_count.counts[h];

        for (uint k = 0u; k < count; k++) {
            uint other_id = sorted.idx[start + k];
            if (other_id == id) continue;
            vec3 other_pos = read_s.boids[other_id].pos.xyz;
            float d = distance(pos, other_pos);
            if (other_id % 3 != id % 3) {
                sep += (pos - other_pos) / (d * d);
                continue;
            }
            if (d < perception && d > 0.001) {
                sep += (pos - other_pos) / (d * d);
                align += read_s.boids[other_id].vel.xyz;
                coh += other_pos;
                neighbors++;
            }
        }
    }

    vec3 accel = vec3(0.0);
    if (neighbors > 0) {
        align /= float(neighbors);
        coh = (coh / float(neighbors)) - pos;
        accel = sep * 1.5 + align * 1.0 + coh * 1.0;
    }

    vel += accel * pc.params.x;
    float max_speed = 4.0;
    if (length(vel) > max_speed) vel = normalize(vel) * max_speed;
    pos += vel * pc.params.x;

    // clamp to world bounds so boids don't fly off and skew the grid
    vec3 wmin = pc.world_min.xyz;
    vec3 wmax = wmin + vec3(dims) * cell_size;
    pos = clamp(pos, wmin, wmax);

    write_s.boids[id].pos = vec4(pos, 0.0);
    write_s.boids[id].vel = vec4(vel, 0.0);
}