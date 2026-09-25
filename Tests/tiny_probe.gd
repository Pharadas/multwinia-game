extends SceneTree
func _initialize() -> void:
	_wait_and_print()
func _wait_and_print() -> void:
	for i in range(300):
		await process_frame
		if RenderingServer.get_rendering_device() != null:
			break
	print("PROBE rd=", RenderingServer.get_rendering_device())
	quit(0)
