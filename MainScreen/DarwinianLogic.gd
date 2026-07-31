extends CharacterBody3D

var x := 0
var curr_destination := Vector3(randf_range(-128.0, 128.0), randf_range(-128.0, 128.0), randf_range(-128.0, 128.0))

func _ready():
	randomize()

func _process(delta: float) -> void:
	x += 1
	move_to_pos(curr_destination)
	if x % 1000 == 0:
		x = 0
		curr_destination = Vector3(randf_range(-128.0, 128.0), randf_range(-128.0, 128.0), randf_range(-128.0, 128.0))
		print("changing destination")

func move_to_pos(pos: Vector3) -> void:
	var distance = pos - self.global_position
	if distance.length() < 1.0:
		return

	var dir = distance.normalized()

	if is_on_floor():
		velocity.x += dir.x * 2.0
		velocity.z += dir.z * 2.0

	velocity.x = clamp(velocity.x, -5.0, 5.0)
	velocity.z = clamp(velocity.z, -5.0, 5.0)

func _physics_process(delta: float) -> void:
	# Add the gravity.
	if not is_on_floor():
		velocity += get_gravity() * delta

	move_and_slide()
