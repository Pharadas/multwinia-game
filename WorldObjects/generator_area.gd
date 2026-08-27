extends Area3D

var caught_count := 0
var min_caught_to_generate := 3
var darwinians_per_second := 1
var owner_team := -1
var is_owned := false
var x := 0
var team_colors = [
	Color.DARK_RED,
	Color.DARK_GREEN,
	Color.DARK_BLUE,
	Color.DARK_GOLDENROD,
	Color.PURPLE,
	Color.DARK_CYAN
]

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	x += 1
	if x % 250 == 0 and caught_count == min_caught_to_generate:
		get_tree().root.get_child(0).make_new_darwinian(self.global_position + Vector3(0, 50, 0), owner_team)


func _on_body_entered(body: Node3D) -> void:
	var found_darwinian := body is Darwinian or body is GpuDarwinian
	if found_darwinian and should_capture_darwinians() and body.has_touched_floor_once:
		if not is_owned or body.team_number == owner_team:
			body.stick_to_generator()
			if body is GpuDarwinian:
				# A swarm is a whole garrison at once - one arrival alone
				# staffs the generator (classic darwinians need three).
				caught_count = min_caught_to_generate
			else:
				caught_count += 1
			is_owned = true
			owner_team = body.team_number
			if owner_team >= 0 and owner_team < team_colors.size():
				$"../CSGMesh3D".material.albedo_color = team_colors[owner_team]


func should_capture_darwinians() -> bool:
	return caught_count < min_caught_to_generate


func _on_body_exited(body: Node3D) -> void:
	var found_darwinian := body is Darwinian or body is GpuDarwinian
	if found_darwinian and body.is_currently_in_generating:
		if body is GpuDarwinian:
			caught_count = 0
		else:
			caught_count -= 1

	if caught_count == 0:
		is_owned = false
		owner_team = -1
		$"../CSGMesh3D".material.albedo = Color.WHITE
