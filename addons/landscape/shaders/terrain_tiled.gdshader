shader_type spatial;

// Tile atlas array texture (one layer per TileSet atlas source)
uniform sampler2DArray tile_atlas_array : source_color, filter_nearest, repeat_disable;

// Per-surface tile info, one RGBA8 pixel per surface, 9 surfaces per cell:
// R = atlas tile X, G = atlas tile Y, B = flags (bits 0-1 rotation, 2 flip_h, 3 flip_v,
// 4-5 wall align), A = atlas index. (255, 255, *, 255) marks an erased face.
uniform sampler2D tile_data : filter_nearest, repeat_disable;

uniform ivec2 grid_size = ivec2(8, 8);
uniform float cell_size = 1.0;

// Per-atlas grid dimensions (max 8 atlases)
uniform int atlas_columns[8];
uniform int atlas_rows[8];
uniform int atlas_count = 1;

uniform float roughness : hint_range(0.0, 1.0) = 0.8;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;

const int SURFACES_PER_CELL = 9;

// Surface types encoded by TerrainMeshBuilder in the vertex color alpha
const int SURFACE_TOP = 0;
const int SURFACE_NORTH = 1;
const int SURFACE_WEST = 4;
const int SURFACE_FLOOR = 5;
const int SURFACE_FENCE_NORTH = 6;
const int SURFACE_TYPE_COUNT = 10;

const int ALIGN_TOP = 1;
const int ALIGN_BOTTOM = 2;
const int ALIGN_STRETCH = 3;

const int ERASED_MARKER = 255;

// Walls sit on cell boundaries; sample the cell that owns them by nudging inward
const float WALL_NUDGE = 0.01;

varying vec3 local_position;
varying flat int surface_type;
varying vec2 wall_bounds;  // UV2: x = wall top Y, y = wall bottom Y
varying vec3 vertex_color;

void vertex() {
	local_position = VERTEX;
	surface_type = int(round(COLOR.a * float(SURFACE_TYPE_COUNT - 1)));
	vertex_color = COLOR.rgb;
	wall_bounds = UV2;
}

struct TileInfo {
	int tile_x;
	int tile_y;
	int rotation;
	bool flip_h;
	bool flip_v;
	int atlas_id;
	int wall_align;
	bool erased;
};

TileInfo get_tile_data(ivec2 cell, int surface) {
	vec2 data_uv = vec2(
		(float(cell.x * SURFACES_PER_CELL + surface) + 0.5) / float(grid_size.x * SURFACES_PER_CELL),
		(float(cell.y) + 0.5) / float(grid_size.y)
	);
	vec4 data = texture(tile_data, data_uv);
	int flags = int(data.b * 255.0);

	TileInfo info;
	info.tile_x = int(data.r * 255.0);
	info.tile_y = int(data.g * 255.0);
	info.atlas_id = int(data.a * 255.0);
	info.rotation = flags & 3;
	info.flip_h = ((flags >> 2) & 1) != 0;
	info.flip_v = ((flags >> 3) & 1) != 0;
	info.wall_align = (flags >> 4) & 3;
	info.erased = info.atlas_id == ERASED_MARKER && info.tile_x == ERASED_MARKER && info.tile_y == ERASED_MARKER;
	return info;
}

// Flip, then rotate clockwise in quarter turns
vec2 transform_uv(vec2 uv, int rotation, bool flip_h, bool flip_v) {
	if (flip_h) {
		uv.x = 1.0 - uv.x;
	}
	if (flip_v) {
		uv.y = 1.0 - uv.y;
	}

	if (rotation == 1) {
		uv = vec2(1.0 - uv.y, uv.x);
	} else if (rotation == 2) {
		uv = vec2(1.0 - uv.x, 1.0 - uv.y);
	} else if (rotation == 3) {
		uv = vec2(uv.y, 1.0 - uv.x);
	}

	return uv;
}

vec2 get_atlas_uv(TileInfo tile, vec2 local_uv) {
	vec2 tile_size = vec2(1.0 / float(atlas_columns[tile.atlas_id]), 1.0 / float(atlas_rows[tile.atlas_id]));
	return (vec2(float(tile.tile_x), float(tile.tile_y)) + local_uv) * tile_size;
}

// UV within the tile for a point on a horizontal surface
vec2 get_horizontal_uv(vec3 pos) {
	return fract(pos.xz / cell_size);
}

// UV within the tile for a point on a wall or fence; V grows downward so tiles stand upright
vec2 get_wall_uv(vec3 pos, int edge_surface, int align_mode, vec2 bounds) {
	// North/south walls run along X, east/west walls along Z
	bool along_x = edge_surface == SURFACE_NORTH || edge_surface == SURFACE_NORTH + 2;
	float h_uv = fract((along_x ? pos.x : pos.z) / cell_size);

	float v_uv;
	if (align_mode == ALIGN_TOP) {
		v_uv = fract((bounds.x - pos.y) / cell_size);
	} else if (align_mode == ALIGN_BOTTOM) {
		v_uv = fract((bounds.y - pos.y) / cell_size);
	} else if (align_mode == ALIGN_STRETCH) {
		float wall_height = bounds.x - bounds.y;
		v_uv = wall_height > 0.0 ? (bounds.x - pos.y) / wall_height : 0.0;
	} else {
		v_uv = fract(-pos.y / cell_size);
	}

	return vec2(h_uv, v_uv);
}

void fragment() {
	int surface = surface_type;

	// Fences reuse their wall's orientation (6..9 -> 1..4) and read tile data slots 5..8
	bool is_fence = surface >= SURFACE_FENCE_NORTH;
	int edge_surface = is_fence ? surface - SURFACE_FENCE_NORTH + SURFACE_NORTH : surface;
	int data_surface = is_fence ? surface - 1 : surface;

	vec3 adjusted_pos = local_position;
	if (edge_surface == SURFACE_NORTH) {
		adjusted_pos.z += WALL_NUDGE;
	} else if (edge_surface == SURFACE_NORTH + 1) {  // east
		adjusted_pos.x -= WALL_NUDGE;
	} else if (edge_surface == SURFACE_NORTH + 2) {  // south
		adjusted_pos.z -= WALL_NUDGE;
	} else if (edge_surface == SURFACE_WEST) {
		adjusted_pos.x += WALL_NUDGE;
	}
	ivec2 cell = clamp(ivec2(floor(adjusted_pos.xz / cell_size)), ivec2(0), grid_size - ivec2(1));

	// The floor has no tile data of its own and always shows tile (0, 0) of atlas 0
	TileInfo tile = TileInfo(0, 0, 0, false, false, 0, 0, false);
	if (surface != SURFACE_FLOOR) {
		tile = get_tile_data(cell, data_surface);
	}
	if (tile.erased) {
		discard;
	}

	vec2 local_uv;
	if (surface == SURFACE_TOP || surface == SURFACE_FLOOR) {
		local_uv = get_horizontal_uv(local_position);
	} else {
		local_uv = get_wall_uv(local_position, edge_surface, tile.wall_align, wall_bounds);
	}
	local_uv = transform_uv(local_uv, tile.rotation, tile.flip_h, tile.flip_v);

	vec4 albedo = texture(tile_atlas_array, vec3(get_atlas_uv(tile, local_uv), float(tile.atlas_id)));

	ALBEDO = albedo.rgb * vertex_color;
	ALPHA = albedo.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = roughness;
	METALLIC = metallic;
}
