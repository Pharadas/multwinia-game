// boid_swarm.gdshader
//
// The boids swarm's RENDERER - deliberately dumb. All simulation happens in
// boid_compute.glsl: positions and velocities live in SSBOs and are updated
// every frame by the compute pipeline (spatial-hash neighbor search plus the
// classic boids rules), then written into the per-dot boid_data texture.
// This shader does nothing but read that texture and place the dot, exactly
// like boids_compute_example's particle shader: the GPUParticles3D node is
// just a pool of sprites, the compute pipeline owns the sim.
shader_type particles;

// Per-dot sim state: (x, y, z, friend count). One texel per dot, written by
// boid_compute.glsl pass 4.
uniform sampler2D boid_data;

// Team tint; dots brighten toward white where they're dense.
uniform vec3 team_color : source_color = vec3(0.35, 0.85, 0.45);

// Dot radius in world units (the draw-pass sphere mesh is radius 1, so the
// TRANSFORM scale IS the radius).
uniform float dot_scale = 0.18;

// Friend count that saturates the density brightness (tune with dot_count).
uniform float density_scale = 8.0;

float hash11(float n) {
	return fract(sin(n * 127.1 + 311.7) * 43758.5453123);
}

void process() {
	// Pull this dot's sim state straight from the compute shader's texture.
	vec4 data = texelFetch(boid_data, ivec2(int(INDEX), 0), 0);

	// Position: world space, owned entirely by the compute simulation.
	TRANSFORM[3].xyz = data.xyz;

	// Per-dot size variety (render-only, hashed from INDEX - the sim doesn't
	// care about looks).
	float s = dot_scale * (0.7 + 0.6 * hash11(float(INDEX) * 12.9898 + 78.233));
	TRANSFORM[0].xyz = vec3(s, 0.0, 0.0);
	TRANSFORM[1].xyz = vec3(0.0, s, 0.0);
	TRANSFORM[2].xyz = vec3(0.0, 0.0, s);

	// Dense spots glow toward white; the sparse rim stays team-colored.
	float density = clamp(data.a / density_scale, 0.0, 1.0);
	COLOR = vec4(mix(team_color * 0.5, vec3(1.0), density * 0.85), 1.0);
}
