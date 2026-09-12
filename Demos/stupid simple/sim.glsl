#[compute]
#version 450

#define STATE_ALIVE  0x00000001u
#define STATE_DEAD   0x00000002u
#define STATE_HAS_PATH 0x00000004u
#define STATE_FIGHTING 0x00000008u
#define STATE_BUILDING 0x00000010u
#define STATE_FALLING 0x00000020u
#define STATE_CHARGING 0x00000040u  // dying dot about to explode (fuse running)
#define NO_PATH 0xFFFFFFFFu

// Building ids - must match stupid_simple.gd / hex_building_manager.gd
#define BUILDING_BARRACK 0u
#define BUILDING_MINE    1u
#define BUILDING_WALL    2u

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
// Build progress lives in the packed building word's SPARE bits (16-30 -
// the old sub-hex fields, unused since buildings became whole-hex): a
// 15-bit counter of builder-frames accumulated on the site. 15 bits is
// what lets walls take 10x the work of other buildings (600 > 255, the
// old byte-wide counter would have overflowed into neighboring fields).
// Bit 31 stays the BUILT flag; overflow past 32767 is impossible (the
// counter flips the built flag long before that).
#define BUILD_PROGRESS_SHIFT 16u
#define BUILD_PROGRESS_MASK 0x7FFF0000u
#define BUILD_WORK 200u        // builder-frames for most buildings (~3.3s, 1 builder)
#define WALL_BUILD_WORK 600u   // walls take ~10s for a single builder (60fps)

uint cell_building_id(uint packed_info)  { return packed_info & 0xFFu; }
uint cell_building_team(uint packed_info){ return (packed_info >> 8u) & 0xFFu; }
int  cell_building_sub_q(uint packed_info) { return int((packed_info >> 16u) & 0xFFu) - 3; }
int  cell_building_sub_r(uint packed_info) { return int((packed_info >> 24u) & 0x7Fu) - 3; }
bool cell_building_is_built(uint packed_info) { return (packed_info & BUILDING_BUILT_BIT) != 0u; }

// Grid-cell scan radius for building detection / capture / construction
// (5x5 cell block). File scope: the mine-capture block runs before main()'s
// building scans and shares the same radius.
const int BUILD_SCAN = 2;

