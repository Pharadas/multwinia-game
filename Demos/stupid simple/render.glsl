#[compute]
#version 450
struct BoidState { vec4 pos; vec4 vel; };
struct InstanceData {
    vec4 row1; vec4 row2; vec4 row3; vec4 color;
};
layout(set=0, binding=0, std430) buffer StateBuf { BoidState boids[]; } state;
layout(set=0, binding=1, std430) buffer MultiMeshBuffer { InstanceData instances[]; } mm_buffer;
layout(push_constant) uniform PC {
    vec4 params; vec4 world_min; ivec4 grid_dims;
} pc;
layout(local_size_x=64) in;

void main() {
    uint id = gl_GlobalInvocationID.x;
    if (id >= uint(pc.params.y)) return;

    vec3 pos = state.boids[id].pos.xyz;
    vec3 vel = state.boids[id].vel.xyz;

    vec3 fwd = length(vel) > 0.001 ? normalize(vel) : vec3(0.0, 0.0, 1.0);
    vec3 up_hint = abs(fwd.y) > 0.99 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
    vec3 right = normalize(cross(up_hint, fwd));
    vec3 up = cross(fwd, right);

    mm_buffer.instances[id].row1 = vec4(right.x, up.x, fwd.x, pos.x);
    mm_buffer.instances[id].row2 = vec4(right.y, up.y, fwd.y, pos.y);
    mm_buffer.instances[id].row3 = vec4(right.z, up.z, fwd.z, pos.z);
    mm_buffer.instances[id].color = vec4(float(id % 3 == 0), float(id % 3 == 1), float(id % 3 == 2), 1.0);
}