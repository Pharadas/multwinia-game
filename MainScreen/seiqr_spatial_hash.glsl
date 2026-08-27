#[compute]
#version 450
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// seiqr_spatial_hash.glsl
//
// The SEIIQR spatial hash, ported to a Godot compute shader. Every frame the
// swarm runs this 5-pass pipeline (mirroring the five kernels SEIIQR.cl
// launches per iteration):
//
//   pass 0  clear    zero the cell counters            (clear_buffer)
//   pass 1  count    each dot bumps its cell's counter (update_filled_cuadrants)
//   pass 2  prefix   single-thread scan -> offsets     (calcular_posiciones_de_cuadriculas)
//   pass 3  fill     dots append themselves to cells   (assign_agents_to_cuadrants)
//   pass 4  search   each dot scans the 3x3 cells around it and accumulates
//                    the count + crowd_center of dots within neighbor_radius
//                    (update_agent's sector search)
//
// The result is written to a per-dot texture: one rgba32f texel per particle
// holding (neighbor count, crowd_center.xyz). The particle shader in
// seiqr_swarm.gdshader samples that texture and reacts.
//
// The positions hashed are each dot's deterministic orbit SLOT (the same
// math as the particle shader, driven by objective + sim_time), not its live
// position - particle shaders can't expose their transforms to a buffer, so
// slots are the shared source of truth both shaders agree on.

// CPU-side params, rewritten fresh every frame (9 floats).
layout(set = 0, binding = 0, std430) restrict buffer Params {
	float ox;             // objective.x
	float oy;             // objective.y
	float oz;             // objective.z
	float pass;           // which pipeline stage: 0..4
	float neighbor_radius;
	float half_extent;    // grid half-extent in x and z, centered on the objective
	float grid_w;         // cells per side (cast to int)
	float dot_count;      // number of particles (cast to int)
	float sim_time;       // MUST equal the particle shader's sim_time uniform
} params;

layout(set = 0, binding = 1, std430) restrict buffer Counts {
	uint counts[];        // cell counts, then prefix offsets after pass 2
} counts_buf;

layout(set = 0, binding = 2, std430) restrict buffer Counters {
	uint counters[];      // running write index per cell during pass 3,
} counters_buf;           // then final per-cell counts for pass 4

layout(set = 0, binding = 3, std430) restrict buffer Lists {
	uint lists[];         // dot ids packed per cell, contiguous
} lists_buf;

// Per-dot result: one texel per dot, (neighbor count, crowd_center).
layout(set = 0, binding = 4, rgba32f) writeonly uniform image2D out_image;

const float TAU = 6.28318530718;

// ---- KEEP IN SYNC with seiqr_swarm.gdshader (same slot math) -------------
float hash11(float n) {
	return fract(sin(n * 127.1 + 311.7) * 43758.5453123);
}

float radius_of(int idx) {
	float r = hash11(float(idx) * 3.71 + 5.0);
	return r * r * 10.0; // SWARM_RADIUS
}

float phase_of(int idx) { return hash11(float(idx) * 11.03 + 3.0) * TAU; }
float speed_factor_of(int idx) { return 0.6 + hash11(float(idx) * 13.7 + 7.0) * 0.8; }
float bob_of(int idx) { return hash11(float(idx) * 17.3 + 21.0) * TAU; }
float height_of(int idx) { return (hash11(float(idx) * 5.93 + 9.0) - 0.5) * 3.0; } // CLOUD_HEIGHT

vec3 slot_of(int idx) {
	float ang = phase_of(idx) + params.sim_time * 0.9 * speed_factor_of(idx); // orbit_speed
	vec3 s = vec3(params.ox, 0.0, params.oz);
	s.x += cos(ang) * radius_of(idx);
	s.z += sin(ang) * radius_of(idx);
	s.y = height_of(idx) + sin(params.sim_time * 2.0 + bob_of(idx)) * 0.5;
	return s;
}
// --------------------------------------------------------------------------

// 2D grid cell (x, z) for a position, clamped into the grid.
ivec2 cell_of(vec3 pos) {
	float cell = (2.0 * params.half_extent) / params.grid_w;
	vec2 origin = vec2(params.ox - params.half_extent, params.oz - params.half_extent);
	ivec2 c = ivec2(floor((pos.xz - origin) / cell));
	int gw = int(params.grid_w);
	return clamp(c, ivec2(0), ivec2(gw - 1));
}

void main() {
	uint gid = gl_GlobalInvocationID.x;
	int gw = int(params.grid_w);
	int ncells = gw * gw;

	if (params.pass < 0.5) {
		// pass 0 - clear: reset the cell counts and counters.
		if (gid < uint(ncells)) {
			counts_buf.counts[gid] = 0u;
			counters_buf.counters[gid] = 0u;
		}
	} else if (params.pass < 1.5) {
		// pass 1 - count: one thread per dot bumps its cell's counter.
		if (gid < uint(params.dot_count)) {
			ivec2 c = cell_of(slot_of(int(gid)));
			atomicAdd(counts_buf.counts[c.y * gw + c.x], 1u);
		}
	} else if (params.pass < 2.5) {
		// pass 2 - prefix: single-thread running sum turns counts into
		// offsets, exactly like SEIIQR's single-threaded scan kernel.
		if (gid == 0u) {
			uint acc = 0u;
			for (int ci = 0; ci < ncells; ci++) {
				uint r = counts_buf.counts[ci];
				counts_buf.counts[ci] = acc;
				acc += r;
			}
		}
	} else if (params.pass < 3.5) {
		// pass 3 - fill: one thread per dot appends its id to its cell's
		// list. atomicAdd returns the old value, which gives us the write
		// slot directly - no semaphore needed (SEIIQR had to spinlock).
		if (gid < uint(params.dot_count)) {
			ivec2 c = cell_of(slot_of(int(gid)));
			uint cell = uint(c.y * gw + c.x);
			uint slot = atomicAdd(counters_buf.counters[cell], 1u);
			lists_buf.lists[counts_buf.counts[cell] + slot] = gid;
		}
	} else {
		// pass 4 - search: one thread per dot scans the 3x3 cells around
		// it (cells are exactly neighbor_radius wide, so that covers every
		// dot within radius) and accumulates count + crowd_center.
		if (gid < uint(params.dot_count)) {
			vec3 my_pos = slot_of(int(gid));
			ivec2 mc = cell_of(my_pos);
			float r2 = params.neighbor_radius * params.neighbor_radius;
			float n = 0.0;
			vec3 crowd_center = vec3(0.0);
			for (int dx = -1; dx <= 1; dx++) {
				for (int dy = -1; dy <= 1; dy++) {
					int cx = mc.x + dx;
					int cy = mc.y + dy;
					if (cx < 0 || cx >= gw || cy < 0 || cy >= gw) {
						continue;
					}
					uint cell = uint(cy * gw + cx);
					uint start = counts_buf.counts[cell];
					uint count = counters_buf.counters[cell];
					for (uint li = 0u; li < count; li++) {
						uint other = lists_buf.lists[start + li];
						if (other == gid) {
							continue;
						}
						vec3 op = slot_of(int(other));
						vec3 d = my_pos - op;
						if (dot(d, d) < r2) {
							n += 1.0;
							crowd_center += op;
						}
					}
				}
			}
			if (n > 0.0) {
				crowd_center /= n;
			}
			imageStore(out_image, ivec2(int(gid), 0), vec4(n, crowd_center));
		}
	}
}
