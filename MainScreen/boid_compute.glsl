#[compute]
#version 450
#extension GL_EXT_shader_atomic_float : enable
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// =============================================================================
// HEX GRID NAVIGATION WITH MULTI-POINT PATHS + LIQUID PHYSICS
//
// Dots always exist on hex grid positions. Each dot has a path (array of hex
// IDs) and remembers where it's going. The hex grid provides navigation, and
// pressure-based liquid physics prevents stacking.
// =============================================================================

// ---- buffers ----------------------------------------------------------------

layout(set = 0, binding = 0, std430) restrict buffer DotWorldPosition {
    // xyz = world position (always on hex grid)
    // w   = current hex ID
    vec4 data[];
} dot_world_position_buf;

layout(set = 0, binding = 1, std430) restrict buffer DotVelocity {
    vec4 data[];
} dot_velocity_buf;

layout(set = 0, binding = 2, std430) restrict buffer DotPath {
	// Array of hex IDs forming the dot's complete journey
	// Max 16 waypoints per dot
	int data[];
} dot_path_buf;

layout(set = 0, binding = 3, std430) restrict buffer DotPathState {
	// x = current waypoint index in path
	// y = path length (total waypoints)
	// z = team ID
	// w = action state (0=hold, 1=move, 2=aggressive)
	vec4 data[];
} dot_path_state_buf;

layout(set = 0, binding = 4, std430) restrict buffer DensityField {
	float data[];
} density_field_buf;

layout(set = 0, binding = 5, std430) restrict buffer PressureField {
	vec4 data[]; // xy = gradient
} pressure_field_buf;

layout(set = 0, binding = 6, std430) restrict buffer HexWorldPosition {
	vec4 data[];
} hex_world_position_buf;

layout(set = 0, binding = 7, std430) restrict buffer HexAdjacency {
	// 32 neighbors per hex
	int data[];
} hex_adjacency_buf;

layout(set = 0, binding = 8, std430) restrict buffer Params {
	float dot_count;
	float hex_count;
	float pass_id;
	float update_start;
	float update_count;
	float delta_time;
	float hex_radius;
} params;

// ---- constants --------------------------------------------------------------

const int MAX_PATH_LENGTH = 16;
const float DOT_MOVE_SPEED = 2.0;
const float AGGRESSIVE_SPEED_MULTIPLIER = 1.8;
const float ARRIVAL_THRESHOLD = 0.5;
const float PRESSURE_REPULSION_STRENGTH = 2.5;
const float PRESSURE_SMOOTHING = 0.5;

// ---- helpers ----------------------------------------------------------------

float pseudo_random(float seed) {
	return fract(sin(seed * 127.1 + 311.7) * 43758.5453123);
}

// Find which adjacent hex is closest to target
int find_next_hex_toward_target(int current_hex_id, int target_hex_id) {
	if (current_hex_id == target_hex_id) return current_hex_id;
	
	vec3 current_pos = hex_world_position_buf.data[current_hex_id].xyz;
	vec3 target_pos = hex_world_position_buf.data[target_hex_id].xyz;
	vec3 direction = target_pos - current_pos;
	
	int best_neighbor = current_hex_id;
	float best_distance = length(direction);
	
	for (int slot = 0; slot < 32; slot++) {
		int neighbor_id = hex_adjacency_buf.data[current_hex_id * 32 + slot];
		if (neighbor_id < 0) continue;
		
		vec3 neighbor_pos = hex_world_position_buf.data[neighbor_id].xyz;
		vec3 to_neighbor = neighbor_pos - current_pos;
		
		// Check if this neighbor is in the right direction
		float alignment = dot(normalize(to_neighbor), normalize(direction));
		if (alignment > 0.3) { // Must be somewhat toward target
			float dist_to_target = distance(neighbor_pos, target_pos);
			if (dist_to_target < best_distance) {
				best_distance = dist_to_target;
				best_neighbor = neighbor_id;
			}
		}
	}
	
	return best_neighbor;
}

