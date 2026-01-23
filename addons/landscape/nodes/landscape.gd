@tool
class_name LandscapeTerrain
extends MeshInstance3D

signal terrain_changed

@export var terrain_data: TerrainData:
	set(value):
		if terrain_data and terrain_data.data_changed.is_connected(_on_data_changed):
			terrain_data.data_changed.disconnect(_on_data_changed)
		terrain_data = value
		if terrain_data:
			terrain_data.data_changed.connect(_on_data_changed)
		rebuild_mesh()

@export var tile_set: TerrainTileSet:
	set(value):
		if tile_set and tile_set.tileset_changed.is_connected(_on_tileset_changed):
			tile_set.tileset_changed.disconnect(_on_tileset_changed)
		tile_set = value
		if tile_set:
			tile_set.tileset_changed.connect(_on_tileset_changed)
		_update_material()

@export var auto_rebuild: bool = true

@export_group("Grid")
@export var grid_width: int = 8:
	get:
		return terrain_data.grid_width if terrain_data else 8
	set(value):
		if terrain_data:
			terrain_data.grid_width = value

@export var grid_depth: int = 8:
	get:
		return terrain_data.grid_depth if terrain_data else 8
	set(value):
		if terrain_data:
			terrain_data.grid_depth = value

@export var cell_size: float = 1.0:
	get:
		return terrain_data.cell_size if terrain_data else 1.0
	set(value):
		if terrain_data:
			terrain_data.cell_size = value

@export_group("Height")
@export var height_step: float = 0.25:
	get:
		return terrain_data.height_step if terrain_data else 0.25
	set(value):
		if terrain_data:
			terrain_data.height_step = value

@export var max_slope_steps: int = 1:
	get:
		return terrain_data.max_slope_steps if terrain_data else 1
	set(value):
		if terrain_data:
			terrain_data.max_slope_steps = value

@export_group("")

var _mesh_builder: TerrainMeshBuilder
var _tile_data_texture: ImageTexture
var _preview: TerrainPreview
var _atlas_array_texture: Texture2DArray
var _animation_data_texture: ImageTexture


func _ready() -> void:
	_mesh_builder = TerrainMeshBuilder.new()
	_preview = TerrainPreview.new()
	_preview.preview_changed.connect(_on_preview_changed)
	if not terrain_data:
		terrain_data = TerrainData.new()
	rebuild_mesh()
	_update_material()


func _on_preview_changed() -> void:
	_update_tile_data_texture()
	var mat := material_override as ShaderMaterial
	if mat and _tile_data_texture:
		mat.set_shader_parameter("tile_data", _tile_data_texture)


func _on_data_changed() -> void:
	if auto_rebuild:
		rebuild_mesh()
	_update_tile_data_texture()
	_update_material()
	terrain_changed.emit()


func _on_tileset_changed() -> void:
	_update_material()


func rebuild_mesh() -> void:
	if not terrain_data:
		return
	if not _mesh_builder:
		_mesh_builder = TerrainMeshBuilder.new()

	mesh = _mesh_builder.build_mesh(terrain_data)
	_update_collision()


func _update_collision() -> void:
	# Remove existing collision children
	for child in get_children():
		if child is StaticBody3D:
			child.queue_free()

	# Create new collision from mesh
	if mesh:
		create_trimesh_collision()


