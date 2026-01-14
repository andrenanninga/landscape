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


func _ready() -> void:
	_mesh_builder = TerrainMeshBuilder.new()
	if not terrain_data:
		terrain_data = TerrainData.new()
	rebuild_mesh()
	_update_material()


func _on_data_changed() -> void:
	if auto_rebuild:
		rebuild_mesh()
	terrain_changed.emit()


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


func _update_material() -> void:
	if texture_set:
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
