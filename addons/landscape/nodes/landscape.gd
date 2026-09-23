@tool
class_name LandscapeTerrain
extends MeshInstance3D

signal terrain_changed

const TILED_SHADER := preload("res://addons/landscape/shaders/terrain_tiled.gdshader")
const DEFAULT_SHADER := preload("res://addons/landscape/shaders/terrain.gdshader")

# Must match the uniform array sizes in terrain_tiled.gdshader
const MAX_ATLASES := 8

# Tile data texture layout: one RGBA8 pixel per surface, 9 surfaces per cell
# (TOP, N, E, S, W, FENCE_N, FENCE_E, FENCE_S, FENCE_W), one row per grid row.
# R = atlas tile X, G = atlas tile Y, B = flags (bits 0-1 rotation, 2 flip_h, 3 flip_v,
# 4-5 wall align), A = atlas index. An erased face is (255, 255, *, 255).
const SURFACES_PER_CELL := 9
const ERASED_MARKER := 255
const MAX_ATLAS_COORD := 254

const COLLISION_NODE_NAME := "TerrainCollision"

@export var terrain_data: TerrainData:
	set(value):
		if terrain_data and terrain_data.data_changed.is_connected(_on_data_changed):
			terrain_data.data_changed.disconnect(_on_data_changed)
		terrain_data = value
		if terrain_data:
			terrain_data.data_changed.connect(_on_data_changed)
		rebuild_mesh()
		_refresh_tile_data()

@export var tile_set: TerrainTileSet:
	set(value):
		if tile_set and tile_set.tileset_changed.is_connected(_on_tile_set_changed):
			tile_set.tileset_changed.disconnect(_on_tile_set_changed)
		tile_set = value
		if tile_set:
			tile_set.tileset_changed.connect(_on_tile_set_changed)
		_on_tile_set_changed()

@export var auto_rebuild: bool = true

var _mesh_builder := TerrainMeshBuilder.new()
var _preview := TerrainPreview.new()
var _tile_data_image: Image
var _tile_data_texture: ImageTexture

# The TileSet inside tile_set, watched for edits (see TerrainTileSet.refresh)
var _watched_tileset: TileSet


func _init() -> void:
	_preview.preview_changed.connect(_refresh_tile_data)


func _ready() -> void:
	if not terrain_data:
		terrain_data = TerrainData.new()
	rebuild_mesh()
	_update_material()


func _notification(what: int) -> void:
	# TileSet emits `changed` from its destructor; make sure it no longer targets this node by then
	if what == NOTIFICATION_PREDELETE:
		_watch_tileset(null)


func _on_tile_set_changed() -> void:
	_watch_tileset(tile_set.tileset if tile_set else null)
	_update_material()


func _watch_tileset(tileset: TileSet) -> void:
	if _watched_tileset == tileset:
		return
	if _watched_tileset and _watched_tileset.changed.is_connected(_on_watched_tileset_changed):
		_watched_tileset.changed.disconnect(_on_watched_tileset_changed)
	_watched_tileset = tileset
	if _watched_tileset:
		_watched_tileset.changed.connect(_on_watched_tileset_changed)


func _on_watched_tileset_changed() -> void:
	if tile_set:
		tile_set.refresh()


# The mesh, material and collision are all derived from terrain_data and rebuilt on load,
# so keep them out of the saved scene.
func _validate_property(property: Dictionary) -> void:
	if property.name == "mesh" or property.name == "material_override":
		property.usage &= ~PROPERTY_USAGE_STORAGE


func _on_data_changed() -> void:
	if auto_rebuild:
		rebuild_mesh()
	_refresh_tile_data()
	terrain_changed.emit()


func rebuild_mesh() -> void:
	if not terrain_data:
		return

	mesh = _mesh_builder.build_mesh(terrain_data)
	_update_collision()


# ============================================================================
# COLLISION
# ============================================================================

# Trimesh collision body for raycasts and physics. It is an unowned child, so it is
# neither shown in the scene tree nor saved with the scene.
func get_collision_body() -> StaticBody3D:
	return get_node_or_null(COLLISION_NODE_NAME) as StaticBody3D


