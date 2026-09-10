#[compute]
#version 450

#define STATE_ALIVE  0x00000001u
#define STATE_DEAD   0x00000002u
#define STATE_HAS_PATH 0x00000004u
#define STATE_FIGHTING 0x00000008u
#define STATE_BUILDING 0x00000010u
#define NO_PATH 0xFFFFFFFFu

struct BoidState {
    vec4 pos;
    vec4 vel;
    uint state;
    uint assigned_path_hex;
    uint assigned_path_slot;
    uint team;
    uint health;
    // Hex the boid "lives" in: while idle it's the hex it was waiting on;
    // while following a path it's the hex the path was claimed from. After
    // a fight ends the boid returns here (and re-claims its path).
    int home_hex;
};

layout(set=0, binding=0, std430) buffer ReadState { BoidState boids[]; } read_s;
layout(set=0, binding=1, std430) buffer WriteState { BoidState boids[]; } write_s;
layout(set=0, binding=2, std430) buffer CellOffset { uint offsets[]; } cell_offset;
layout(set=0, binding=3, std430) buffer CellCount { uint counts[]; } cell_count;
layout(set=0, binding=4, std430) buffer SortedIdx { uint idx[]; } sorted;

// Per grid cell: which hex it belongs to + the building sitting in it.
// `building` is 0xFFFFFFFF when the cell has no building, otherwise packed:
//   bits  0-7 : building id (0 = castle, 1 = tower, 2 = wall)
//   bits  8-15: owning team
//   bits 16-23: sub_q + 3 (axial sub-hex coord inside the parent hex, -3..3)
//   bits 24-30: sub_r + 3
//   bit  31   : BUILT flag (1 = finished, 0 = site - boids must build it)
// The building whose CENTER falls in this grid cell is the one stored here;
// the same info is replicated across all 4 team slices.
struct CellInfo {
    uint hex_id;
    uint building;
};
layout(set=0, binding=5, std430) buffer CellInfoBuf { CellInfo cells[]; } cell_info;

#define BUILDING_BUILT_BIT 0x80000000u

uint cell_building_id(uint packed_info)  { return packed_info & 0xFFu; }
uint cell_building_team(uint packed_info){ return (packed_info >> 8u) & 0xFFu; }
int  cell_building_sub_q(uint packed_info) { return int((packed_info >> 16u) & 0xFFu) - 3; }
int  cell_building_sub_r(uint packed_info) { return int((packed_info >> 24u) & 0x7Fu) - 3; }
bool cell_building_is_built(uint packed_info) { return (packed_info & BUILDING_BUILT_BIT) != 0u; }

struct Path {
    vec2 points[16];
    int count;
};

struct HexPaths {
    int path_count;
    // std430 aligns the paths array to 8 bytes, leaving 4 bytes of padding
    // after path_count - used as the fraction (0..1) of boids allowed to
    // claim paths on this hex. <= 0 means everyone may claim (default).
    float claim_chance;
    Path paths[10];
};

layout(set=0, binding=6, std430) buffer GlobalPathsBuf {
    HexPaths hex_paths[];
} global_paths;

// Ping-ponged per-boid damage accumulators (binding 7 = this frame's write
// side, cleared by the CPU each frame; last frame's totals arrive on the
// read side next frame). Attackers atomicAdd damage onto their target's
// slot in the WRITE buffer; victims subtract their slot from the READ
// buffer when applying health loss. Attackers and victims never touch the
// same buffer in the same frame, so there are no races.
layout(set=0, binding=7, std430) buffer DmgWrite { uint dmg[]; } dmg_write;
layout(set=0, binding=8, std430) buffer DmgRead { uint dmg[]; } dmg_read;

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

    // CLAMP: boids outside the terrain (random spawn box is bigger than the
    // hex grid) would otherwise produce out-of-bounds hex ids, which index
    // global_paths OOB and can crash the GPU driver.
    int hex_w = int(pc.hex_grid.z);
    int hex_h = int(pc.hex_grid.y);
    if (hex_w <= 0) hex_w = grid_w;
    if (hex_h <= 0) hex_h = grid_h;
    int total_hexes = hex_w * hex_h;
    int hid = (col - min_q) + (row - min_r) * w;
    return clamp(hid, 0, max(total_hexes - 1, 0));
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

