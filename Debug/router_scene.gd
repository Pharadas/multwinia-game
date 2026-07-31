extends Node

# Path to the scenes you want to launch
const MAIN_SCREEN = "res://MainScreen/MainScreen.tscn"
const PHONE_PLAYER = "res://Town/Town.tscn"

func _ready() -> void:
	var arguments = OS.get_cmdline_args()

	# Get screen dimensions
	var screen_id = DisplayServer.window_get_current_screen()
	var screen_rect = DisplayServer.screen_get_usable_rect(screen_id)
	
	# Calculate half-screen width and full height
	var half_width = screen_rect.size.x / 2
	var target_size = Vector2i(half_width, screen_rect.size.y)

	# Check which instance is running
	if "--main_screen" in arguments:
				# Resize and position on the LEFT
		DisplayServer.window_set_size(target_size)
		DisplayServer.window_set_position(Vector2i(screen_rect.position.x, screen_rect.position.y))
		get_tree().change_scene_to_file(MAIN_SCREEN)

	elif "--phone_player" in arguments:
		# Resize and position on the RIGHT
		DisplayServer.window_set_size(target_size)
		DisplayServer.window_set_position(Vector2i(screen_rect.position.x + half_width, screen_rect.position.y))
		get_tree().change_scene_to_file(PHONE_PLAYER)
	else:
		# Fallback if you run a single instance normally
		get_tree().change_scene_to_file(MAIN_SCREEN)
