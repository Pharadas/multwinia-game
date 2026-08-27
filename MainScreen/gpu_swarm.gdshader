// gpu_swarm.gdshader
//
// The "brain" of a GpuDarwinian: every dot's motion is computed here, on
// the GPU, so a whole army of dots costs the CPU nothing per dot. The CPU
// only moves the emitter node itself (destinations, roads, captures) - the
// dots swirl around it as it moves.
//
// Each dot orbits the swarm's vertical axis at its own radius/speed/phase
// (all derived from a cheap hash of its particle index, so no two dots are
// ever in lockstep), bobs gently up and down, and the whole cloud breathes
// in and out so it never looks like a rigid blob.
shader_type particles;

// Cloud extents around the emitter origin, in world units. Sized for THIS
// map's scale: hexes are ~16 units across (hex_size 2 * mesh_scale 8), so
// the swarm needs to be a hex or more wide to read as an army.
const float SWARM_RADIUS = 10.0;
const float CLOUD_HEIGHT = 3.0;
// How fast the swirl spins (radians/sec at the slowest dot; faster dots
// multiply this).
const float ORBIT_SPEED = 1.1;

// Cheap deterministic hash so each dot gets stable, independent motion with
// no texture lookups.
float hash11(float n) {
	return fract(sin(n * 127.1 + 311.7) * 43758.5453123);
}

void start() {
	// A fresh dot: pick a stable home position, scale, and motion phase.
	float a = hash11(float(INDEX) * 2.17 + 1.0) * TAU;
	float r = hash11(float(INDEX) * 3.71 + 5.0);
	r = r * r * SWARM_RADIUS; // square it so dots bunch toward the core
	float h = (hash11(float(INDEX) * 5.93 + 9.0) - 0.5) * CLOUD_HEIGHT;
	float s = 0.5 + hash11(float(INDEX) * 7.31 + 13.0) * 1.0;

	// Build the transform column by column (translation is column 3).
	TRANSFORM = mat4(1.0);
	TRANSFORM[0] = vec4(s, 0.0, 0.0, 0.0);
	TRANSFORM[1] = vec4(0.0, s, 0.0, 0.0);
	TRANSFORM[2] = vec4(0.0, 0.0, s, 0.0);
	TRANSFORM[3] = vec4(cos(a) * r, h, sin(a) * r, 1.0);

	// Tint brightness by distance from the core (multiplied with the team
	// color on the draw material), so the cloud has a hot center and a
	// dimmer, hazy rim instead of reading as a flat ball.
	COLOR = vec4(vec3(0.45 + 0.55 * (1.0 - r / SWARM_RADIUS)), 1.0);

	CUSTOM.x = hash11(float(INDEX) * 11.03 + 3.0) * TAU; // orbit phase
	CUSTOM.y = 0.6 + hash11(float(INDEX) * 13.7 + 7.0) * 0.8; // orbit speed factor
	CUSTOM.z = hash11(float(INDEX) * 17.3 + 21.0) * TAU; // bob phase
	CUSTOM.w = h; // base height, restored every frame in process()
}

void process() {
	vec3 pos = TRANSFORM[3].xyz;

	// Orbit around the vertical axis, slowly breathing the radius in and
	// out so the cloud shimmers instead of spinning rigidly.
	float rad = length(pos.xz) * (1.0 + 0.14 * sin(TIME * 0.8 + CUSTOM.x * 4.0));
	float ang = atan(pos.z, pos.x) + TIME * ORBIT_SPEED * CUSTOM.y;
	pos.x = cos(ang) * rad;
	pos.z = sin(ang) * rad;

	// Gentle vertical bob around each dot's base height.
	pos.y = CUSTOM.w + sin(TIME * 2.2 + CUSTOM.z) * 0.35;

	TRANSFORM[3].xyz = pos;
}