func _update_tile_data_texture() -> void:
	if not terrain_data or not tile_set:
		_tile_data_texture = null
		return

	# Create RGBA8 image: width = grid_width * 9 (5 surfaces + 4 fence surfaces per cell), height = grid_depth
	# R channel = atlas tile X coordinate (0-255)
	# G channel = atlas tile Y coordinate (0-255)
	# B channel = flags (bits 0-1: rotation, bit 2: flip_h, bit 3: flip_v)
	# A channel = atlas_id (0-255)
	var width := terrain_data.grid_width * 9
	var height := terrain_data.grid_depth

	var image := Image.create(width, height, false, Image.FORMAT_RGBA8)

	for z in terrain_data.grid_depth:
		for x in terrain_data.grid_width:
			var tiles := terrain_data.get_all_tiles_packed(x, z)
			# Process 5 regular surfaces (top, north, east, south, west)
			for surface in 5:
				# Check if preview buffer has an override for this cell/surface
				var key := "%d,%d,%d" % [x, z, surface]
				var packed: int
				if _preview and _preview.has(key):
					packed = _preview.get_value(key)
				else:
					packed = tiles[surface]

				var global_tile_index := packed & TerrainData.TILE_INDEX_MASK
				var rotation := (packed & TerrainData.TILE_ROTATION_MASK) >> TerrainData.TILE_ROTATION_SHIFT
				var flip_h := 1 if (packed & TerrainData.TILE_FLIP_H_BIT) != 0 else 0
				var flip_v := 1 if (packed & TerrainData.TILE_FLIP_V_BIT) != 0 else 0
				var wall_align := (packed & TerrainData.TILE_WALL_ALIGN_MASK) >> TerrainData.TILE_WALL_ALIGN_SHIFT

				# Check for erased tile (special invisible marker)
				var atlas_id: int
				var atlas_coords: Vector2i
				if global_tile_index == TerrainData.ERASED_TILE_INDEX:
					atlas_id = 255  # Special marker for erased
					atlas_coords = Vector2i(255, 255)
				else:
					atlas_id = tile_set.get_atlas_for_tile(global_tile_index)
					atlas_coords = tile_set.get_tile_atlas_coords_global(global_tile_index)

				# Pack flags: bits 0-1 = rotation, bit 2 = flip_h, bit 3 = flip_v, bits 4-5 = wall_align
				var flags := rotation | (flip_h << 2) | (flip_v << 3) | (wall_align << 4)

				var pixel_x := x * 9 + surface
				# Store as normalized values (0-255 range mapped to 0-1)
				image.set_pixel(pixel_x, z, Color(atlas_coords.x / 255.0, atlas_coords.y / 255.0, flags / 255.0, atlas_id / 255.0))

			# Process 4 fence surfaces (fence_north, fence_east, fence_south, fence_west)
			var fence_tiles := terrain_data.get_all_fence_tiles_packed(x, z)
			for edge in 4:
				var fence_surface := 5 + edge  # 5=fence_north, 6=fence_east, 7=fence_south, 8=fence_west
				var key := "%d,%d,%d" % [x, z, fence_surface + 1]  # Surface enum: FENCE_NORTH=5, etc.
				var packed: int
				if _preview and _preview.has(key):
					packed = _preview.get_value(key)
				else:
					packed = fence_tiles[edge]

				var global_tile_index := packed & TerrainData.TILE_INDEX_MASK
				var rotation := (packed & TerrainData.TILE_ROTATION_MASK) >> TerrainData.TILE_ROTATION_SHIFT
				var flip_h := 1 if (packed & TerrainData.TILE_FLIP_H_BIT) != 0 else 0
				var flip_v := 1 if (packed & TerrainData.TILE_FLIP_V_BIT) != 0 else 0
				var wall_align := (packed & TerrainData.TILE_WALL_ALIGN_MASK) >> TerrainData.TILE_WALL_ALIGN_SHIFT

				# Check for erased tile (special invisible marker)
				var atlas_id: int
				var atlas_coords: Vector2i
				if global_tile_index == TerrainData.ERASED_TILE_INDEX:
					atlas_id = 255  # Special marker for erased
					atlas_coords = Vector2i(255, 255)
				else:
					atlas_id = tile_set.get_atlas_for_tile(global_tile_index)
					atlas_coords = tile_set.get_tile_atlas_coords_global(global_tile_index)

				# Pack flags: bits 0-1 = rotation, bit 2 = flip_h, bit 3 = flip_v, bits 4-5 = wall_align
				var flags := rotation | (flip_h << 2) | (flip_v << 3) | (wall_align << 4)

				var pixel_x := x * 9 + fence_surface
				# Store as normalized values (0-255 range mapped to 0-1)
				image.set_pixel(pixel_x, z, Color(atlas_coords.x / 255.0, atlas_coords.y / 255.0, flags / 255.0, atlas_id / 255.0))

	_tile_data_texture = ImageTexture.create_from_image(image)


