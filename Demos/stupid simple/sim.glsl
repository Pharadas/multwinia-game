#[compute]
#version 450

#define STATE_ALIVE  0x00000001u
#define STATE_DEAD   0x00000002u
#define STATE_HAS_PATH 0x00000004u
#define NO_PATH 0xFFFFFFFFu

struct BoidState {
    vec4 pos;
    vec4 vel;
    uint state;
    uint assigned_path_hex;
    uint assigned_path_slot;
    uint team;
    uint health;
};

layout(set=0, binding=0, std430) buffer ReadState { BoidState boids[]; } read_s;
layout(set=0, binding=1, std430) buffer WriteState { BoidState boids[]; } write_s;
layout(set=0, binding=2, std430) buffer CellOffset { uint offsets[]; } cell_offset;
layout(set=0, binding=3, std430) buffer CellCount { uint counts[]; } cell_count;
layout(set=0, binding=4, std430) buffer SortedIdx { uint idx[]; } sorted;
layout(set=0, binding=5, std430) buffer CellInfo { uint idx[]; } cell_info;

struct Path {
    vec2 points[16];
    int count;
};

struct HexPaths {
    int path_count;
    Path paths[10];
};

layout(set=0, binding=6, std430) buffer GlobalPathsBuf {
    HexPaths hex_paths[];
} global_paths;

layout(push_constant) uniform PC {
    vec4 params; vec4 world_min; ivec4 grid_dims;
    vec4 hex_params; ivec4 hex_grid;
} pc;

layout(local_size_x=64) in;

ivec3 get_cell(vec3 pos, vec3 world_min, float cell_size) {
    return ivec3(floor((pos - world_min) / cell_size));
}

uint cell_index_2d(int team, ivec3 cell, ivec3 dims) {
    int cx = clamp(cell.x, 0, dims.x - 1);
    int cz = clamp(cell.z, 0, dims.z - 1);
    return uint(team * dims.x * dims.z + cx + cz * dims.x);
}

int world_to_hex_id(vec3 pos) {
    float hex_size = pc.hex_params.x;
    float mesh_scale = pc.hex_params.y;
    int grid_w = int(pc.hex_grid.x);
    int grid_h = int(pc.hex_grid.y);

    if (hex_size < 0.001 || mesh_scale < 0.001) return 0;

    const float SQRT_3 = 1.73205080757;

    float horiz_spacing = hex_size * 1.5;
    float vert_spacing = SQRT_3 * hex_size;
    float total_width = float(grid_w - 1) * horiz_spacing;
    float total_depth = float(grid_h) * vert_spacing;

    float u = pos.x / mesh_scale + total_width * 0.5;
    float v = pos.z / mesh_scale + total_depth * 0.5;

    float q = (2.0 / 3.0 * u) / hex_size;
    float r = (-1.0 / 3.0 * u + SQRT_3 / 3.0 * v) / hex_size;
    float s = -q - r;

    int rq = int(round(q));
    int rr = int(round(r));
    int rs = int(round(s));

    float q_diff = abs(float(rq) - q);
    float r_diff = abs(float(rr) - r);
    float s_diff = abs(float(rs) - s);

    if (q_diff > r_diff && q_diff > s_diff) {
        rq = -rr - rs;
    } else if (r_diff > s_diff) {
        rr = -rq - rs;
    }

    int col = rq;
    int row = rr + (rq - (rq & 1)) / 2;

    int min_q = int(pc.hex_params.z);
    int min_r = int(pc.hex_params.w);
    int w = int(pc.hex_grid.z);
    if (w <= 0) w = grid_w;

    return (col - min_q) + (row - min_r) * w;
}

// Per-boid pseudo-random based on ID — breaks symmetry so boids in the
// same cell don't all get identical forces.
float hash(uint n) {
    n = (n << 13u) ^ n;
    n = n * (n * n * 15731u + 789221u) + 1376312589u;
    return float(n & 0x7FFFFFFFu) / float(0x7FFFFFFF);
}

// 2D neighbor offsets (9 cells)
const ivec3 OFFSETS_2D[9] = ivec3[9](
    ivec3( 0, 0,  0),
    ivec3(-1, 0,  0), ivec3( 1, 0,  0),
    ivec3( 0, 0, -1), ivec3( 0, 0,  1),
    ivec3(-1, 0, -1), ivec3( 1, 0, -1),
    ivec3(-1, 0,  1), ivec3( 1, 0,  1)
);

