@tool
extends MeshInstance3D

@export var heightmap_image: NoiseTexture2D

@export var height_scale: float = 10.0
@export var mesh_scale: float = 1.0

func _ready() -> void:
	generate_terrain()

func generate_terrain() -> void:
	if not heightmap_image:
		return

	await heightmap_image.changed
	# Extract image data safely
	var img: Image = heightmap_image.get_image()
	print(img)
	var width: int = img.get_width()
	var depth: int = img.get_height()

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# 1. Generate Vertices, UVs, and Heights
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	
	# Pre-allocate array size for performance
	vertices.resize(width * depth)
	uvs.resize(width * depth)

	for z in range(depth):
		for x in range(width):
			# Get height value from the red channel (0.0 to 1.0)
			var pixel_color := img.get_pixel(x, z) * 4.0
			var y_height := pixel_color.r * height_scale

			# Calculate vertex position centered around the origin
			var pos := Vector3(
				(x - width / 2.0) * mesh_scale,
				y_height,
				(z - depth / 2.0) * mesh_scale
			)
			
			var index := x + (z * width)
			vertices[index] = pos
			uvs[index] = Vector2(float(x) / width, float(z) / depth)

	# 2. Build Triangles (Indices)
	for z in range(depth - 1):
		for x in range(width - 1):
			# Corner indices for the current grid quad
			var tl := x + (z * width)
			var tr := (x + 1) + (z * width)
			var bl := x + ((z + 1) * width)
			var br := (x + 1) + ((z + 1) * width)

			# Triangle 1 (Top-Left -> Top-Right -> Bottom-Left)
			st.set_uv(uvs[tl]); st.add_vertex(vertices[tl])
			st.set_uv(uvs[tr]); st.add_vertex(vertices[tr])
			st.set_uv(uvs[bl]); st.add_vertex(vertices[bl])

			# Triangle 2 (Top-Right -> Bottom-Right -> Bottom-Left)
			st.set_uv(uvs[tr]); st.add_vertex(vertices[tr])
			st.set_uv(uvs[br]); st.add_vertex(vertices[br])
			st.set_uv(uvs[bl]); st.add_vertex(vertices[bl])

	# 3. Finalize Mesh Properties
	st.generate_normals() # Automatically generates smooth lighting normals
	st.generate_tangents() # Required if you plan to use normal maps

	var meshval: ArrayMesh = st.commit()
	mesh = meshval

	# 4. Generate the Collision Shape
	# Create a StaticBody3D parent if you don't have one in your scene tree
	var static_body = StaticBody3D.new()
	add_child(static_body)

	# Generate the precise trimesh shape data from the mesh data
	var collision_shape = CollisionShape3D.new()
	collision_shape.shape = mesh.create_trimesh_shape()
	
	# Add the shape as a child of the static body
	static_body.add_child(collision_shape)