func _update_atlas_array() -> void:
	_atlas_array_texture = null

	if not tile_set or tile_set.get_atlas_count() == 0:
		return

	# Collect all atlas images and convert to same format/size
	var images: Array[Image] = []
	var target_size := Vector2i.ZERO

	# First pass: find the largest dimensions
	for i in tile_set.get_atlas_count():
		var info := tile_set.get_atlas_info(i)
		var tex: Texture2D = info.texture
		if tex:
			var img := tex.get_image()
			if img:
				target_size.x = maxi(target_size.x, img.get_width())
				target_size.y = maxi(target_size.y, img.get_height())

	if target_size == Vector2i.ZERO:
		return

	# Second pass: collect images, convert format and resize if needed
	for i in tile_set.get_atlas_count():
		var info := tile_set.get_atlas_info(i)
		var tex: Texture2D = info.texture
		if tex:
			var img := tex.get_image()
			if img:
				# Make a copy to avoid modifying the original
				img = img.duplicate()

				# Decompress if compressed
				if img.is_compressed():
					img.decompress()

				# Convert to RGBA8 format for consistency
				if img.get_format() != Image.FORMAT_RGBA8:
					img.convert(Image.FORMAT_RGBA8)

				# Clear mipmaps for consistency (we use nearest filtering anyway)
				if img.has_mipmaps():
					img.clear_mipmaps()

				# Resize if needed (all images must be same size for Texture2DArray)
				if img.get_width() != target_size.x or img.get_height() != target_size.y:
					img.resize(target_size.x, target_size.y, Image.INTERPOLATE_NEAREST)

				images.append(img)

	if images.is_empty():
		return

	# Create Texture2DArray from all atlas textures
	_atlas_array_texture = Texture2DArray.new()
	var err := _atlas_array_texture.create_from_images(images)
	if err != OK:
		push_warning("Failed to create Texture2DArray from atlas images: %d" % err)
		_atlas_array_texture = null


func _update_animation_data_texture() -> void:
	_animation_data_texture = null

	if not tile_set or tile_set.get_atlas_count() == 0:
		return

	# Find max dimensions needed across all atlases
	var max_cols := 1
	var max_rows := 1
	for i in tile_set.get_atlas_count():
		var info := tile_set.get_atlas_info(i)
		max_cols = maxi(max_cols, info.columns)
		max_rows = maxi(max_rows, info.rows)

	var atlas_count := tile_set.get_atlas_count()

	# Create RGBA8 image: width = max_cols * max_rows, height = atlas_count
	# R = frame count (1 = not animated)
	# G = animation columns (frames per row)
	# B = animation speed (scaled: value * 10 = actual speed, so 25.5 max)
	# A = reserved
	var width := max_cols * max_rows
	var height := atlas_count

	var image := Image.create(width, height, false, Image.FORMAT_RGBA8)

	# Initialize all pixels to frame_count=1 (no animation)
	# Using 1.0/255.0 for frame_count=1, columns=1, speed=0
	image.fill(Color(1.0 / 255.0, 1.0 / 255.0, 0.0, 0.0))

	# Fill in animation data for animated tiles
	var anim_data := tile_set.get_animation_data()
	for key: String in anim_data:
		var parts: PackedStringArray = key.split(",")
		var atlas_id := int(parts[0])
		var tile_x := int(parts[1])
		var tile_y := int(parts[2])

		var info := tile_set.get_atlas_info(atlas_id)
		var cols: int = info.columns

		# Linear index for this tile position
		var linear_idx := tile_y * cols + tile_x

		var data: Dictionary = anim_data[key]
		var frames: int = data.frames
		var anim_columns: int = data.columns
		var speed: float = data.speed

		# Encode values (frame_count and columns as direct values, speed scaled)
		var r := float(frames) / 255.0
		var g := float(anim_columns) / 255.0
		var b := speed / 25.5  # Scale so max readable speed is 25.5

		image.set_pixel(linear_idx, atlas_id, Color(r, g, b, 0.0))

	_animation_data_texture = ImageTexture.create_from_image(image)


