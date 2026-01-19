@tool
class_name TerrainTileSet
extends Resource

signal tileset_changed

# The Godot TileSet resource
@export var tileset: TileSet:
	set(value):
		tileset = value
		_rebuild_tile_data()
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

# Atlas texture (extracted from TileSet) - first atlas for backwards compatibility
var atlas_texture: Texture2D

# Tile size in pixels (extracted from TileSet)
var tile_size: Vector2i = Vector2i(16, 16)

# Atlas dimensions in tiles (first atlas for backwards compatibility)
var atlas_columns: int = 1
var atlas_rows: int = 1

# Cached UV rects for each tile (normalized 0-1)
var _tile_uv_rects: Array[Rect2] = []

# Per-atlas info: {texture, start_index, tile_count, columns, rows, tile_size, tiles}
# tiles is Array[Vector2i] of atlas coordinates for each valid tile
var _atlas_info: Array[Dictionary] = []

# Animation data: "atlas_idx,tile_x,tile_y" -> {frames, columns, speed}
var _animation_data: Dictionary = {}


func _rebuild_tile_data() -> void:
	_tile_uv_rects.clear()
	_atlas_info.clear()
	_animation_data.clear()
	atlas_texture = null

	if not tileset:
		atlas_columns = 1
		atlas_rows = 1
		return

	var current_index := 0
	for source_idx in tileset.get_source_count():
		var source_id := tileset.get_source_id(source_idx)
		var source = tileset.get_source(source_id)
		if source is TileSetAtlasSource:
			var atlas_source := source as TileSetAtlasSource
			var tex := atlas_source.texture
			if not tex:
				continue

			var tile_sz := atlas_source.texture_region_size
			var tex_size := tex.get_size()
			var cols := maxi(1, int(tex_size.x / tile_sz.x))
			var rows := maxi(1, int(tex_size.y / tile_sz.y))

			# Get only the tiles that are actually defined in the atlas
			var valid_tiles: Array[Vector2i] = []
			for i in atlas_source.get_tiles_count():
				var coords := atlas_source.get_tile_id(i)
				valid_tiles.append(coords)

			# Sort tiles by row then column for consistent ordering
			valid_tiles.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
				if a.y != b.y:
					return a.y < b.y
				return a.x < b.x
			)

			# Extract animation data for tiles with multiple frames
			for coords in valid_tiles:
				var frame_count := atlas_source.get_tile_animation_frames_count(coords)
				if frame_count > 1:
					var anim_columns := atlas_source.get_tile_animation_columns(coords)
					var anim_speed := atlas_source.get_tile_animation_speed(coords)
					var key := "%d,%d,%d" % [_atlas_info.size(), coords.x, coords.y]
					_animation_data[key] = {
						"frames": frame_count,
						"columns": anim_columns,
						"speed": anim_speed
					}

			_atlas_info.append({
				"texture": tex,
				"start_index": current_index,
				"tile_count": valid_tiles.size(),
				"columns": cols,
				"rows": rows,
				"tile_size": tile_sz,
				"tiles": valid_tiles
			})

			# Add UV rects for valid tiles only
			for coords in valid_tiles:
				var pixel_rect := Rect2(
					coords.x * tile_sz.x,
					coords.y * tile_sz.y,
					tile_sz.x,
					tile_sz.y
				)
				var uv_rect := Rect2(
					pixel_rect.position / tex_size,
					pixel_rect.size / tex_size
				)
				_tile_uv_rects.append(uv_rect)

			current_index += valid_tiles.size()

	# Set backwards-compatible values from first atlas
	if _atlas_info.size() > 0:
		var first := _atlas_info[0]
		atlas_texture = first.texture
		tile_size = first.tile_size
		atlas_columns = first.columns
		atlas_rows = first.rows
	else:
		atlas_columns = 1
		atlas_rows = 1


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


# Get the number of atlas sources
func get_atlas_count() -> int:
	return _atlas_info.size()


# Get info for a specific atlas
func get_atlas_info(atlas_idx: int) -> Dictionary:
	if atlas_idx < 0 or atlas_idx >= _atlas_info.size():
		return {}
	return _atlas_info[atlas_idx]


# Get the atlas index that contains a global tile index
func get_atlas_for_tile(tile_index: int) -> int:
	for i in _atlas_info.size():
		var info := _atlas_info[i]
		var start: int = info.start_index
		var count: int = info.tile_count
		if tile_index >= start and tile_index < start + count:
			return i
	return 0


# Get the local tile index within an atlas from a global index
func get_local_tile_index(global_index: int) -> int:
	var atlas_idx := get_atlas_for_tile(global_index)
	if atlas_idx < _atlas_info.size():
		return global_index - _atlas_info[atlas_idx].start_index
	return global_index


# Get the global tile index from atlas index and local tile index
func get_global_tile_index(atlas_idx: int, local_index: int) -> int:
	if atlas_idx < 0 or atlas_idx >= _atlas_info.size():
		return local_index
	return _atlas_info[atlas_idx].start_index + local_index


# Get tile count for a specific atlas
func get_atlas_tile_count(atlas_idx: int) -> int:
	if atlas_idx < 0 or atlas_idx >= _atlas_info.size():
		return 0
	return _atlas_info[atlas_idx].tile_count


# Get atlas coordinates for a local tile index within an atlas
func get_tile_atlas_coords_for_atlas(atlas_idx: int, local_index: int) -> Vector2i:
	if atlas_idx < 0 or atlas_idx >= _atlas_info.size():
		return Vector2i.ZERO
	var tiles: Array = _atlas_info[atlas_idx].tiles
	if local_index < 0 or local_index >= tiles.size():
		return Vector2i.ZERO
	return tiles[local_index]


# Get atlas coordinates for a global tile index
func get_tile_atlas_coords_global(global_index: int) -> Vector2i:
	var atlas_idx := get_atlas_for_tile(global_index)
	var local_idx := get_local_tile_index(global_index)
	return get_tile_atlas_coords_for_atlas(atlas_idx, local_idx)


# Get the valid tiles array for an atlas
func get_atlas_tiles(atlas_idx: int) -> Array:
	if atlas_idx < 0 or atlas_idx >= _atlas_info.size():
		return []
	return _atlas_info[atlas_idx].tiles


# Get animation data dictionary
func get_animation_data() -> Dictionary:
	return _animation_data
