@tool
class_name PlaceholderTiles
extends RefCounted

# Generate a placeholder tile atlas image
static func generate_placeholder_atlas(columns: int = 4, rows: int = 4, tile_size: int = 16) -> Image:
	var width := columns * tile_size
	var height := rows * tile_size
	var image := Image.create(width, height, false, Image.FORMAT_RGBA8)

	# Distinct colors for different tile types
	var colors := [
		Color(0.22, 0.55, 0.24),  # 0: Grass green
		Color(0.45, 0.32, 0.20),  # 1: Dirt brown
		Color(0.55, 0.55, 0.52),  # 2: Stone gray
		Color(0.85, 0.75, 0.55),  # 3: Sand
		Color(0.25, 0.45, 0.65),  # 4: Water blue
		Color(0.18, 0.42, 0.20),  # 5: Dark grass
		Color(0.62, 0.42, 0.25),  # 6: Clay
		Color(0.38, 0.38, 0.42),  # 7: Dark stone
		Color(0.72, 0.72, 0.68),  # 8: Light stone
		Color(0.35, 0.25, 0.18),  # 9: Dark dirt
		Color(0.28, 0.52, 0.28),  # 10: Medium grass
		Color(0.92, 0.88, 0.78),  # 11: Light sand
		Color(0.58, 0.48, 0.38),  # 12: Sandstone
		Color(0.32, 0.32, 0.35),  # 13: Slate
		Color(0.48, 0.42, 0.32),  # 14: Mud
		Color(0.65, 0.58, 0.48),  # 15: Dried mud
	]

	var tile_index := 0
	for y in rows:
		for x in columns:
			var base_color: Color = colors[tile_index % colors.size()]
			_draw_placeholder_tile(image, x * tile_size, y * tile_size, tile_size, base_color, tile_index)
			tile_index += 1

	return image


static func _draw_placeholder_tile(image: Image, x: int, y: int, size: int, base_color: Color, index: int) -> void:
	# Fill with base color
	for py in size:
		for px in size:
			image.set_pixel(x + px, y + py, base_color)

	# Add subtle noise/texture pattern
	var darker := base_color.darkened(0.12)
	var lighter := base_color.lightened(0.08)
	for py in size:
		for px in size:
			# Create a pseudo-random pattern based on position
			var hash_val := ((px * 7 + py * 13 + index * 17) % 5)
			if hash_val == 0:
				image.set_pixel(x + px, y + py, darker)
			elif hash_val == 1:
				image.set_pixel(x + px, y + py, lighter)

	# Draw 1-pixel border (darker)
	var border_color := base_color.darkened(0.25)
	for i in size:
		image.set_pixel(x + i, y, border_color)  # Top
		image.set_pixel(x + i, y + size - 1, border_color)  # Bottom
		image.set_pixel(x, y + i, border_color)  # Left
		image.set_pixel(x + size - 1, y + i, border_color)  # Right


# Create a placeholder TileSet resource with atlas
static func create_placeholder_tileset(columns: int = 4, rows: int = 4, tile_size: int = 16) -> TileSet:
	var image := generate_placeholder_atlas(columns, rows, tile_size)
	var texture := ImageTexture.create_from_image(image)

	var tileset := TileSet.new()
	tileset.tile_size = Vector2i(tile_size, tile_size)

	var source := TileSetAtlasSource.new()
	source.texture = texture
	source.texture_region_size = Vector2i(tile_size, tile_size)

	# Create tiles in the atlas
	for y in rows:
		for x in columns:
			source.create_tile(Vector2i(x, y))

	tileset.add_source(source)
	return tileset


# Create a TerrainTileSet with placeholder tiles
static func create_terrain_tileset(columns: int = 4, rows: int = 4, tile_size: int = 16) -> TerrainTileSet:
	var godot_tileset := create_placeholder_tileset(columns, rows, tile_size)

	var terrain_tileset := TerrainTileSet.new()
	terrain_tileset.tileset = godot_tileset

	return terrain_tileset
