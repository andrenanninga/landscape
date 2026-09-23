@tool
class_name TilePacking
extends RefCounted

## Static utility class for packing/unpacking tile data into integers.
## Provides bit manipulation for tile index, rotation, flip, and wall alignment.
##
## Layout of a packed tile:
##   bits 0-15   tile index (0xFFFF marks an erased face)
##   bits 16-17  rotation (0-3, clockwise quarter turns)
##   bit 18      flip horizontal
##   bit 19      flip vertical
##   bits 20-21  wall alignment mode (wall and fence tiles only)
##
## Bit 20 is dual-purpose: on the TOP tile of a cell it stores the diagonal flip flag
## instead, because top faces have no wall alignment. TerrainData keeps the two apart by
## never writing alignment bits into a top tile.

const TILE_INDEX_MASK := 0xFFFF
const TILE_ROTATION_MASK := 0x30000
const TILE_ROTATION_SHIFT := 16
const TILE_FLIP_H_BIT := 0x40000
const TILE_FLIP_V_BIT := 0x80000
const TILE_WALL_ALIGN_MASK := 0x300000
const TILE_WALL_ALIGN_SHIFT := 20
const DIAGONAL_FLIP_BIT := 0x100000


static func pack(tile_index: int, rotation: int = 0, flip_h: bool = false, flip_v: bool = false, wall_align: int = 0) -> int:
	var packed := tile_index & TILE_INDEX_MASK
	packed |= (rotation << TILE_ROTATION_SHIFT) & TILE_ROTATION_MASK
	if flip_h:
		packed |= TILE_FLIP_H_BIT
	if flip_v:
		packed |= TILE_FLIP_V_BIT
	packed |= (wall_align << TILE_WALL_ALIGN_SHIFT) & TILE_WALL_ALIGN_MASK
	return packed


static func unpack(packed: int) -> Dictionary:
	return {
		"tile_index": get_tile_index(packed),
		"rotation": get_rotation(packed),
		"flip_h": get_flip_h(packed),
		"flip_v": get_flip_v(packed),
		"wall_align": get_wall_align(packed),
	}


static func get_tile_index(packed: int) -> int:
	return packed & TILE_INDEX_MASK


static func get_rotation(packed: int) -> int:
	return (packed & TILE_ROTATION_MASK) >> TILE_ROTATION_SHIFT


static func get_flip_h(packed: int) -> bool:
	return (packed & TILE_FLIP_H_BIT) != 0


static func get_flip_v(packed: int) -> bool:
	return (packed & TILE_FLIP_V_BIT) != 0


static func get_wall_align(packed: int) -> int:
	return (packed & TILE_WALL_ALIGN_MASK) >> TILE_WALL_ALIGN_SHIFT


static func has_diagonal_flip(packed: int) -> bool:
	return (packed & DIAGONAL_FLIP_BIT) != 0


static func set_diagonal_flip(packed: int, flip: bool) -> int:
	if flip:
		return packed | DIAGONAL_FLIP_BIT
	return packed & ~DIAGONAL_FLIP_BIT
