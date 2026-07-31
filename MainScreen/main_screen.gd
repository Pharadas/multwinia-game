extends Node3D

const darwinian_scene := preload("res://MainScreen/Darwinian.tscn")

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	for i in range(1000):
		var darwinian := darwinian_scene.instantiate()
		var t = 100.0
		darwinian.global_position = Vector3(randf_range(-t, t), randf_range(10.0, 20.0), randf_range(-t, t))
		add_child(darwinian)

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass
