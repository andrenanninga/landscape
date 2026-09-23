@tool
class_name TerrainTileSet
extends Resource

## Wraps a Godot TileSet so its atlas sources can be used for terrain texturing.
## Tiles from all atlas sources are numbered consecutively ("global" indices); each atlas
## also has "local" indices starting at 0.

signal tileset_changed

@export var tileset: TileSet:
	set(value):
		tileset = value
		refresh()

@export_group("Material")
@export_range(0.0, 1.0) var roughness: float = 0.8:
	set(value):
		roughness = value
		tileset_changed.emit()

@export_range(0.0, 1.0) var metallic: float = 0.0:
	set(value):
		metallic = value
		tileset_changed.emit()

# Per-atlas info: {texture, start_index, tile_count, columns, rows, tile_size, tiles}
# tiles is Array[Vector2i] of atlas coordinates for each defined tile, row-major
var _atlas_info: Array[Dictionary] = []

# Per global tile index: normalized UV rect within its atlas texture
var _tile_uv_rects: Array[Rect2] = []

# Per global tile index: Vector3i(atlas x, atlas y, atlas index)
var _tile_locations: Array[Vector3i] = []

# Global tile index -> {frames, columns, duration, stride, random_start} for animated tiles only
var _tile_animations: Dictionary = {}


# Re-reads the TileSet's sources. Call after the TileSet itself was edited; this resource
# cannot listen to `tileset.changed` on its own because a RefCounted script object has no
# usable `self` while it is being torn down, and TileSet emits `changed` from its destructor.
# LandscapeTerrain watches the TileSet and calls this instead.
func refresh() -> void:
	_rebuild_tile_data()
	tileset_changed.emit()


func _rebuild_tile_data() -> void:
	_tile_uv_rects.clear()
	_tile_locations.clear()
	_tile_animations.clear()
	_atlas_info.clear()

	if not tileset:
		return

	for source_idx in tileset.get_source_count():
		var source := tileset.get_source(tileset.get_source_id(source_idx))
		var atlas_source := source as TileSetAtlasSource
		if not atlas_source or not atlas_source.texture:
			continue

		var tex := atlas_source.texture
		var tile_sz := atlas_source.texture_region_size
		var tex_size := tex.get_size()
		var cols := maxi(1, int(tex_size.x / tile_sz.x))
		var rows := maxi(1, int(tex_size.y / tile_sz.y))

		var valid_tiles: Array[Vector2i] = []
		for i in atlas_source.get_tiles_count():
			valid_tiles.append(atlas_source.get_tile_id(i))
		valid_tiles.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			if a.y != b.y:
				return a.y < b.y
			return a.x < b.x
		)

		var atlas_idx := _atlas_info.size()
		_atlas_info.append({
			"texture": tex,
			"start_index": _tile_uv_rects.size(),
			"tile_count": valid_tiles.size(),
			"columns": cols,
			"rows": rows,
			"tile_size": tile_sz,
			"tiles": valid_tiles,
		})

		for coords in valid_tiles:
			var frames := atlas_source.get_tile_animation_frames_count(coords)
			if frames > 1:
				_tile_animations[_tile_locations.size()] = _read_animation(atlas_source, coords, frames)

			var pixel_rect := Rect2(Vector2(coords * tile_sz), Vector2(tile_sz))
			_tile_uv_rects.append(Rect2(pixel_rect.position / tex_size, pixel_rect.size / tex_size))
			_tile_locations.append(Vector3i(coords.x, coords.y, atlas_idx))


# Frames are spaced evenly over the whole cycle, so per-frame durations only affect its length.
# `stride` is the atlas cell step between frames (tile size plus separation).
func _read_animation(atlas_source: TileSetAtlasSource, coords: Vector2i, frames: int) -> Dictionary:
	var total_duration := 0.0
	for frame in frames:
		total_duration += atlas_source.get_tile_animation_frame_duration(coords, frame)
	var speed := maxf(atlas_source.get_tile_animation_speed(coords), 0.001)

	var columns := atlas_source.get_tile_animation_columns(coords)
	var stride := atlas_source.get_tile_size_in_atlas(coords) + atlas_source.get_tile_animation_separation(coords)
	var mode := atlas_source.get_tile_animation_mode(coords)

	return {
		"frames": frames,
		"columns": columns if columns > 0 else frames,
		"duration": total_duration / speed,
		"stride": stride,
		"random_start": mode == TileSetAtlasSource.TILE_ANIMATION_MODE_RANDOM_START_TIMES,
	}


func get_tile_count() -> int:
	return _tile_uv_rects.size()


func get_tile_uv_rect(tile_index: int) -> Rect2:
	if tile_index < 0 or tile_index >= _tile_uv_rects.size():
		return Rect2(0, 0, 1, 1)
	return _tile_uv_rects[tile_index]


# Atlas coordinates and atlas index of a global tile as Vector3i(x, y, atlas)
func get_tile_location(tile_index: int) -> Vector3i:
	if tile_index < 0 or tile_index >= _tile_locations.size():
		return Vector3i.ZERO
	return _tile_locations[tile_index]


# {frames, columns, duration (seconds per cycle), stride, random_start}; empty for static tiles
func get_tile_animation(tile_index: int) -> Dictionary:
	return _tile_animations.get(tile_index, {})


func get_atlas_count() -> int:
	return _atlas_info.size()


func get_atlas_info(atlas_idx: int) -> Dictionary:
	if atlas_idx < 0 or atlas_idx >= _atlas_info.size():
		return {}
	return _atlas_info[atlas_idx]


func get_atlas_for_tile(tile_index: int) -> int:
	return get_tile_location(tile_index).z


func get_local_tile_index(global_index: int) -> int:
	var atlas_idx := get_atlas_for_tile(global_index)
	if atlas_idx < _atlas_info.size():
		return global_index - _atlas_info[atlas_idx].start_index
	return global_index


func get_global_tile_index(atlas_idx: int, local_index: int) -> int:
	if atlas_idx < 0 or atlas_idx >= _atlas_info.size():
		return local_index
	return _atlas_info[atlas_idx].start_index + local_index


func get_atlas_tile_count(atlas_idx: int) -> int:
	if atlas_idx < 0 or atlas_idx >= _atlas_info.size():
		return 0
	return _atlas_info[atlas_idx].tile_count


func get_tile_atlas_coords_for_atlas(atlas_idx: int, local_index: int) -> Vector2i:
	if atlas_idx < 0 or atlas_idx >= _atlas_info.size():
		return Vector2i.ZERO
	var tiles: Array = _atlas_info[atlas_idx].tiles
	if local_index < 0 or local_index >= tiles.size():
		return Vector2i.ZERO
	return tiles[local_index]


func get_tile_atlas_coords_global(global_index: int) -> Vector2i:
	var location := get_tile_location(global_index)
	return Vector2i(location.x, location.y)


func get_atlas_tiles(atlas_idx: int) -> Array:
	if atlas_idx < 0 or atlas_idx >= _atlas_info.size():
		return []
	return _atlas_info[atlas_idx].tiles
