extends Node
# Path to the scenes you want to launch
const MAIN_SCREEN = "res://MainScreen/MainScreen.tscn"
const PHONE_PLAYER = "res://Phone/MainPhoneView.tscn"

var phone_scene: PackedScene = preload(PHONE_PLAYER)

func _ready() -> void:
	var arguments = OS.get_cmdline_args()

	if "--main_screen" in arguments:
		# Left half, full height.
		var screen_id = DisplayServer.window_get_current_screen()
		var screen_rect = DisplayServer.screen_get_usable_rect(screen_id)
		var half_width = screen_rect.size.x / 2
		var target_size := Vector2i(half_width, screen_rect.size.y)
		DisplayServer.window_set_size(target_size)
		DisplayServer.window_set_position(Vector2i(screen_rect.position.x, screen_rect.position.y))
		get_tree().change_scene_to_file.call_deferred(MAIN_SCREEN)
		return

	# Every other instance is just a phone player. It no longer needs a
	# team number handed to it at launch - HexTerrainSocket now assigns the
	# next free team number automatically the moment a phone connects (see
	# hex_terrain_socket.gd / hex_grid_2d_socket.gd), so there's nothing
	# left for this launcher to figure out or pass in.
	_launch_phone_player.call_deferred()

## change_scene_to_file() just loads a path - there's no way to pass data to
## the new scene through it. So instead we load + instantiate it ourselves
## and swap it in manually - this is the same thing change_scene_to_file()
## does internally, minus the parameter passing it doesn't support (which
## isn't needed here anymore anyway).
func _launch_phone_player() -> void:
	var phone_instance := phone_scene.instantiate()
	var tree := get_tree()
	var old_scene := tree.current_scene
	tree.root.add_child(phone_instance)
	tree.current_scene = phone_instance
	if old_scene:
		old_scene.queue_free()