// Inverse of world_to_hex_id's index math: hex 1D id -> offset (col,row)
// -> axial -> flat-top pixel position, then apply mesh_scale and the same
// centering offset world_to_hex_id subtracts. MUST stay in sync with it.
vec3 hex_center_from_id(int hex_id) {
    float hex_size = pc.hex_params.x;
    float mesh_scale = pc.hex_params.y;
    int min_q = int(pc.hex_params.z);
    int min_r = int(pc.hex_params.w);
    int w = int(pc.hex_grid.z);
    if (w <= 0) w = int(pc.hex_grid.x);

    int col = hex_id % w + min_q;
    int row = hex_id / w + min_r;

    // offset (odd-q) -> axial
    int q = col;
    int r = row - (col - (col & 1)) / 2;

    const float SQRT_3 = 1.73205080757;
    float horiz_spacing = hex_size * 1.5;
    float vert_spacing = SQRT_3 * hex_size;
    float total_width = float(int(pc.hex_grid.x) - 1) * horiz_spacing;
    float total_depth = float(int(pc.hex_grid.y)) * vert_spacing;

    // axial -> pixel (flat-top), then undo the same centering/undo-scaling
    // world_to_hex_id applies: it computed u = pos.x / mesh_scale + total_width*0.5
    // with u = hex_size * 1.5 * q, so invert in one step.
    float u = hex_size * 1.5 * float(q);
    float v = hex_size * (SQRT_3 / 2.0 * float(q) + SQRT_3 * float(r));

    float wx = (u - total_width * 0.5) * mesh_scale;
    float wz = (v - total_depth * 0.5) * mesh_scale;
    return vec3(wx, 0.0, wz);
}

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
    int home_hex = read_s.boids[id].home_hex;
    bool was_fighting = (state & STATE_FIGHTING) != 0u;
    bool had_path_before = assigned_hex != NO_PATH;

    // Building occupying the grid cell this boid is in (0 = none).
    uint cell_ci = cell_index_2d(0, my_cell, dims);  // building info is the same on every team slice
    uint my_building = cell_building_id(cell_info.cells[cell_ci].building);
    uint my_building_team = cell_building_team(cell_info.cells[cell_ci].building);

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
    vec3 closest_enemy_pos = vec3(1000000.0);
    uint closest_enemy_id = id;  // id means "no target"
    float closest_enemy_d = 1e10;

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
                if (read_s.boids[other_id].health == 0u) continue;  // dead boids are invisible
                vec3 other_pos = read_s.boids[other_id].pos.xyz;
                float d = distance(pos, other_pos);
                // d > 0.001: co-located boids (d == 0) would later produce
                // normalize(vec3(0)) = NaN, which poisons the whole sim.
                if (d < 0.5 && d > 0.001) {
                    // enemies close enough to attack this dot
                    nearby_enemies++;
                }
                if (d < closest_enemy_d && d > 0.001) {
                    closest_enemy_d = d;
                    closest_enemy_pos = other_pos;
                    closest_enemy_id = other_id;
                }
            }
            // GUARANTEE melee target acquisition: when boids are packed in a
            // cell, random sampling can miss the actual nearest enemy, so
            // surrounded boids spread damage instead of focusing it. Linear
            // scan of this cell only (cheap: cells hold a handful of boids).
            for (uint li = 0u; li < count && li < 32u; li++) {
                uint other_id = sorted.idx[start + li];
                if (read_s.boids[other_id].health == 0u) continue;
                float d = distance(pos, read_s.boids[other_id].pos.xyz);
                if (d < closest_enemy_d && d > 0.001) {
                    closest_enemy_d = d;
                    closest_enemy_pos = read_s.boids[other_id].pos.xyz;
                    closest_enemy_id = other_id;
                }
            }
        }
    }

    // CHASE: when enemies are visible, break off to fight. The path
    // assignment is KEPT (not dropped) - the follow block below is skipped
    // this frame while fighting, and on the first non-combat frame the boid
    // resumes the SAME path (same hex + slot) from wherever it stands.
    bool enemy_visible = closest_enemy_d < perception * 4.0;
    bool fighting = false;
    bool stand_ground = false;
    if (nearby_enemies > 0) {
        // STAND AND FIGHT: a target is in melee range, so stop moving
        // entirely - no chase force, and the flocking/wander accel gathered
        // above is discarded so boids don't spread out while trading blows.
        // They hold their ground (gravity still settles them on Y) until
        // the target dies or breaks away.
        accel.xz = vec2(0.0);
        stand_ground = true;
        // KEEP the path assignment: the follow block below is skipped while
        // fighting, and the moment the fight ends the boid resumes the SAME
        // path (same hex + slot) from where it stands - no walking back to
        // the claim hex first.
        state |= STATE_FIGHTING;  // marks the boid as allowed to cross hexes
        fighting = true;
    } else if (enemy_visible) {
        // Enemy in sight but out of melee: pursue it. Path assignment is
        // kept (not dropped), so combat resume picks the same path back up.
        vec3 chase_dir = closest_enemy_pos - pos;
        float clen = length(chase_dir);
        if (clen > 0.001) {
            accel += (chase_dir / clen) * 6.0;
        }
        state |= STATE_FIGHTING;
        fighting = true;
    } else {
        // No combat this frame - clear the fighting flag so the hex
        // boundary clamps again once the boid is done fighting.
        state &= ~STATE_FIGHTING;

        // RETURN HOME: only boids that had NO path walk back to the hex
        // they were waiting on before combat dragged them away. Boids with
        // a path skip this entirely - they resume their path from wherever
        // the fight left them (the follow block's nearest-segment projection
        // naturally picks up mid-path).
        if (was_fighting && assigned_hex == NO_PATH) {
            if (home_hex >= 0 && home_hex != original_hex_id) {
                // Home hex center via inverse hex math (axial -> pixel).
                vec3 home_center = hex_center_from_id(home_hex);
                vec3 to_home = home_center - pos;
                to_home.y = 0.0;
                float hd = length(to_home);
                if (hd > 0.6) {
                    accel += normalize(to_home) * 5.0;
                    // Fight-mode movement so it can legally cross back.
                    state |= STATE_FIGHTING;
                    fighting = true;
                } else {
                    home_hex = original_hex_id;  // arrived
                }
            }
        }
    }

    // ATTACK: if our closest enemy is in melee range, deal damage to it.
    // Single atomicAdd onto the target's slot in the WRITE accumulator -
    // each boid damages exactly ONE attacker per frame; incoming damage is
    // unlimited because everyone who picked us adds to our slot.
    const float ATTACK_RANGE = 0.5;      // must match the nearby_enemies threshold above
    const float DPS_PER_ATTACKER = 300.0;
    bool attacking = false;
    if (closest_enemy_id != id && closest_enemy_d <= ATTACK_RANGE) {
        float dmg_f = DPS_PER_ATTACKER * pc.params.x;
        uint dmg_u = uint(max(1.0, ceil(dmg_f)));
        atomicAdd(dmg_write.dmg[closest_enemy_id], dmg_u);
        attacking = true;
    }

    // (debug) attacking drives render tinting later if wanted

    // --- BUILDING DETECTION ---
    // Scan a 2-cell ring (5x5 block) of the cell_info buffer for buildings
    // owned by OTHER teams. Buildings are static so a wider scan than the
    // boid search is cheap. Track the closest one; its grid cell center is
    // close enough to the building's world position (the building is placed
    // AT its sub-hex center, which falls inside that grid cell).
    const int BUILD_SCAN = 2;  // cells in each direction
    float closest_bldg_d = 1e10;
    vec3 closest_bldg_pos = vec3(0.0);
    uint closest_bldg_id = 0u;
    uint closest_bldg_team = 0u;

    for (int bdx = -BUILD_SCAN; bdx <= BUILD_SCAN; bdx++) {
        for (int bdz = -BUILD_SCAN; bdz <= BUILD_SCAN; bdz++) {
            ivec3 bc = my_cell + ivec3(bdx, 0, bdz);
            if (bc.x < 0 || bc.x >= dims.x || bc.z < 0 || bc.z >= dims.z) continue;
            uint bci = cell_index_2d(0, bc, dims);
            uint packed_b = cell_info.cells[bci].building;
            uint bid = cell_building_id(packed_b);
            if (bid == 0xFFu) continue;  // no building in this cell
            uint bteam = cell_building_team(packed_b);
            if (int(bteam) == my_team) continue;  // friendly - ignore
            // Building center = the grid cell's world-space center.
            vec3 bp = pc.world_min.xyz + vec3(float(bc.x) + 0.5, 0.0, float(bc.z) + 0.5) * cell_size;
            float d = distance(pos.xz, bp.xz);
            if (d < closest_bldg_d) {
                closest_bldg_d = d;
                closest_bldg_pos = bp;
                closest_bldg_id = bid;
                closest_bldg_team = bteam;
            }
        }
    }

    // ATTACK BUILDING: no mobile enemies around but a hostile building is in
    // detection range (4x perception) - march on it and rally at its walls.
    // Mobile enemies take priority (handled above). Boids don't deal building
    // damage yet (no building HP on the GPU).
    if (nearby_enemies == 0 && closest_bldg_d < perception * 4.0) {
        vec3 to_bldg = closest_bldg_pos - pos;
        to_bldg.y = 0.0;
        float bd = length(to_bldg);
        if (bd > 0.001) {
            accel += normalize(to_bldg) * 5.0;
        }
    }

    // --- CONSTRUCTION: unbuilt FRIENDLY buildings need builders ---
    // Same 5x5 scan as hostile detection, but targets friendly sites (built
    // flag clear). The closest friendly boid in the cell marches to the site,
    // stands on it, and marks the building built. Combat outranks building:
    // a boid under attack won't stop to lay bricks.
    float closest_site_d = 1e10;
    ivec3 site_cell = ivec3(0);
    uint site_packed = 0u;
    bool has_site = false;
    if (nearby_enemies == 0) {
        for (int bdx = -BUILD_SCAN; bdx <= BUILD_SCAN; bdx++) {
            for (int bdz = -BUILD_SCAN; bdz <= BUILD_SCAN; bdz++) {
                ivec3 bc = my_cell + ivec3(bdx, 0, bdz);
                if (bc.x < 0 || bc.x >= dims.x || bc.z < 0 || bc.z >= dims.z) continue;
                uint bci = cell_index_2d(0, bc, dims);
                uint packed_b = cell_info.cells[bci].building;
                if (packed_b == 0xFFFFFFFFu) continue;            // empty cell
                if (cell_building_is_built(packed_b)) continue;   // already built
                if (int(cell_building_team(packed_b)) != my_team) continue;  // not ours
                vec3 bp = pc.world_min.xyz + vec3(float(bc.x) + 0.5, 0.0, float(bc.z) + 0.5) * cell_size;
                float d = distance(pos.xz, bp.xz);
                if (d < closest_site_d) {
                    closest_site_d = d;
                    site_cell = bc;
                    site_packed = packed_b;
                    has_site = true;
                }
            }
        }
    }

    bool building_now = false;
    if (has_site) {
        vec3 site_pos = pc.world_min.xyz + vec3(float(site_cell.x) + 0.5, 0.0, float(site_cell.z) + 0.5) * cell_size;
        vec3 to_site = site_pos - pos;
        to_site.y = 0.0;
        float sd = length(to_site);
        if (sd > 0.8) {
            // March to the construction site (frees hexes like fighting does).
            accel += normalize(to_site) * 6.0;
            state |= STATE_FIGHTING;
            fighting = true;
        } else {
            // AT the site: stand still and build. Only the FIRST boid to
            // touch the site flips the built flag (atomicExchange); the rest
            // just mill around it. The CPU picks up the flag change to grow
            // the real mesh.
            accel.xz = vec2(0.0);
            vel.xz = vec2(0.0);
            building_now = true;
            state |= STATE_BUILDING;
            if (atomicExchange(cell_info.cells[cell_index_2d(0, site_cell, dims)].building,
                               site_packed | BUILDING_BUILT_BIT) != (site_packed | BUILDING_BUILT_BIT)) {
                // We were the one who set it - stay planted this frame.
                building_now = true;
            }
        }
    } else {
        state &= ~STATE_BUILDING;
    }

    // 1. If boid has no path assigned, look at its current hex for team paths.
    // Boids that just finished a fight re-claim their OLD path first: it was
    // stored at home_hex, so if we're back home and the path still lives
    // (not expired), re-assign the same slot instead of rolling a new one.
    if (assigned_hex == NO_PATH) {
        int my_hex = world_to_hex_id(pos);
        int target_hex = -1;

        int team_hex_idx = my_hex * 4 + my_team;
        if (global_paths.hex_paths[team_hex_idx].path_count > 0) {
            // Percentage gate: only a fraction of boids may claim paths on
            // this hex. chance <= 0 means unset -> everyone. hash() is stable
            // per boid id, so the same boids always follow (no flickering).
            float chance = global_paths.hex_paths[team_hex_idx].claim_chance;
            if (chance <= 0.0) chance = 1.0;
            if (hash(id * 77u + 13u) < chance) {
                target_hex = my_hex;
            }
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

    // 1b. Remember where we belong: idle boids home to their current hex;
    // pathed boids home to the hex the path was claimed from.
    if (assigned_hex != NO_PATH) {
        home_hex = int(assigned_hex);
    } else if (!fighting && home_hex < 0) {
        home_hex = original_hex_id;
    }

    // 2. If boid has an assigned path, follow its team's path. Skipped while
    // fighting (chase steering rules this frame) - the assignment survives
    // combat untouched and resumes on the first non-combat frame.
    if (assigned_hex != NO_PATH && !fighting) {
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
    // STAND AND FIGHT: kill horizontal velocity so the boid plants its feet
    // while in melee (vertical motion untouched - gravity still applies).
    if (stand_ground || building_now) {
        vel.xz = vec2(0.0);
    }
    // gravity
    vel.y -= 9.8 * pc.params.x;
    float max_speed = 8.0;
    if (length(vel) > max_speed) vel = normalize(vel) * max_speed;
    pos += vel * pc.params.x;

    // NaN safety net: if anything above produced NaN (shouldn't anymore,
    // but a single poisoned boid used to crash the whole sim), reset that
    // boid instead of letting the corruption spread through flocking.
    if (isnan(pos.x) || isnan(pos.y) || isnan(pos.z) ||
        isnan(vel.x) || isnan(vel.y) || isnan(vel.z)) {
        pos = original_pos;
        vel = vec3(0.0);
        state &= ~STATE_FIGHTING;
    }

    // clamp to world bounds
    vec3 wmin = pc.world_min.xyz;
    vec3 wmax = wmin + vec3(dims.x, 100.0, dims.z) * cell_size;
    pos = clamp(pos, wmin, wmax);

    // HARD hex boundary: if the boid left its hex and has no path AND isn't
    // fighting, snap back. Fighting boids may cross hexes in pursuit.
    int new_hex_id = world_to_hex_id(pos);
    bool hex_free = (state & (STATE_HAS_PATH | STATE_FIGHTING)) != 0u;
    if (new_hex_id != original_hex_id && !hex_free) {
        pos.xz = original_pos.xz;
        vel.xz = vec2(0.0);  // dampen on bounce
    }

    write_s.boids[id].pos = vec4(pos, float(my_team));
    write_s.boids[id].vel = vec4(vel, 0.0);
    write_s.boids[id].state = state;
    write_s.boids[id].assigned_path_hex = assigned_hex;
    write_s.boids[id].assigned_path_slot = assigned_slot;
    write_s.boids[id].team = uint(my_team);
    write_s.boids[id].home_hex = home_hex;

    // TAKE DAMAGE: consume LAST frame's accumulated damage from the read
    // side (attackers this frame write to the write side, which becomes
    // next frame's read side). The victim is the sole writer of its own
    // health - no cross-thread health writes anywhere.
    uint current_health = read_s.boids[id].health;
    uint incoming = dmg_read.dmg[id];
    if (incoming > 0u) {
        if (current_health <= incoming) {
            current_health = 0u;
        } else {
            current_health -= incoming;
        }
    }
    write_s.boids[id].health = current_health;
}
