@tool
class_name TerrainTileSet
extends Resource

signal tileset_changed

# The Godot TileSet resource (provides editor preview and tile organization)
@export var tileset: TileSet:
	set(value):
		tileset = value
		_rebuild_tile_data()
		tileset_changed.emit()

# Which atlas source to use (usually 0)
@export var atlas_source_id: int = 0:
	set(value):
		atlas_source_id = value
		_rebuild_tile_data()
		tileset_changed.emit()

# The atlas texture (extracted from TileSet or set directly)
@export var atlas_texture: Texture2D:
	set(value):
		atlas_texture = value
		_rebuild_tile_data()
		tileset_changed.emit()

# Optional normal map atlas (must have same layout as albedo)
@export var normal_atlas: Texture2D:
	set(value):
		normal_atlas = value
		tileset_changed.emit()

# PBR material properties
@export_group("Material")
@export_range(0.0, 1.0) var roughness: float = 0.8:
	set(value):
		roughness = value
		tileset_changed.emit()

@export_range(0.0, 1.0) var metallic: float = 0.0:
	set(value):
		metallic = value
		tileset_changed.emit()

# Tile size in pixels (extracted from TileSet or set manually)
var tile_size: Vector2i = Vector2i(16, 16)

# Atlas dimensions in tiles
var atlas_columns: int = 1
var atlas_rows: int = 1

# Cached UV rects for each tile (normalized 0-1)
var _tile_uv_rects: Array[Rect2] = []


func _rebuild_tile_data() -> void:
	_tile_uv_rects.clear()

	# Try to extract data from TileSet if available
	if tileset and tileset.get_source_count() > 0:
		var source_id := atlas_source_id if atlas_source_id < tileset.get_source_count() else 0
		var source = tileset.get_source(source_id)
		if source is TileSetAtlasSource:
			var atlas_source := source as TileSetAtlasSource
			if not atlas_texture:
				atlas_texture = atlas_source.texture
			tile_size = atlas_source.texture_region_size

	if not atlas_texture:
		atlas_columns = 1
		atlas_rows = 1
		return

	var tex_size := atlas_texture.get_size()
	atlas_columns = maxi(1, int(tex_size.x / tile_size.x))
	atlas_rows = maxi(1, int(tex_size.y / tile_size.y))

	# Pre-calculate normalized UV rects for all tiles
	for y in atlas_rows:
		for x in atlas_columns:
			var pixel_rect := Rect2(
				x * tile_size.x,
				y * tile_size.y,
				tile_size.x,
				tile_size.y
			)
			var uv_rect := Rect2(
				pixel_rect.position / tex_size,
				pixel_rect.size / tex_size
			)
			_tile_uv_rects.append(uv_rect)


func get_tile_count() -> int:
	return _tile_uv_rects.size()


func get_tile_uv_rect(tile_index: int) -> Rect2:
	if tile_index < 0 or tile_index >= _tile_uv_rects.size():
		return Rect2(0, 0, 1, 1)
	return _tile_uv_rects[tile_index]


func get_tile_atlas_coords(tile_index: int) -> Vector2i:
	if atlas_columns <= 0:
		return Vector2i.ZERO
	return Vector2i(tile_index % atlas_columns, tile_index / atlas_columns)


# Get the UV size of a single tile (for shader)
func get_tile_uv_size() -> Vector2:
	if atlas_columns <= 0 or atlas_rows <= 0:
		return Vector2.ONE
	return Vector2(1.0 / atlas_columns, 1.0 / atlas_rows)