struct Path {
    vec2 points[16];
    int count;
    // Elapsed-sim-time deadline after which NEW boids can't claim this path
    // (boids already following it finish regardless). Written by the CPU at
    // byte offset 132 of the 136-byte Path record. <= 0 = never expires.
    float expiry;
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

// Per-team economy, CPU-managed: [t*2+0] = resources, [t*2+1] = starve flag
// (1 = the team couldn't pay upkeep - its boids slowly lose health).
layout(set=0, binding=9, std430) buffer EconResBuf { uint econ_res[]; } econ_res;

// Per grid cell (xz, no team slices): 1 = the ground tile here collapsed
// (a depleted mine) - boids standing on it fall and die.
layout(set=0, binding=10, std430) buffer CollapseBuf { uint flags[]; } collapse_buf;

// DEATH EXPLOSIONS, GPU-only. Two phases share one buffer:
//
// 1. CHARGE: a boid that dies with the explode roll gets STATE_CHARGING
//    and a ~1s fuse stored in assigned_path_slot (as a sim-time deadline,
//    same trick as the wall cooldown). render.glsl strobes it white so
//    everyone can see it; nearby boids read the flag and RUN AWAY.
//
// 2. BLAST: when the fuse hits zero the boid writes vec4(xyz = blast
//    world pos, w = sim time of the blast) into its per-id slot and dies.
//    NEXT frame every boid scans the slot list; any blast younger than
//    BLAST_TTL within BLAST_RADIUS adds a strong outward impulse to its
//    velocity - units get sent flying. The one-frame latency is what makes
//    the impulse readable by everyone (dispatch barrier). Timestamps age
//    out, so the list never needs clearing.
#define EXPLODE_SLOTS 128u
#define BLAST_RADIUS 25.0
#define BLAST_TTL 0.4

// (file & rank formations replaced by nearest-segment path flow - rigid
// slots self-jammed when hundreds of boids claimed one path)

layout(set=0, binding=11, std430) buffer ExplodeBuf {
    vec4 data[128];   // xyz = blast position, w = sim time of the blast
    uint count;       // unused (kept for buffer layout) - scans filter by age
} explode_buf;

layout(push_constant) uniform PC {
    // grid_dims.w = num_teams - every team-indexed buffer/loop keys off it.
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
    int num_teams = (pc.grid_dims.w > 0) ? pc.grid_dims.w : 4;
    int my_team = int(read_s.boids[id].team) % num_teams;
    // NPC horde = the LAST team index. Its boids are deserters: hex-free,
    // hostile to everyone, wandering the whole map, capturing nothing and
    // paying no upkeep (the CPU skips them). Player teams are 0..num_teams-2.
    int npc_team = num_teams - 1;
    bool is_npc = (my_team == npc_team);
    int original_hex_id = world_to_hex_id(pos);
    uint state = read_s.boids[id].state;
    uint assigned_hex = read_s.boids[id].assigned_path_hex;
    uint assigned_slot = read_s.boids[id].assigned_path_slot;
    int home_hex = read_s.boids[id].home_hex;
    bool was_fighting = (state & STATE_FIGHTING) != 0u;
    bool had_path_before = assigned_hex != NO_PATH;

    // Wall-grind tracker packed into vel.w (unused by every other shader):
    // low 4 bits = consecutive bump count, upper bits = last bumped wall's
    // cell index. The counter only resets when a DIFFERENT wall is hit or
    // after giving up - the bounce arc (pushed out, steering back in) spans
    // several clean frames, so a plain per-frame reset would never reach 10.
    uint bump_packed = floatBitsToUint(read_s.boids[id].vel.w);
    uint wall_bumps = bump_packed & 0xFu;
    uint last_wall = bump_packed >> 4;

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

    // --- CHARGING EARLY-OUT ---
    // A dot with a lit fuse does nothing but slide (momentum from whoever
    // shoved it), tick, and detonate. No combat, no capture, no building,
    // no pathing - and no hex clamp (the panic shove may throw it across
    // a boundary; the blast is what matters now).
    if ((state & STATE_CHARGING) != 0u) {
        vel.xz *= max(0.0, 1.0 - 2.0 * pc.params.x);  // ground friction
        vel.y -= 9.8 * pc.params.x;
        pos += vel * pc.params.x;
        if (pc.params.w >= float(assigned_slot)) {
            // DETONATE: timestamped blast in this boid's dedicated slot;
            // everyone scans the slot list next frame (see buffer comment).
            explode_buf.data[id % EXPLODE_SLOTS] = vec4(pos, pc.params.w);
            write_s.boids[id].pos = vec4(pos, float(my_team));
            write_s.boids[id].vel = vec4(0.0);
            write_s.boids[id].state = STATE_ALIVE;
            write_s.boids[id].assigned_path_hex = NO_PATH;
            write_s.boids[id].assigned_path_slot = 0u;
            write_s.boids[id].team = uint(my_team);
            write_s.boids[id].home_hex = home_hex;
            write_s.boids[id].health = 0u;  // gone at the end of the fuse
            return;
        }
        // Fuse still burning: stay at 1 HP so only the fuse can end it.
        write_s.boids[id].pos = vec4(pos, float(my_team));
        write_s.boids[id].vel = vec4(vel, 0.0);
        write_s.boids[id].state = state | STATE_CHARGING;
        write_s.boids[id].assigned_path_hex = NO_PATH;
        write_s.boids[id].assigned_path_slot = assigned_slot;  // the fuse
        write_s.boids[id].team = uint(my_team);
        write_s.boids[id].home_hex = home_hex;
        write_s.boids[id].health = 1u;
        return;
    }

    // --- MINE CAPTURE: standing on an enemy-built mine flips it to us.
    // NPC deserters never capture - they only wreck, they don't hold.
    // HEX-WIDE test: the mine's word lives only in the hex's CENTER grid
    // cell, and the old exact-cell check meant the ~90% of the hexagon
    // around that cell never captured (dots wander the whole hex, and the
    // capture only fired if they happened to stand in that one 5x5-unit
    // cell). Every cell_info entry carries the hex id of the hex it belongs
    // to, so scanning the 5x5 ring for a built mine whose hex id matches
    // OUR hex lets any dot anywhere on the mine's hexagon capture it -
    // while dots on neighboring hexes still can't (different hex id). ---
    if (!is_npc) {
        for (int cdx = -BUILD_SCAN; cdx <= BUILD_SCAN; cdx++) {
            for (int cdz = -BUILD_SCAN; cdz <= BUILD_SCAN; cdz++) {
                ivec3 cc = my_cell + ivec3(cdx, 0, cdz);
                if (cc.x < 0 || cc.x >= dims.x || cc.z < 0 || cc.z >= dims.z) continue;
                uint ci_cap = cell_index_2d(0, cc, dims);
                uint packed_m = cell_info.cells[ci_cap].building;
                if (cell_building_id(packed_m) != BUILDING_MINE) continue;
                if (!cell_building_is_built(packed_m)) continue;
                // Same hexagon only (cell_info stores each cell's hex id).
                if (cell_info.cells[ci_cap].hex_id != uint(original_hex_id)) continue;
                // Re-check under the atomic: the owner may have changed
                // since the read (another team's boid captured this frame).
                uint packed_now = cell_info.cells[ci_cap].building;
                if (cell_building_team(packed_now) != uint(my_team)) {
                    uint captured = (packed_now & ~(0xFFu << 8u)) | ((uint(my_team) & 0xFFu) << 8u);
                    atomicExchange(cell_info.cells[ci_cap].building, captured);
                }
            }
        }
    }

    // --- TILE COLLAPSE: the ground in this hex is gone - fall and die ---
    // Flag is indexed by HEX id, not grid cell: one hex spans several grid
    // cells, so this catches every dot anywhere on the hexagon - including
    // ones that wander onto the hole after the collapse.
    bool falling = (state & STATE_FALLING) != 0u;
    if (!falling) {
        if (collapse_buf.flags[original_hex_id] != 0u) {
            falling = true;
            state = (state & ~uint(STATE_HAS_PATH)) | STATE_FALLING;
            assigned_hex = NO_PATH;  // a path over a collapsed hole is dead
            vel = vec3(0.0, -1.0, 0.0);
        }
    }
    if (falling) {
        // Pure ballistic fall: no flocking, no combat, no pathing. Once the
        // boid drops below the world floor it dies (render culls health==0).
        vel.y -= 9.8 * pc.params.x;
        pos += vel * pc.params.x;
        uint hp = read_s.boids[id].health;
        if (pos.y < pc.world_min.y - 2.0) hp = 0u;
        write_s.boids[id].pos = vec4(pos, float(my_team));
        write_s.boids[id].vel = vec4(vel, 0.0);
        write_s.boids[id].state = state;
        write_s.boids[id].assigned_path_hex = assigned_hex;
        write_s.boids[id].assigned_path_slot = assigned_slot;
        write_s.boids[id].team = uint(my_team);
        write_s.boids[id].home_hex = home_hex;
        write_s.boids[id].health = hp;
        return;
    }

    // --- CHARGING NEIGHBORS FLEE ---
    // Scan a small ring of the blast-slot list for young, nearby blasts?
    // No - charging is per-boid state, so flee logic uses the same sampled
    // neighbor loop data: nothing to scan here. Instead, when computing the
    // flocking neighbors below we note their charge state and add a strong
    // flee force away from any CHARGING dot (runs away BEFORE the blast).

    // Per-boid random offsets — each boid gets slightly different forces
    // even when neighbors are identical, breaking grid lockstep.
    float rx = hash(id * 3u + 0u) * 2.0 - 1.0;
    float ry = hash(id * 3u + 1u) * 2.0 - 1.0;
    float rz = hash(id * 3u + 2u) * 2.0 - 1.0;

    vec3 sep = vec3(0.0), align = vec3(0.0), coh = vec3(0.0);
    vec3 boid_sep = vec3(0.0);  // hard near-field separation (anti-jam)
    vec3 flee_dir = vec3(0.0);   // sum of away-from-charging-dot directions
    bool fleeing = false;        // true while a charging dot is in sight
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
                // Extra-short-range repulsion: inside ~half a cell the
                // soft term is far too weak, and packed marching columns
                // used to jam into overlapping clumps that behaved like
                // solid obstacles for everyone behind them.
                if (d < cell_size * 0.45) {
                    boid_sep += (pos - other_pos) / max(d * d, 0.01);
                }
                align += read_s.boids[other_id].vel.xyz;
                coh += other_pos;
                neighbors++;
                // A dot about to EXPLODE terrifies everyone in perception
                // range: add a hard flee component away from it (any team -
                // enemies flee too, this overrides the combat stand-ground
                // below via a flag).
                if ((read_s.boids[other_id].state & STATE_CHARGING) != 0u) {
                    flee_dir += (pos - other_pos) / d;
                    fleeing = true;
                }
            }
        }
    }

    vec3 accel = vec3(0.0);
    if (neighbors > 0) {
        align /= float(neighbors);
        coh = (coh / float(neighbors)) - pos;
        // Separation doubled (was 4.0): converging columns need real
        // push-back or they compress into a plug nothing can pass through.
        accel = sep * 9.0 + align * 1.0 + coh * 1.5;
    }
    // Near-field separation applies even with zero flocking neighbors.
    accel += boid_sep;

    // Add per-boid wander force to break grid symmetry
    accel += vec3(rx, ry * 0.3, rz) * 1.5;

    // NPC deserters ROAM THE MAP: a strong per-boid heading that re-rolls
    // (per boid) every ~7 s, layered on top of regular flocking. Combined
    // with the hex-free boundary below this makes the horde drift all over
    // the battlefield and pick fights with whoever it bumps into.
    if (is_npc) {
        float heading = hash(id * 91u + uint(pc.params.w / 7.0)) * 6.2831853;
        accel.xz += vec2(cos(heading), sin(heading)) * 5.0;
    }

    // --- ENEMY COMBAT & REPULSION ---
    int nearby_enemies = 0;
    vec3 closest_enemy_pos = vec3(1000000.0);
    uint closest_enemy_id = id;  // id means "no target"
    float closest_enemy_d = 1e10;

    for (int t = 0; t < num_teams; t++) {
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
                // Charging dots are terrifying regardless of team: an ENEMY
                // about to blow also triggers the flee response (the own-team
                // flocking loop already covers friendly chargers).
                if (d < perception && (read_s.boids[other_id].state & STATE_CHARGING) != 0u) {
                    flee_dir += (pos - other_pos) / max(d, 0.001);
                    fleeing = true;
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
    if (nearby_enemies > 0 && !fleeing) {
        // STAND AND FIGHT: a target is in melee range, so stop moving
        // entirely - no chase force, and the flocking/wander accel gathered
        // above is discarded so boids don't spread out while trading blows.
        // They hold their ground (gravity still settles them on Y) until
        // the target dies or breaks away.
        // (Skipped while fleeing a charging dot: survival beats fighting.)
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

    // FLEE overrides everything (except the blast itself): a strong,
    // un-normalized sum so several charging dots push harder than one.
    if (fleeing) {
        accel += normalize(flee_dir) * 12.0;
        state |= STATE_FIGHTING;  // hex-free while panicking
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
    // BUILD_SCAN (file scope, near the CellInfo helpers) sets the ring size.
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
            if (bteam == 0xFFu) continue;  // terrain wall (scenery) - blocks movement, never an objective
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
                // Empty cells are 0x000000FF (id byte 0xFF, team byte 0),
                // NOT 0xFFFFFFFF - checking only the id byte is the fix for
                // team 0's dots marching outward: the old exact-word check
                // let 0x000000FF fall through, which decoded as "unbuilt
                // building owned by team 0" in every empty cell, so the
                // whole red army constantly marched to phantom sites (and
                // crossed hexes doing it). Non-team-0 boids were immune:
                // their team byte never matched 0.
                if (cell_building_id(packed_b) == 0xFFu) continue;  // empty cell
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
    if (has_site && assigned_hex == NO_PATH && !fleeing) {
        // Pathed boids keep marching (the path outranks building); only
        // idle boids break off to construct. With the old rule every
        // pathed boid passing within 2 cells of a site detoured into it
        // and stood there - the bulk of a marching column froze mid-way.
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
            // AT the site: stand still and BUILD. Progress accumulates in
            // the packed building word (bits 16-30): every builder on the
            // site adds one unit per frame via atomicAdd, so crowds build
            // faster. Walls need WALL_BUILD_WORK (~10s for one builder).
            // The builder whose add crosses the target flips the built
            // flag - the CPU poll then swaps the ghost mesh for the real
            // building.
            accel.xz = vec2(0.0);
            vel.xz = vec2(0.0);
            building_now = true;
            state |= STATE_BUILDING;
            uint work_needed = (cell_building_id(site_packed) == BUILDING_WALL)
                ? WALL_BUILD_WORK : BUILD_WORK;
            uint old_packed = atomicAdd(cell_info.cells[cell_index_2d(0, site_cell, dims)].building,
                                        1u << BUILD_PROGRESS_SHIFT);
            uint prog = ((old_packed >> BUILD_PROGRESS_SHIFT) & 0x7FFFu) + 1u;
            if (prog >= work_needed) {
                // We pushed progress to full - flip built (idempotent; also
                // clamps any overflow garbage back out of the progress field).
                uint done = (site_packed & ~BUILD_PROGRESS_MASK) | BUILDING_BUILT_BIT;
                if ((site_packed & 0xFFu) == BUILDING_MINE) {
                    // Finished mines go NEUTRAL (team byte 0xFF): nobody owns
                    // a mine for free just for placing it - it must be
                    // CAPTURED by a dot standing on it (capture block above).
                    done = (done & ~(0xFFu << 8u)) | (0xFFu << 8u);
                }
                atomicExchange(cell_info.cells[cell_index_2d(0, site_cell, dims)].building, done);
            }
        }
    } else {
        state &= ~STATE_BUILDING;
    }

    // 1. If boid has no path assigned, look at its current hex for team paths.
    // Boids that just finished a fight re-claim their OLD path first: it was
    // stored at home_hex, so if we're back home and the path still lives
    // (not expired), re-assign the same slot instead of rolling a new one.
    //
    // WALL-BOUNCE COOLDOWN: after being pushed back by a wall the boid must
    // settle in its own hex instead of instantly re-claiming the blocked
    // path (it would grind against the wall forever). While cooling down,
    // assigned_slot holds a sim-time deadline (>= 10; real slots are 0..9);
    // once pc.params.w passes it, claiming works normally again.
    bool wall_cooldown = false;
    if (assigned_slot >= 10u) {
        if (pc.params.w < float(assigned_slot)) {
            wall_cooldown = true;     // still cooling down - no claiming
            assigned_hex = NO_PATH;
        } else {
            assigned_slot = 0u;       // cooldown over - back to normal
        }
    }
    if (assigned_hex == NO_PATH && !wall_cooldown) {
        int my_hex = world_to_hex_id(pos);
        int target_hex = -1;

        int team_hex_idx = my_hex * num_teams + my_team;
        if (global_paths.hex_paths[team_hex_idx].path_count > 0) {
            // Percentage gate: only a fraction of boids may claim paths on
            // this hex. chance <= 0 means unset -> everyone. hash() is stable
            // per boid id, so the same boids always follow (no flickering).
            float chance = global_paths.hex_paths[team_hex_idx].claim_chance;
            if (chance <= 0.0) chance = 1.0;
            // Gate is stable per PATH DRAW (boid id + start hex + path
            // count): the chosen subset follows without flickering, each
            // new draw picks a fresh subset, and a boid excluded from one
            // path can still be picked by the next. The old id-only hash
            // locked the same boids out of EVERY path forever.
            float gate = hash(id * 77u + uint(my_hex) * 131u
                              + uint(global_paths.hex_paths[team_hex_idx].path_count) * 977u);
            if (gate < chance) {
                target_hex = my_hex;
            }
        }
        if (target_hex >= 0) {
            int t_hex_idx = target_hex * num_teams + my_team;
            int total_paths = global_paths.hex_paths[t_hex_idx].path_count;

            int active_count = min(total_paths, 10);
            // SHORT-LIVED PATHS: skip expired paths - a fresh claim can only
            // pick a path whose expiry hasn't passed. Boids ALREADY following
            // a path are unaffected (checked once at claim time).
            uint chosen = uint(active_count);
            for (int cand = 0; cand < active_count; cand++) {
                uint slot_c = uint((id + cand) % active_count);
                if (global_paths.hex_paths[t_hex_idx].paths[slot_c].count <= 0) continue;
                float exp = global_paths.hex_paths[t_hex_idx].paths[slot_c].expiry;
                if (exp > 0.0 && pc.params.w > exp) continue;  // expired
                chosen = slot_c;
                break;
            }
            if (chosen < uint(active_count)
                && global_paths.hex_paths[t_hex_idx].paths[chosen].count > 0) {
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
        int t_hex_idx = int(assigned_hex) * num_teams + my_team;
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
            // --- PATH FLOW (replaces the rigid file & rank grid) ---
            // March along the path polyline itself instead of converging
            // on one anchored slot grid. The rigid grid self-jammed: every
            // follower steered at the SAME block around the objective, so
            // boids on the far side of the crowd ground against the packed
            // mass forever and the column looked stuck half-way.
            vec2 final_pt = global_paths.hex_paths[t_hex_idx].paths[assigned_slot].points[p_count - 1];

            // ARRIVAL: reached the objective - release the assignment. The
            // boid goes idle (hex-bound where it stands) and drops out of
            // the follower count, so a fully-arrived path can expire and
            // its visual can be cleaned up. The old formation hold kept
            // the assignment forever, pinning followers > 0 permanently.
            if (length(pos.xz - final_pt) < 0.8) {
                assigned_hex = NO_PATH;
                assigned_slot = 0u;
                state = STATE_ALIVE;
                // Adopt the arrival hex as home so the post-fight "return
                // home" walk brings the boid back HERE, not to the hex it
                // was drawn from.
                home_hex = original_hex_id;
            } else {

            // Nearest point on the polyline (16 pts, linear scan).
            vec2 pxz = pos.xz;
            float best_d2 = 1e30;
            vec2 best_pt = global_paths.hex_paths[t_hex_idx].paths[assigned_slot].points[0];
            int best_seg = 0;
            for (int pi = 0; pi < p_count - 1; pi++) {
                vec2 a = global_paths.hex_paths[t_hex_idx].paths[assigned_slot].points[pi];
                vec2 b = global_paths.hex_paths[t_hex_idx].paths[assigned_slot].points[pi + 1];
                vec2 ab = b - a;
                float ab2 = dot(ab, ab);
                float u = (ab2 > 0.000001) ? clamp(dot(pxz - a, ab) / ab2, 0.0, 1.0) : 0.0;
                vec2 q = a + ab * u;
                float d2 = dot(pxz - q, pxz - q);
                if (d2 < best_d2) {
                    best_d2 = d2;
                    best_pt = q;
                    best_seg = pi;
                }
            }

            float d = sqrt(best_d2);
            if (d > 2.5) {
                // Off the path: cut back to the nearest segment first -
                // this makes the column FLOW along the drawn route instead
                // of every boid cutting a straight line to the endpoint
                // and wedging into chokepoints.
                vec3 to_seg = vec3(best_pt.x - pxz.x, 0.0, best_pt.y - pxz.y);
                accel += normalize(to_seg) * 8.0;
            } else {
                // On the path: look ahead along the route and follow the
                // corridor. Aim point = nearest point + lookahead along
                // the path direction; the goal-seek toward the final point
                // keeps the column converging on the objective.
                vec2 seg_dir = global_paths.hex_paths[t_hex_idx].paths[assigned_slot].points[min(best_seg + 1, p_count - 1)]
                             - global_paths.hex_paths[t_hex_idx].paths[assigned_slot].points[best_seg];
                float sl = length(seg_dir);
                if (sl < 0.001) seg_dir = vec2(0.0, 1.0); else seg_dir /= sl;
                vec2 aim = best_pt + seg_dir * 6.0;
                // On the last segment, aim at the endpoint itself so the
                // army gathers AT the objective instead of orbiting past it.
                if (best_seg >= p_count - 2) aim = final_pt;
                vec2 to_aim = aim - pxz;
                if (length(to_aim) > 0.5) {
                    accel += normalize(vec3(to_aim.x, 0.0, to_aim.y)) * 8.0;
                }
                // Goal-seek only when close to the objective (was applied
                // from anywhere - it dragged boids off the route into walls
                // of bodies at the endpoint).
                float end_d = length(pxz - final_pt);
                if (end_d < 12.0 && end_d > 0.5) {
                    accel += normalize(vec3(final_pt.x - pxz.x, 0.0, final_pt.y - pxz.y)) * 4.0;
                }
            }
            state = STATE_HAS_PATH;
            }  // end not-arrived
        }
    }

    // Steering, not raw force: accel is a TARGET VELOCITY offset, not an
    // impulse. Raw forces used to wind the velocity up to max_speed and keep
    // it there after the steering stopped - boids would fly off outward and
    // never stop. Steering velocity always decays back toward accel/DRAG.
    vel.xz += (accel.xz - vel.xz) * min(6.0 * pc.params.x, 1.0);
    vel.y += accel.y * pc.params.x;
    // STAND AND FIGHT: kill horizontal velocity so the boid plants its feet
    // while in melee (vertical motion untouched - gravity still applies).
    if (stand_ground || building_now) {
        vel.xz = vec2(0.0);
    }
    // gravity
    vel.y -= 9.8 * pc.params.x;
    // Cap the HORIZONTAL speed: with drag-based steering the XZ plan is
    // where runaway motion lived. Y stays gravity-driven (falls, settling).
    float max_speed = 8.0;
    float hspeed = length(vel.xz);
    if (hspeed > max_speed) vel.xz *= max_speed / hspeed;
    if (vel.y < -30.0) vel.y = -30.0;
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
    // fighting, snap back. Fighting boids may cross hexes in pursuit - and
    // so may NPC deserters, who roam freely.
    int new_hex_id = world_to_hex_id(pos);
    bool hex_free = (state & (STATE_HAS_PATH | STATE_FIGHTING)) != 0u || is_npc;
    if (new_hex_id != original_hex_id && !hex_free) {
        pos.xz = original_pos.xz;
        vel.xz = vec2(0.0);  // dampen on bounce
    }

    // --- WALLS BLOCK BOIDS (bump-then-give-up) ---
    // A BUILT wall building occupies its grid cell. A boid entering that
    // cell is pushed back and BOUNCES (into-wall velocity reflected at 40%,
    // the other axis keeps sliding) but KEEPS its path - it keeps trying to
    // push through, visibly bumping. After WALL_BUMP_LIMIT consecutive
    // bumps against the SAME wall cell it gives up: drops the path (with a
    // re-claim cooldown) and settles in its own hex.
    const uint WALL_BUMP_LIMIT = 10u;
    int wall_ci = -1;
    {
        // Test the cell we moved INTO (not the one we left): a wall only
        // occupies 1-2 grid cells inside a hex, so a boid can walk straight
        // across it without ever changing hex. The old hex-change requirement
        // let boids ghost through walls most of the time.
        int wcx = clamp(int(floor((pos.x - pc.world_min.x) / cell_size)), 0, dims.x - 1);
        int wcz = clamp(int(floor((pos.z - pc.world_min.z) / cell_size)), 0, dims.z - 1);
        uint wci = cell_index_2d(0, ivec3(wcx, 0, wcz), dims);
        uint packed_w = cell_info.cells[wci].building;
        if (cell_building_id(packed_w) == BUILDING_WALL
            && cell_building_is_built(packed_w)
            && int(cell_building_team(packed_w)) != my_team) {
            wall_ci = int(wci);
        }
    }
    if (wall_ci >= 0) {
        uint widx = uint(wall_ci) & 0x0FFFFFFFu;
        if (widx != last_wall) {
            wall_bumps = 1u;      // a different wall: fresh count
            last_wall = widx;
        } else {
            wall_bumps++;
        }
        // Entry direction must be read BEFORE the position is rolled back.
        vec2 entry = pos.xz - original_pos.xz;
        // Push back to the pre-move position (both branches).
        pos.xz = original_pos.xz;
        if (wall_bumps >= WALL_BUMP_LIMIT) {
            // GIVE UP: drop the path and clear every special state so the
            // boid goes back to plain ALIVE - hex-bound, wandering its own
            // hex (NOT the wall's hex) instead of grinding against the wall.
            wall_bumps = 0u;
            vel.xz = vec2(0.0);
            if (assigned_hex != NO_PATH && assigned_slot < 10u) {
                // Cooldown: assigned_slot temporarily stores a sim-time
                // deadline (>= 10, kept out of the 0..9 slot range) so the
                // boid doesn't instantly re-claim the same blocked path. It
                // lasts until the blocked path expires (or ~2s otherwise).
                float blocked_exp = global_paths.hex_paths[int(assigned_hex) * num_teams + my_team].paths[assigned_slot].expiry;
                uint cooldown = (blocked_exp > pc.params.w)
                    ? uint(blocked_exp) + 1u
                    : uint(pc.params.w) + 2u;
                if (cooldown < 10u) cooldown = 10u;
                assigned_slot = cooldown;
            }
            assigned_hex = NO_PATH;
            state = STATE_ALIVE;
            // Home is now the hex we're actually standing in - otherwise
            // the post-fight "return home" walk would drag us into the wall.
            home_hex = original_hex_id;
        } else {
            // BOUNCE: reflect the dominant entry axis (damped) so the bump
            // reads physically; the other axis keeps sliding, letting the
            // boid edge along the wall while it keeps trying to push in.
            // NOTE: entry is a vec2 packed as (dx, dz) - .y is the Z axis.
            if (abs(entry.x) > abs(entry.y)) {
                vel.x = -vel.x * 0.4;
            } else {
                vel.z = -vel.z * 0.4;
            }
        }
    }

    // --- STARVATION: when the CPU flags the team out of resources, every
    // boid bleeds ~2 HP/s (hash-staggered so the damage spreads across the
    // team instead of everyone taking it on the same frame). The CPU clears
    // the flag as soon as income covers upkeep again.
    uint starve_dmg = 0u;
    if (!is_npc && econ_res.econ_res[my_team * 3 + 1] != 0u) {
        if ((id + uint(pc.params.w * 60.0)) % 30u == 0u) starve_dmg = 1u;
    }

    // --- DESERTION: going broke doesn't kill the army instantly - boids
    // randomly defect to the NPC horde one at a time. Two triggers, same
    // mechanism: (a) the active starvation flag, or (b) the CPU writes the
    // team's resource DEFICIT as a float into econ_res[team*3+2]; the deeper
    // the debt, the higher each boid's per-frame conversion chance, so a
    // mildly broke team leaks units slowly and a drowning one collapses.
    // Conversion = reteam + full reset: drop path/state/home, keep position
    // and health. NPC boids never convert (they're already deserters).
    if (!is_npc
        && (econ_res.econ_res[my_team * 3 + 1] != 0u
            || econ_res.econ_res[my_team * 3 + 2] != 0u)) {
        float debt = uintBitsToFloat(econ_res.econ_res[my_team * 3 + 2]);
        // Rate arrives packed in the unused hex_grid.w push-constant slot
        // (float bits, set by the CPU) so it's tunable without recompiling.
        float deser_rate = intBitsToFloat(pc.hex_grid.w);
        if (deser_rate <= 0.0) deser_rate = 0.0000015;
        float p = (debt > 0.0) ? min(debt * deser_rate, 0.0005)
                               : 0.00002;  // starving but not in debt
        if (hash(id * 613u + uint(pc.params.w * 60.0)) < p) {
            my_team = npc_team;
            state = STATE_ALIVE;
            assigned_hex = NO_PATH;
            assigned_slot = 0u;
            home_hex = original_hex_id;
        }
    }

    write_s.boids[id].pos = vec4(pos, float(my_team));
    write_s.boids[id].vel = vec4(vel, uintBitsToFloat((last_wall << 4) | (wall_bumps & 0xFu)));
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
    uint incoming = dmg_read.dmg[id] + starve_dmg;
    if (incoming > 0u) {
        if (current_health <= incoming) {
            current_health = 0u;
        } else {
            current_health -= incoming;
        }
    }

    // --- BLAST IMPULSES: scan the explosion slot list for recent blasts.
    // A blast written LAST frame (or older, within BLAST_TTL) inside
    // BLAST_RADIUS hurls this boid outward. One-frame latency is intended:
    // the sim's dispatch barrier makes the new entries visible to every
    // boid exactly one dispatch after the dying boid wrote them.
    {
        for (uint s = 0u; s < EXPLODE_SLOTS; s++) {
            vec4 b = explode_buf.data[s];
            float age = pc.params.w - b.w;
            if (age < 0.0 || age > BLAST_TTL) continue;  // dead/unused slot
            vec3 to_me = pos - b.xyz;
            to_me.y *= 0.35;  // mostly a ground shockwave
            float bd = length(to_me);
            if (bd > BLAST_RADIUS || bd < 0.001) continue;
            // Falloff from full force at the epicenter to zero at the rim.
            float force = mix(30.0, 2.0, bd / BLAST_RADIUS);
            vel += (to_me / bd) * force;
            vel.y += length(to_me / bd) * force;
            // A blast hard enough to fling you also stings a little.
            current_health = (current_health > 40u) ? current_health - 40u : 0u;
        }
    }

    // --- DEATH EXPLOSION, two phases (see buffer comment at the top) ---
    // (The charging phases are handled by the early-out above; this only
    // converts a fresh death into a charging grenade.)
    if (current_health == 0u
        && hash(id * 911u + uint(pc.params.w * 60.0)) < 0.35) {
        state = (state & ~(STATE_FIGHTING | STATE_BUILDING)) | STATE_CHARGING;
        assigned_hex = NO_PATH;
        // Fuse deadline in sim seconds, stored in the slot field. Kept
        // >= 10 so it can't collide with the real 0..9 path slots (same
        // convention as the wall cooldown) - at 1s granularity that only
        // lengthens the fuse during the session's first 9 seconds.
        uint fuse = uint(pc.params.w) + 5u;      // ~1 second
        assigned_slot = (fuse < 10u) ? 10u : fuse;
        current_health = 1u;  // pinned alive until detonation
        // The normal write-out above already flushed the pre-conversion
        // fields - overwrite them with the charging state.
        write_s.boids[id].state = state;
        write_s.boids[id].assigned_path_hex = NO_PATH;
        write_s.boids[id].assigned_path_slot = assigned_slot;
    }

    write_s.boids[id].health = current_health;
}
