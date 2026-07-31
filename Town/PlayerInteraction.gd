extends TileMapLayer # Use 'extends TileMap' if using Godot 4.0-4.2 legacy node

func _unhandled_input(event: InputEvent) -> void:
	# Check if the player clicked the left mouse button
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:

		# 1. Get the mouse position relative to this TileMap
		var local_mouse_pos: Vector2 = get_local_mouse_position()

		# 2. Convert the local pixel position into grid coordinates (Vector2i)
		var clicked_cell: Vector2i = local_to_map(local_mouse_pos)

		# 3. Use the grid coordinates to interact with the tile
		_interact_with_tile(clicked_cell)

func _interact_with_tile(cell_coords: Vector2i) -> void:
	# Example: Get information about the tile at that position (layer 0)
	var tile_data: TileData = get_cell_tile_data(cell_coords)

	if tile_data != null:
		print("Clicked on a tile at grid position: ", cell_coords)
		var button = Button.new()
		button.text = "Click me"
		button.pressed.connect(_button_pressed)
		add_child(button)

	else:
		print("Clicked an empty cell at grid position: ", cell_coords)

func _button_pressed():
	print("Hello world!")