func _update_collision() -> void:
	# Older versions generated an owned "<name>_col" body with create_trimesh_collision(),
	# which ended up saved in the scene. Drop any such leftovers.
	for child in get_children():
		if child is StaticBody3D and child.name != COLLISION_NODE_NAME:
			remove_child(child)
			child.queue_free()

	if not mesh:
		return

	var body := get_collision_body()
	if not body:
		body = StaticBody3D.new()
		body.name = COLLISION_NODE_NAME
		var shape_node := CollisionShape3D.new()
		shape_node.shape = ConcavePolygonShape3D.new()
		body.add_child(shape_node)
		add_child(body)

	var shape := (body.get_child(0) as CollisionShape3D).shape as ConcavePolygonShape3D
	shape.set_faces(mesh.get_faces())


# ============================================================================
# MATERIAL
# ============================================================================

# Builds the material from scratch; needed when the tile set or its atlases change
func _update_material() -> void:
	if not tile_set or tile_set.get_atlas_count() == 0:
		if not material_override or (material_override as ShaderMaterial).shader != DEFAULT_SHADER:
			var mat := ShaderMaterial.new()
			mat.shader = DEFAULT_SHADER
			material_override = mat
		_tile_data_texture = null
		_tile_data_image = null
		return

	var atlas_count := mini(tile_set.get_atlas_count(), MAX_ATLASES)
	if tile_set.get_atlas_count() > MAX_ATLASES:
		push_warning("LandscapeTerrain: tile set has %d atlases, only the first %d are rendered" % [tile_set.get_atlas_count(), MAX_ATLASES])

	var columns: Array[int] = []
	var rows: Array[int] = []
	for i in atlas_count:
		var info := tile_set.get_atlas_info(i)
		columns.append(info.columns)
		rows.append(info.rows)

	var mat := ShaderMaterial.new()
	mat.shader = TILED_SHADER
	mat.set_shader_parameter("tile_atlas_array", _build_atlas_array(atlas_count))
	mat.set_shader_parameter("atlas_columns", columns)
	mat.set_shader_parameter("atlas_rows", rows)
	mat.set_shader_parameter("atlas_count", atlas_count)
	mat.set_shader_parameter("roughness", tile_set.roughness)
	mat.set_shader_parameter("metallic", tile_set.metallic)
	material_override = mat

	_refresh_tile_data()


# Pushes the current tile data and grid dimensions to the existing tiled material
func _refresh_tile_data() -> void:
	var mat := material_override as ShaderMaterial
	if not mat or mat.shader != TILED_SHADER or not terrain_data or not tile_set:
		return

	_update_tile_data_texture()

	mat.set_shader_parameter("tile_data", _tile_data_texture)
	mat.set_shader_parameter("grid_size", Vector2i(terrain_data.grid_width, terrain_data.grid_depth))
	mat.set_shader_parameter("cell_size", terrain_data.cell_size)


# All atlas textures as one Texture2DArray. Layers must share a size and format, so
# smaller atlases are upscaled with nearest filtering; non-integer ratios will distort
# their pixels.
func _build_atlas_array(atlas_count: int) -> Texture2DArray:
	var images: Array[Image] = []
	var target_size := Vector2i.ZERO

	for i in atlas_count:
		var tex: Texture2D = tile_set.get_atlas_info(i).texture
		var img := tex.get_image() if tex else null
		if not img:
			continue

		img = img.duplicate()
		if img.is_compressed():
			img.decompress()
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		if img.has_mipmaps():
			img.clear_mipmaps()

		images.append(img)
		target_size.x = maxi(target_size.x, img.get_width())
		target_size.y = maxi(target_size.y, img.get_height())

	if images.is_empty():
		return null

	for img in images:
		if img.get_size() != target_size:
			img.resize(target_size.x, target_size.y, Image.INTERPOLATE_NEAREST)

	var array_texture := Texture2DArray.new()
	var err := array_texture.create_from_images(images)
	if err != OK:
		push_warning("LandscapeTerrain: failed to create Texture2DArray from atlas images: %d" % err)
		return null
	return array_texture


func _update_tile_data_texture() -> void:
	var width := terrain_data.grid_width * SURFACES_PER_CELL
	var height := terrain_data.grid_depth

	var bytes := PackedByteArray()
	bytes.resize(width * height * 4)

	for z in terrain_data.grid_depth:
		for x in terrain_data.grid_width:
			var tiles := terrain_data.get_all_tiles_packed(x, z)
			tiles.append_array(terrain_data.get_all_fence_tiles_packed(x, z))
			for surface in SURFACES_PER_CELL:
				_write_tile_pixel(bytes, _pixel_offset(x, z, surface, width), tiles[surface])

	var previews := _preview.get_buffer()
	for key: Vector3i in previews:
		if terrain_data.is_valid_cell(key.x, key.y) and key.z >= 0 and key.z < SURFACES_PER_CELL:
			_write_tile_pixel(bytes, _pixel_offset(key.x, key.y, key.z, width), previews[key])

	_tile_data_image = Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, bytes)
	if _tile_data_texture and _tile_data_texture.get_size() == Vector2(width, height):
		_tile_data_texture.update(_tile_data_image)
	else:
		_tile_data_texture = ImageTexture.create_from_image(_tile_data_image)


static func _pixel_offset(x: int, z: int, surface: int, width: int) -> int:
	return (z * width + x * SURFACES_PER_CELL + surface) * 4


func _write_tile_pixel(bytes: PackedByteArray, offset: int, packed: int) -> void:
	var tile_index := TilePacking.get_tile_index(packed)
	var flags := TilePacking.get_rotation(packed) \
		| (int(TilePacking.get_flip_h(packed)) << 2) \
		| (int(TilePacking.get_flip_v(packed)) << 3) \
		| (TilePacking.get_wall_align(packed) << 4)

	var location := Vector3i(ERASED_MARKER, ERASED_MARKER, ERASED_MARKER)
	if tile_index != TerrainData.ERASED_TILE_INDEX:
		location = tile_set.get_tile_location(tile_index)
		location.x = mini(location.x, MAX_ATLAS_COORD)
		location.y = mini(location.y, MAX_ATLAS_COORD)

	bytes[offset] = location.x
	bytes[offset + 1] = location.y
	bytes[offset + 2] = flags
	bytes[offset + 3] = location.z


# ============================================================================
# PAINT PREVIEW
# ============================================================================

# previews: Vector3i(x, z, surface) -> packed tile, rendered in place of the stored tiles
func set_tile_previews(previews: Dictionary) -> void:
	_preview.set_previews(previews)


func clear_preview() -> void:
	_preview.clear()


# ============================================================================
# COORDINATE HELPERS
# ============================================================================

func world_to_cell(world_pos: Vector3) -> Vector2i:
	var local_pos := to_local(world_pos)
	var cell_x := int(floor(local_pos.x / terrain_data.cell_size))
	var cell_z := int(floor(local_pos.z / terrain_data.cell_size))
	return Vector2i(
		clampi(cell_x, 0, terrain_data.grid_width - 1),
		clampi(cell_z, 0, terrain_data.grid_depth - 1)
	)


# Nearest corner to a world position as Vector3i(cell x, cell z, corner)
func world_to_corner(world_pos: Vector3) -> Vector3i:
	var local_pos := to_local(world_pos)
	var cell := world_to_cell(world_pos)
	var half_cell := terrain_data.cell_size / 2.0

	var cell_local_x := local_pos.x - cell.x * terrain_data.cell_size
	var cell_local_z := local_pos.z - cell.y * terrain_data.cell_size

	var corner: int
	if cell_local_x < half_cell:
		corner = TerrainData.Corner.NW if cell_local_z < half_cell else TerrainData.Corner.SW
	else:
		corner = TerrainData.Corner.NE if cell_local_z < half_cell else TerrainData.Corner.SE

	return Vector3i(cell.x, cell.y, corner)