func _update_material() -> void:
	# Tiled rendering takes priority if tile_set is assigned
	if tile_set and tile_set.get_atlas_count() > 0:
		var shader: Shader = load("res://addons/landscape/shaders/terrain_tiled.gdshader")
		if shader:
			var mat := ShaderMaterial.new()
			mat.shader = shader

			# Update atlas array texture
			_update_atlas_array()

			# Set atlas array texture
			if _atlas_array_texture:
				mat.set_shader_parameter("tile_atlas_array", _atlas_array_texture)

			# Update and set animation data texture
			_update_animation_data_texture()
			if _animation_data_texture:
				mat.set_shader_parameter("animation_data", _animation_data_texture)
				# Calculate dimensions for shader
				var max_cols := 1
				var max_rows := 1
				for i in tile_set.get_atlas_count():
					var info := tile_set.get_atlas_info(i)
					max_cols = maxi(max_cols, info.columns)
					max_rows = maxi(max_rows, info.rows)
				mat.set_shader_parameter("anim_data_size", Vector2i(max_cols * max_rows, tile_set.get_atlas_count()))

			# Set per-atlas columns and rows arrays
			var atlas_count := tile_set.get_atlas_count()
			var columns_array: Array[int] = []
			var rows_array: Array[int] = []
			for i in atlas_count:
				var info := tile_set.get_atlas_info(i)
				columns_array.append(info.columns)
				rows_array.append(info.rows)

			mat.set_shader_parameter("atlas_columns", columns_array)
			mat.set_shader_parameter("atlas_rows", rows_array)
			mat.set_shader_parameter("atlas_count", atlas_count)

			# Set PBR properties
			mat.set_shader_parameter("roughness", tile_set.roughness)
			mat.set_shader_parameter("metallic", tile_set.metallic)

			# Set grid info
			if terrain_data:
				mat.set_shader_parameter("grid_size", Vector2i(terrain_data.grid_width, terrain_data.grid_depth))
				mat.set_shader_parameter("cell_size", terrain_data.cell_size)

			# Set tile data texture
			_update_tile_data_texture()
			if _tile_data_texture:
				mat.set_shader_parameter("tile_data", _tile_data_texture)

			material_override = mat
		else:
			material_override = null
	else:
		# Apply default shader with solid colors
		var shader: Shader = load("res://addons/landscape/shaders/terrain.gdshader")
		if shader:
			var mat := ShaderMaterial.new()
			mat.shader = shader
			material_override = mat
		else:
			material_override = null


# Helper to convert world position to cell coordinates
func world_to_cell(world_pos: Vector3) -> Vector2i:
	var local_pos := to_local(world_pos)
	var cell_x := int(local_pos.x / terrain_data.cell_size)
	var cell_z := int(local_pos.z / terrain_data.cell_size)
	return Vector2i(
		clampi(cell_x, 0, terrain_data.grid_width - 1),
		clampi(cell_z, 0, terrain_data.grid_depth - 1)
	)


func set_selected_cell(cell: Vector2i, corner: int = -1, corner_mode: bool = false) -> void:
	var mat := material_override as ShaderMaterial
	if mat:
		mat.set_shader_parameter("selected_cell", Vector2(cell.x, cell.y))
		mat.set_shader_parameter("cell_size", terrain_data.cell_size if terrain_data else 1.0)
		mat.set_shader_parameter("selected_corner", corner)
		mat.set_shader_parameter("corner_mode", corner_mode)


func clear_selection() -> void:
	var mat := material_override as ShaderMaterial
	if mat:
		mat.set_shader_parameter("selected_cell", Vector2(-1.0, -1.0))
		mat.set_shader_parameter("selected_corner", -1)
		mat.set_shader_parameter("corner_mode", false)


func set_tile_previews(previews: Dictionary) -> void:
	if not _preview:
		_preview = TerrainPreview.new()
		_preview.preview_changed.connect(_on_preview_changed)
	_preview.set_previews(previews)


func get_preview_buffer() -> Dictionary:
	return _preview.get_buffer() if _preview else {}


func clear_preview() -> void:
	if _preview:
		_preview.clear()


func has_preview() -> bool:
	return _preview and not _preview.is_empty()


# Helper to convert world position to nearest corner
func world_to_corner(world_pos: Vector3) -> Vector3i:
	var local_pos := to_local(world_pos)
	var cell := world_to_cell(world_pos)

	# Find which corner of the cell is nearest
	var cell_local_x := local_pos.x - cell.x * terrain_data.cell_size
	var cell_local_z := local_pos.z - cell.y * terrain_data.cell_size
	var half_cell := terrain_data.cell_size / 2.0

	var corner: int
	if cell_local_x < half_cell:
		corner = TerrainData.Corner.NW if cell_local_z < half_cell else TerrainData.Corner.SW
	else:
		corner = TerrainData.Corner.NE if cell_local_z < half_cell else TerrainData.Corner.SE

	return Vector3i(cell.x, cell.y, corner)
