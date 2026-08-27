#[compute]
#version 450
layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Positions {
    vec4 positions[];
} posBuf;

layout(set = 0, binding = 1, std430) restrict buffer Velocities {
    vec4 velocities[];
} velBuf;

layout(set = 0, binding = 2, std430) restrict buffer HashCounts {
    uint counts[];
} countBuf;

layout(set = 0, binding = 3, std430) restrict buffer PrefixSum {
    uint prefix_sum[];
} prefBuf;

layout(set = 0, binding = 4, std430) restrict buffer HashIndexes {
    uint indexes[];
} indexBuf;

layout(push_constant) uniform Params {
    uint num_units;
    uint hash_size;
    float cell_size;
    float delta_time;
    vec3 target_pos;
    vec3 arena_bounds;
} pc;

uint cell_hash(uvec3 cell) {
    return (uint(cell.x) * 73856093u) ^ 
           (uint(cell.y) * 19349663u) ^ 
           (uint(cell.z) * 83492791u);
}

uvec3 coord_to_cell(vec3 pos) {
    return uvec3(floor(pos / pc.cell_size));
}

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= pc.num_units) return;

    vec3 my_pos = posBuf.positions[i].xyz;
    vec3 my_vel = velBuf.velocities[i].xyz;
    uvec3 base_cell = coord_to_cell(my_pos);
    
    vec3 separation = vec3(0.0);
    vec3 cohesion = vec3(0.0);
    vec3 alignment = vec3(0.0);
    int neighbor_count = 0;

    for (int dx = -1; dx <= 1; ++dx) {
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dz = -1; dz <= 1; ++dz) {
                uvec3 neighbor_cell = base_cell + uvec3(dx, dy, dz);
                uint h = cell_hash(neighbor_cell) % pc.hash_size;
                uint count = countBuf.counts[h];
                if (count == 0u) continue;

                uint start_idx = prefBuf.prefix_sum[h] - 1u;
                for (uint k = 0u; k < count; ++k) {
                    uint n_idx = indexBuf.indexes[start_idx - k];
                    if (n_idx == i) continue;

                    vec3 n_pos = posBuf.positions[n_idx].xyz;
                    vec3 n_vel = velBuf.velocities[n_idx].xyz;
                    float dist = distance(my_pos, n_pos);

                    if (dist < pc.cell_size && dist > 0.0) {
                        vec3 diff = my_pos - n_pos;
                        separation += normalize(diff) / dist;
                        cohesion += n_pos;
                        alignment += n_vel;
                        neighbor_count++;
                    }
                }
            }
        }
    }

    vec3 force = vec3(0.0);
    if (neighbor_count > 0) {
        separation /= float(neighbor_count);
        cohesion = (cohesion / float(neighbor_count)) - my_pos;
        alignment /= float(neighbor_count);

        force += separation * 1.5;
        force += cohesion * 0.5;
        force += alignment * 0.5;
    }

    vec3 to_target = normalize(pc.target_pos - my_pos);
    force += to_target * 2.0;

    vec3 bounds = pc.arena_bounds;
    if (my_pos.x < 5.0) force.x += 5.0;
    if (my_pos.x > bounds.x - 5.0) force.x -= 5.0;
    if (my_pos.z < 5.0) force.z += 5.0;
    if (my_pos.z > bounds.z - 5.0) force.z -= 5.0;

    vec3 new_vel = my_vel + (force * pc.delta_time);
    float speed = length(new_vel);
    float max_speed = 15.0;
    if (speed > max_speed) new_vel = (new_vel / speed) * max_speed;

    vec3 new_pos = my_pos + (new_vel * pc.delta_time);

    velBuf.velocities[i] = vec4(new_vel, 0.0);
    posBuf.positions[i] = vec4(new_pos, posBuf.positions[i].w);
}