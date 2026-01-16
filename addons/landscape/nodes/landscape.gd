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

@export var texture_set: TerrainTextureSet:
	set(value):
		texture_set = value
		_update_material()

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


func _ready() -> void:
	_mesh_builder = TerrainMeshBuilder.new()
	if not terrain_data:
		terrain_data = TerrainData.new()
	rebuild_mesh()
	_update_material()


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

	# Create RG8 image: width = grid_width * 5 (5 surfaces per cell), height = grid_depth
	# R channel = tile index (0-255)
	# G channel = flags (bits 0-1: rotation, bit 2: flip_h, bit 3: flip_v)
	var width := terrain_data.grid_width * 5
	var height := terrain_data.grid_depth

	var image := Image.create(width, height, false, Image.FORMAT_RG8)

	for z in terrain_data.grid_depth:
		for x in terrain_data.grid_width:
			var tiles := terrain_data.get_all_tiles_packed(x, z)
			for surface in 5:
				var packed := tiles[surface]
				var tile_index := packed & TerrainData.TILE_INDEX_MASK
				var rotation := (packed & TerrainData.TILE_ROTATION_MASK) >> TerrainData.TILE_ROTATION_SHIFT
				var flip_h := 1 if (packed & TerrainData.TILE_FLIP_H_BIT) != 0 else 0
				var flip_v := 1 if (packed & TerrainData.TILE_FLIP_V_BIT) != 0 else 0

				# Pack flags: bits 0-1 = rotation, bit 2 = flip_h, bit 3 = flip_v
				var flags := rotation | (flip_h << 2) | (flip_v << 3)

				var pixel_x := x * 5 + surface
				# Store as normalized values (0-255 range mapped to 0-1)
				image.set_pixel(pixel_x, z, Color(tile_index / 255.0, flags / 255.0, 0, 1))

	_tile_data_texture = ImageTexture.create_from_image(image)


func _update_material() -> void:
	# Tiled rendering takes priority if tile_set is assigned
	if tile_set and tile_set.atlas_texture:
		var shader: Shader = load("res://addons/landscape/shaders/terrain_tiled.gdshader")
		if shader:
			var mat := ShaderMaterial.new()
			mat.shader = shader

			# Set atlas texture
			mat.set_shader_parameter("tile_atlas", tile_set.atlas_texture)
			mat.set_shader_parameter("atlas_columns", tile_set.atlas_columns)
			mat.set_shader_parameter("atlas_rows", tile_set.atlas_rows)

			# Set normal map if available
			if tile_set.normal_atlas:
				mat.set_shader_parameter("tile_atlas_normal", tile_set.normal_atlas)
				mat.set_shader_parameter("use_normal_map", true)
			else:
				mat.set_shader_parameter("use_normal_map", false)

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
	elif texture_set:
		material_override = texture_set.create_material()
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


func set_paint_preview(cell: Vector2i, surface: int, tile: int, rotation: int, flip_h: bool, flip_v: bool) -> void:
	var mat := material_override as ShaderMaterial
	if mat:
		mat.set_shader_parameter("preview_cell", cell)
		mat.set_shader_parameter("preview_surface", surface)
		mat.set_shader_parameter("preview_tile", tile)
		mat.set_shader_parameter("preview_rotation", rotation)
		mat.set_shader_parameter("preview_flip_h", flip_h)
		mat.set_shader_parameter("preview_flip_v", flip_v)


func clear_paint_preview() -> void:
	var mat := material_override as ShaderMaterial
	if mat:
		mat.set_shader_parameter("preview_cell", Vector2i(-1, -1))


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