void main() {
// =============================================================================
// PASS 0: Clear density field
// =============================================================================
if (params.pass_id < 0.5) {
	int hex_id = int(gl_GlobalInvocationID.x);
	if (hex_id < int(params.hex_count)) {
		density_field_buf.data[hex_id] = 0.0;
	}

// =============================================================================
// PASS 1: Build density field
// =============================================================================
} else if (params.pass_id < 1.5) {
	uint thread_id = gl_GlobalInvocationID.x;
	if (thread_id >= uint(params.update_count)) return;
	int dot_id = int(thread_id + uint(params.update_start));
	if (dot_id >= int(params.dot_count)) return;
	
	int current_hex_id = int(dot_world_position_buf.data[dot_id].w);
	atomicAdd(density_field_buf.data[current_hex_id], 1.0);

// =============================================================================
// PASS 2: Compute pressure gradient
// =============================================================================
} else if (params.pass_id < 2.5) {
	int hex_id = int(gl_GlobalInvocationID.x);
	if (hex_id >= int(params.hex_count)) return;
	
	vec3 current_pos = hex_world_position_buf.data[hex_id].xyz;
	float current_density = density_field_buf.data[hex_id];
	
	vec2 gradient = vec2(0.0);
	float total_weight = 0.0;
	
	// Sample neighbors
	for (int slot = 0; slot < 32; slot++) {
		int neighbor_id = hex_adjacency_buf.data[hex_id * 32 + slot];
		if (neighbor_id < 0) continue;
		
		vec3 neighbor_pos = hex_world_position_buf.data[neighbor_id].xyz;
		vec2 direction = neighbor_pos.xz - current_pos.xz;
		float dist = length(direction);
		
		if (dist > 0.001) {
			float neighbor_density = density_field_buf.data[neighbor_id];
			float density_diff = neighbor_density - current_density;
			
			// Gradient points from low to high density
			gradient += normalize(direction) * density_diff;
			total_weight += 1.0;
		}
	}
	
	if (total_weight > 0.0) {
		gradient /= total_weight;
	}
	
	pressure_field_buf.data[hex_id] = vec4(gradient * PRESSURE_SMOOTHING, 0.0, 0.0);

// =============================================================================
// PASS 3: Move dots along their paths with liquid physics
// =============================================================================
} else if (params.pass_id < 3.5) {
	uint thread_id = gl_GlobalInvocationID.x;
	if (thread_id >= uint(params.update_count)) return;
	int dot_id = int(thread_id + uint(params.update_start));
	if (dot_id >= int(params.dot_count)) return;
	
	// --- Read dot state ---
	vec4 pos_data = dot_world_position_buf.data[dot_id];
	vec3 current_position = pos_data.xyz;
	int current_hex_id = int(pos_data.w);
	
	vec4 state_data = dot_path_state_buf.data[dot_id];
	int waypoint_index = int(state_data.x);
	int path_length = int(state_data.y);
	int team_id = int(state_data.z);
	int action_state = int(state_data.w);
	
	float move_speed = DOT_MOVE_SPEED;
	if (action_state == 2) move_speed *= AGGRESSIVE_SPEED_MULTIPLIER;
	
	vec3 hex_center = hex_world_position_buf.data[current_hex_id].xyz;
	vec3 new_position = current_position;
	new_position.x = hex_center.x;
	new_position.z = hex_center.z;
	int new_hex_id = current_hex_id;
	
	if (path_length > 0 && waypoint_index < path_length && action_state > 0) {
		int target_hex_id = dot_path_buf.data[dot_id * MAX_PATH_LENGTH + waypoint_index];
		vec3 target_pos = hex_world_position_buf.data[target_hex_id].xyz;
		float dist_to_target = distance(current_position.xz, target_pos.xz);
		
		if (dist_to_target < ARRIVAL_THRESHOLD) {
			waypoint_index++;
			state_data.x = float(waypoint_index);
			dot_path_state_buf.data[dot_id] = state_data;
			if (waypoint_index < path_length) {
				target_hex_id = dot_path_buf.data[dot_id * MAX_PATH_LENGTH + waypoint_index];
				target_pos = hex_world_position_buf.data[target_hex_id].xyz;
			}
		}
		
		if (waypoint_index < path_length) {
			int next_hex_id = find_next_hex_toward_target(current_hex_id, target_hex_id);
			vec3 next_hex_pos = hex_world_position_buf.data[next_hex_id].xyz;
			vec3 dir = next_hex_pos - current_position;
			dir.y = 0.0;
			float dist = length(dir);
			if (dist > 0.001) {
				float step = min(move_speed * params.delta_time, dist);
				new_position = current_position + (dir / dist) * step;
			}
		}
		
		// Pressure repulsion
		vec2 pressure_gradient = pressure_field_buf.data[current_hex_id].xy;
		new_position.x -= pressure_gradient.x * PRESSURE_REPULSION_STRENGTH;
		new_position.z -= pressure_gradient.y * PRESSURE_REPULSION_STRENGTH;
	}
	
	// Clamp to hex boundary (circle wall)
	vec2 offset = new_position.xz - hex_center.xz;
	float dist_from_center = length(offset);
	if (dist_from_center > params.hex_radius && dist_from_center > 0.001) {
		new_position.xz = hex_center.xz + (offset / dist_from_center) * params.hex_radius;
	}
	
	// Check if we crossed into a neighbor hex
	float best_dist = distance(new_position.xz, hex_center.xz);
	for (int slot = 0; slot < 32; slot++) {
		int neighbor_id = hex_adjacency_buf.data[current_hex_id * 32 + slot];
		if (neighbor_id < 0) continue;
		vec2 neighbor_xz = hex_world_position_buf.data[neighbor_id].xz;
		float d = distance(new_position.xz, neighbor_xz);
		if (d < best_dist) {
			best_dist = d;
			new_hex_id = neighbor_id;
		}
	}
	
	// If transitioning to a new hex, place dot inside new hex boundary
	if (new_hex_id != current_hex_id) {
		vec3 new_center = hex_world_position_buf.data[new_hex_id].xyz;
		vec2 to_new = new_position.xz - new_center.xz;
		float d_new = length(to_new);
		if (d_new > params.hex_radius && d_new > 0.001) {
			new_position.xz = new_center.xz + (to_new / d_new) * params.hex_radius;
		}
	}

	// Snap Y to the terrain surface of whichever hex the dot is now on.
	// new_hex_id is already the resolved destination (current or newly
	// transitioned), so this covers moving, holding, and hex-crossing in
	// one place — no dot can float or sink regardless of its initial Y.
	new_position.y = hex_world_position_buf.data[new_hex_id].xyz.y;

dot_world_position_buf.data[dot_id] = vec4(new_position, float(new_hex_id));
	dot_velocity_buf.data[dot_id] = vec4(0.0);
}
}