void main() {
    uint id = gl_GlobalInvocationID.x;
    if (id >= uint(pc.params.y)) return;

    vec3 pos = read_s.boids[id].pos.xyz;
    vec3 vel = read_s.boids[id].vel.xyz;
    vec3 original_pos = pos;
    float cell_size = pc.params.z;
    ivec3 dims = pc.grid_dims.xyz;
    ivec3 my_cell = get_cell(pos, pc.world_min.xyz, cell_size);
    int my_team = int(read_s.boids[id].team) % 4;
    int original_hex_id = world_to_hex_id(pos);
    uint state = read_s.boids[id].state;
    uint assigned_hex = read_s.boids[id].assigned_path_hex;
    uint assigned_slot = read_s.boids[id].assigned_path_slot;

    if (read_s.boids[id].health <= 0) {
        write_s.boids[id].pos = vec4(0.0, 0.0, 0.0, float(my_team));
        write_s.boids[id].vel = vec4(0.0);
        write_s.boids[id].team = uint(my_team);
        write_s.boids[id].health = 0;
        return;
    }

    // Per-boid random offsets — each boid gets slightly different forces
    // even when neighbors are identical, breaking grid lockstep.
    float rx = hash(id * 3u + 0u) * 2.0 - 1.0;
    float ry = hash(id * 3u + 1u) * 2.0 - 1.0;
    float rz = hash(id * 3u + 2u) * 2.0 - 1.0;

    vec3 sep = vec3(0.0), align = vec3(0.0), coh = vec3(0.0);
    int neighbors = 0;
    float perception = cell_size;

    // --- FLOCKING: search own team's 2D grid (9 cells) ---
    for (int c = 0; c < 9 && neighbors < 50; c++) {
        ivec3 neighbor_cell = my_cell + OFFSETS_2D[c];
        if (neighbor_cell.x < 0 || neighbor_cell.x >= dims.x ||
            neighbor_cell.z < 0 || neighbor_cell.z >= dims.z) continue;

        uint h = cell_index_2d(my_team, neighbor_cell, dims);
        uint start = cell_offset.offsets[h];
        uint count = cell_count.counts[h];

        // Sample up to min(count, 8) random neighbors per cell
        uint samples = min(count, 8u);
        for (uint k = 0u; k < samples && neighbors < 50; k++) {
            uint idx = uint(hash(id * 137u + uint(c) * 997u + k) * float(count)) % count;
            uint other_id = sorted.idx[start + idx];
            if (other_id == id) continue;
            vec3 other_pos = read_s.boids[other_id].pos.xyz;
            float d = distance(pos, other_pos);
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
        // Lower cohesion (was 5.0) so boids don't all converge to same point
        accel = sep * 4.0 + align * 1.0 + coh * 1.5;
    }

    // Add per-boid wander force to break grid symmetry
    accel += vec3(rx, ry * 0.3, rz) * 1.5;

    // --- ENEMY COMBAT & REPULSION ---
    int nearby_enemies = 0;
    for (int t = 0; t < 4; t++) {
        if (t == my_team) continue;
        for (int c = 0; c < 9; c++) {
            ivec3 neighbor_cell = my_cell + OFFSETS_2D[c];
            if (neighbor_cell.x < 0 || neighbor_cell.x >= dims.x ||
                neighbor_cell.z < 0 || neighbor_cell.z >= dims.z) continue;

            uint h = cell_index_2d(t, neighbor_cell, dims);
            uint start = cell_offset.offsets[h];
            uint count = cell_count.counts[h];

            uint esamples = min(count, 10u);
            for (uint k = 0u; k < esamples; k++) {
                uint idx = uint(hash(id * 251u + uint(t) * 571u + k) * float(count)) % count;
                uint other_id = sorted.idx[start + idx];
                vec3 other_pos = read_s.boids[other_id].pos.xyz;
                float d = distance(pos, other_pos);
                if (d < perception && d > 0.001) {
                    nearby_enemies++;
                }
            }
        }
    }

    if (nearby_enemies > 0) {
        accel *= 0.5;
    }

    // 1. If boid has no path assigned, look at its current hex for team paths
    if (assigned_hex == NO_PATH) {
        int my_hex = world_to_hex_id(pos);
        int target_hex = -1;

        int team_hex_idx = my_hex * 4 + my_team;
        if (global_paths.hex_paths[team_hex_idx].path_count > 0) {
            target_hex = my_hex;
        }

        if (target_hex >= 0) {
            int t_hex_idx = target_hex * 4 + my_team;
            int total_paths = global_paths.hex_paths[t_hex_idx].path_count;
            int active_count = min(total_paths, 10);
            uint chosen = id % uint(active_count);
            if (global_paths.hex_paths[t_hex_idx].paths[chosen].count > 0) {
                assigned_hex = uint(target_hex);
                assigned_slot = chosen;
            }
        }
    }

    // 2. If boid has an assigned path, follow its team's path
    if (assigned_hex != NO_PATH) {
        int t_hex_idx = int(assigned_hex) * 4 + my_team;
        int p_count = global_paths.hex_paths[t_hex_idx].paths[assigned_slot].count;
        if (p_count <= 0) {
            assigned_hex = NO_PATH;
        } else if (p_count == 1) {
            vec2 tp = global_paths.hex_paths[t_hex_idx].paths[assigned_slot].points[0];
            vec3 target = vec3(tp.x, pos.y, tp.y);
            vec3 to_target = target - pos;
            float d = length(to_target.xz);
            if (d > 0.5) {
                accel += normalize(to_target) * 8.0;
                state = STATE_HAS_PATH;
            } else {
                assigned_hex = NO_PATH;
            }
        } else {
            vec2 final_pt = global_paths.hex_paths[t_hex_idx].paths[assigned_slot].points[p_count - 1];
            float dist_to_end = length(pos.xz - final_pt);

            if (dist_to_end <= 0.8) {
                assigned_hex = NO_PATH;
                state = STATE_ALIVE;
            } else {
                float min_dist_sq = 1e10;
                int best_seg = 0;
                vec2 best_proj = global_paths.hex_paths[t_hex_idx].paths[assigned_slot].points[0];

                for (int i = 0; i < p_count - 1; i++) {
                    vec2 a = global_paths.hex_paths[t_hex_idx].paths[assigned_slot].points[i];
                    vec2 b = global_paths.hex_paths[t_hex_idx].paths[assigned_slot].points[i + 1];
                    vec2 ab = b - a;
                    float l2 = dot(ab, ab);
                    float t = 0.0;
                    vec2 proj = a;
                    if (l2 > 0.0001) {
                        t = clamp(dot(pos.xz - a, ab) / l2, 0.0, 1.0);
                        proj = a + t * ab;
                    }
                    float d2 = dot(pos.xz - proj, pos.xz - proj);
                    if (d2 < min_dist_sq) {
                        min_dist_sq = d2;
                        best_seg = i;
                        best_proj = proj;
                    }
                }

                float lookahead = 6.0;
                vec2 target_2d = best_proj;

                int curr_seg = best_seg;
                vec2 seg_a = best_proj;
                vec2 seg_b = global_paths.hex_paths[t_hex_idx].paths[assigned_slot].points[curr_seg + 1];
                float seg_rem = length(seg_b - seg_a);

                if (lookahead <= seg_rem) {
                    target_2d = seg_a + (seg_rem > 0.001 ? (seg_b - seg_a) * (lookahead / seg_rem) : vec2(0.0));
                } else {
                    float dist_needed = lookahead - seg_rem;
                    target_2d = seg_b;
                    for (int k = curr_seg + 1; k < p_count - 1; k++) {
                        vec2 pA = global_paths.hex_paths[t_hex_idx].paths[assigned_slot].points[k];
                        vec2 pB = global_paths.hex_paths[t_hex_idx].paths[assigned_slot].points[k + 1];
                        float seg_len = length(pB - pA);
                        if (dist_needed <= seg_len) {
                            target_2d = pA + (seg_len > 0.001 ? (pB - pA) * (dist_needed / seg_len) : vec2(0.0));
                            dist_needed = 0.0;
                            break;
                        }
                        dist_needed -= seg_len;
                        target_2d = pB;
                    }
                }

                vec3 target = vec3(target_2d.x, pos.y, target_2d.y);
                vec3 to_target = target - pos;
                float d = length(to_target.xz);
                if (d > 0.5) {
                    accel += normalize(to_target) * 8.0;
                }
                state = STATE_HAS_PATH;
            }
        }
    }

    vel += accel * pc.params.x;
    // gravity
    vel.y -= 9.8 * pc.params.x;
    float max_speed = 8.0;
    if (length(vel) > max_speed) vel = normalize(vel) * max_speed;
    pos += vel * pc.params.x;

    // clamp to world bounds
    vec3 wmin = pc.world_min.xyz;
    vec3 wmax = wmin + vec3(dims.x, 100.0, dims.z) * cell_size;
    pos = clamp(pos, wmin, wmax);

    // HARD hex boundary: if the boid left its hex and has no path, snap back
    int new_hex_id = world_to_hex_id(pos);
    if (new_hex_id != original_hex_id && state != STATE_HAS_PATH) {
        pos.xz = original_pos.xz;
        vel.xz = vec2(0.0);  // dampen on bounce
    }

    write_s.boids[id].pos = vec4(pos, float(my_team));
    write_s.boids[id].vel = vec4(vel, 0.0);
    write_s.boids[id].state = state;
    write_s.boids[id].assigned_path_hex = assigned_hex;
    write_s.boids[id].assigned_path_slot = assigned_slot;
    write_s.boids[id].team = uint(my_team);

    uint current_health = read_s.boids[id].health;
    if (nearby_enemies > 0) {
        // Base damage rate: 300 damage per second per nearby enemy (boids have 1000 max health)
        float damage_amount = float(nearby_enemies) * 300.0 * pc.params.x;
        uint dmg = uint(max(1.0, ceil(damage_amount)));
        if (current_health <= dmg) {
            current_health = 0u;
        } else {
            current_health -= dmg;
        }
    }
    write_s.boids[id].health = current_health;
}
