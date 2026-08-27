// seiqr_swarm.gdshader
//
// A SEIIQR-style swarm: every dot's motion is computed here on the GPU and
// the CPU does nothing but hand the swarm an objective
// (SeiqrSwarm.set_objective()). No raycasts, no collisions, no per-dot CPU
// logic - the dots are the agents, this shader is the simulation, the same
// split as SEIIQR.cl (host sends a tiny struct, the GPU owns everything).
//
// Each dot orbits the objective at its own radius / height / speed / phase,
// all hashed from its particle index so no two dots move in lockstep. When
// the objective moves, every dot springs toward its new personal orbit slot
// and the whole cloud streams across the map.
//
// On top of that, every frame a compute shader (seiqr_spatial_hash.glsl)
// builds a SEIIQR spatial hash over the dots and writes each dot's neighbor
// count + centroid into the neighbor_tex texture. This shader reads it per
// dot and pushes away from crowded areas, so the swarm spreads out into a
// living cloud instead of a single lump.
shader_type particles;

// World position the swarm is marching toward. Set from GDScript via
// set_objective(); every dot reads it every frame. The only CPU->GPU state.
uniform vec3 objective;

// How eagerly dots chase their personal orbit slot (spring strength).
// Higher = snappier migration, lower = dreamier drift.
uniform float follow_strength = 2.5;

// How fast the swirl spins; each dot multiplies this by its own factor.
uniform float orbit_speed = 0.9;

// Simulation clock, shared with the spatial hash compute shader so both
// agree on where every dot's slot is. Set from GDScript every frame.
uniform float sim_time = -1.0;

// Spatial hash result: one texel per dot, (neighbor count, centroid.xyz).
// Written by seiqr_spatial_hash.glsl, sampled here by particle index.
uniform sampler2D neighbor_tex;
uniform int dot_count = 1200;

// How hard crowded dots push apart, and the count scale that saturates it.
uniform float separation_strength = 2.5;
uniform float neighbor_scale = 8.0;

// Cloud extent around the objective, in world units.
const float SWARM_RADIUS = 10.0;
const float CLOUD_HEIGHT = 3.0;
const float JITTER = 1.5;

// Cheap deterministic hash, same family as SEIIQR's simpleNoise().
float hash11(float n) {
	return fract(sin(n * 127.1 + 311.7) * 43758.5453123);
}

// ---- KEEP IN SYNC with seiqr_spatial_hash.glsl (same slot math) ----------
float radius_of(int idx) {
	float r = hash11(float(idx) * 3.71 + 5.0);
	return r * r * SWARM_RADIUS; // squared so dots bunch toward the core
}

float phase_of(int idx) { return hash11(float(idx) * 11.03 + 3.0) * TAU; }
float speed_factor_of(int idx) { return 0.6 + hash11(float(idx) * 13.7 + 7.0) * 0.8; }
float bob_of(int idx) { return hash11(float(idx) * 17.3 + 21.0) * TAU; }
float height_of(int idx) { return (hash11(float(idx) * 5.93 + 9.0) - 0.5) * CLOUD_HEIGHT; }

vec3 slot_of(int idx, float t) {
	float ang = phase_of(idx) + t * orbit_speed * speed_factor_of(idx);
	vec3 s = objective;
	s.x += cos(ang) * radius_of(idx);
	s.z += sin(ang) * radius_of(idx);
	s.y = height_of(idx) + sin(t * 2.0 + bob_of(idx)) * 0.5;
	return s;
}
// --------------------------------------------------------------------------

void start() {
	// A fresh dot is born already in place on its own orbit slot around the
	// objective, so the cloud is full from the first frame instead of
	// pouring out of the emitter origin.
	float t = sim_time >= 0.0 ? sim_time : TIME;
	vec3 pos = slot_of(int(INDEX), t);
	TRANSFORM = mat4(1.0);
	TRANSFORM[3] = vec4(pos, 1.0);

	// Brightness fades toward the rim (multiplied with the dot material's
	// albedo), so the swarm has a hot core and a hazy edge.
	float r = radius_of(int(INDEX));
	COLOR = vec4(vec3(0.45 + 0.55 * (1.0 - r / SWARM_RADIUS)), 1.0);
}

void process() {
	float t = sim_time >= 0.0 ? sim_time : TIME;
	vec3 pos = TRANSFORM[3].xyz;

	// Spring toward this dot's own orbit slot (VELOCITY is integrated by
	// the engine every frame, so this converges smoothly and never
	// overshoots)...
	VELOCITY = (slot_of(int(INDEX), t) - pos) * follow_strength;

	// ...then read this dot's spatial-hash result. neighbor_tex holds
	// (neighbor count, centroid) for every dot, written by the compute
	// shader this frame - this is the SEIIQR neighbor search, on the GPU.
	vec4 nb = texture(neighbor_tex, vec2((float(INDEX) + 0.5) / float(max(dot_count, 1)), 0.5));
	if (nb.x > 0.5) {
		// Push away from the centroid of nearby dots, scaled by how crowded
		// it is, so the swarm spreads out and dots keep their own space.
		VELOCITY += (pos - nb.yzw) * separation_strength * clamp(nb.x / neighbor_scale, 0.0, 1.0);
	}

	// SEIIQR-style random-walk jitter so the swarm shimmers instead of
	// spinning like a rigid body.
	VELOCITY.x += (hash11(pos.x * 3.1 + pos.z * 1.7 + t * 0.7) - 0.5) * JITTER;
	VELOCITY.y += (hash11(pos.y * 3.7 + pos.x * 2.3 + t * 0.7) - 0.5) * JITTER;
	VELOCITY.z += (hash11(pos.z * 4.3 + pos.y * 1.9 + t * 0.7) - 0.5) * JITTER;
}
