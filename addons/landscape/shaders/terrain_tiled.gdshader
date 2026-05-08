shader_type spatial;

// Tile atlas array texture (multiple atlas sources)
uniform sampler2DArray tile_atlas_array : source_color, filter_nearest, repeat_disable;

// Tile data texture - stores per-cell tile info
// Layout: width = grid_width * 9 (5 surfaces + 4 fence surfaces per cell), height = grid_depth
// RGBA8 format: R = atlas tile X coord, G = atlas tile Y coord, B = flags (rotation + flip), A = atlas_id
uniform sampler2D tile_data : filter_nearest, repeat_disable;

// Grid configuration
uniform ivec2 grid_size = ivec2(8, 8);
uniform float cell_size = 1.0;

// Atlas configuration (per-atlas arrays, max 8 atlases)
uniform int atlas_columns[8];
uniform int atlas_rows[8];
uniform int atlas_count = 1;

// PBR material properties
uniform float roughness : hint_range(0.0, 1.0) = 0.8;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;

// Selection highlight
uniform vec2 selected_cell = vec2(-1.0, -1.0);
uniform int selected_corner = -1;
uniform bool corner_mode = false;
uniform vec3 selection_color : source_color = vec3(1.0, 1.0, 1.0);
uniform float selection_border_width : hint_range(0.01, 0.2) = 0.08;
uniform float corner_highlight_size : hint_range(0.2, 0.7) = 0.5;

varying vec3 world_position;
varying vec3 local_position;
varying flat int surface_type;
varying vec2 wall_bounds;  // UV2: x = wall top Y, y = wall bottom Y (for wall alignment)
varying vec3 vertex_color;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	local_position = VERTEX;
	// Decode surface type from vertex color alpha channel (0-9 normalized to 0-1)
	// 0=top, 1=north, 2=east, 3=south, 4=west, 5=floor,
	// 6=fence_north, 7=fence_east, 8=fence_south, 9=fence_west
	surface_type = int(round(COLOR.a * 9.0));
	vertex_color = COLOR.rgb;
	wall_bounds = UV2;
}

// Tile data struct to hold all unpacked values
struct TileInfo {
	int tile_x;      // Atlas tile X coordinate
	int tile_y;      // Atlas tile Y coordinate
	int rotation;    // 0-3
	int flip_h;      // 0 or 1
	int flip_v;      // 0 or 1
	int atlas_id;    // Which atlas this tile is from
	int wall_align;  // 0=world, 1=top, 2=bottom, 3=stretch (for wall surfaces)
};

// Get tile data from data texture
TileInfo get_tile_data(ivec2 cell, int surface) {
	vec2 data_uv = vec2(
		(float(cell.x * 9 + surface) + 0.5) / float(grid_size.x * 9),
		(float(cell.y) + 0.5) / float(grid_size.y)
	);

	vec4 data = texture(tile_data, data_uv);

	// Unpack: R = atlas tile X, G = atlas tile Y, B = flags, A = atlas_id
	int tile_x = int(data.r * 255.0);
	int tile_y = int(data.g * 255.0);
	int flags = int(data.b * 255.0);
	int atlas_id = int(data.a * 255.0);

	TileInfo info;
	info.tile_x = tile_x;
	info.tile_y = tile_y;
	info.rotation = flags & 3;           // Bits 0-1
	info.flip_h = (flags >> 2) & 1;      // Bit 2
	info.flip_v = (flags >> 3) & 1;      // Bit 3
	info.wall_align = (flags >> 4) & 3;  // Bits 4-5 (0=world, 1=top, 2=bottom)
	info.atlas_id = atlas_id;

	return info;
}

// Apply rotation and flip to UV coordinates
vec2 transform_uv(vec2 uv, int rotation, bool flip_h, bool flip_v) {
	if (flip_h) {
		uv.x = 1.0 - uv.x;
	}
	if (flip_v) {
		uv.y = 1.0 - uv.y;
	}

	// Clockwise: 0=0°, 1=90°, 2=180°, 3=270°
	if (rotation == 1) {
		uv = vec2(1.0 - uv.y, uv.x);
	} else if (rotation == 2) {
		uv = vec2(1.0 - uv.x, 1.0 - uv.y);
	} else if (rotation == 3) {
		uv = vec2(uv.y, 1.0 - uv.x);
	}

	return uv;
}

// Convert tile coords + local UV to atlas UV for a specific atlas
vec2 get_atlas_uv(int tile_x, int tile_y, int atlas_id, vec2 local_uv) {
	int cols = atlas_columns[atlas_id];
	int rows = atlas_rows[atlas_id];

	vec2 tile_size = vec2(1.0 / float(cols), 1.0 / float(rows));
	vec2 tile_origin = vec2(float(tile_x), float(tile_y)) * tile_size;

	return tile_origin + local_uv * tile_size;
}

// Get local UV coordinates within a cell based on surface type
// align_mode: 0=world, 1=top, 2=bottom (only used for wall surfaces)
// bounds: x=wall_top_y, y=wall_bottom_y (only used for wall surfaces)
vec2 get_surface_uv(vec3 pos, int surface, int align_mode, vec2 bounds) {
	if (surface == 0 || surface == 5) {
		// Top/floor surface - use XZ plane
		return fract(pos.xz / cell_size);
	}

	// Wall surfaces - horizontal UV
	float h_uv;
	if (surface == 1 || surface == 3) {
		// North/South walls - use X for horizontal
		h_uv = fract(pos.x / cell_size);
	} else {
		// East/West walls - use Z for horizontal
		h_uv = fract(pos.z / cell_size);
	}

	// Vertical UV based on wall alignment mode (V decreases as Y increases = right-side-up)
	float v_uv;
	float wall_top = bounds.x;
	float wall_bottom = bounds.y;

	if (align_mode == 1) {
		v_uv = fract((wall_top - pos.y) / cell_size);
	} else if (align_mode == 2) {
		v_uv = fract((wall_bottom - pos.y) / cell_size);
	} else if (align_mode == 3) {
		float wall_height = wall_top - wall_bottom;
		v_uv = wall_height > 0.0 ? (wall_top - pos.y) / wall_height : 0.0;
	} else {
		v_uv = fract(-pos.y / cell_size);
	}

	return vec2(h_uv, v_uv);
}

void fragment() {
	int surface = surface_type;

	// Walls/fences sit on cell boundaries — nudge slightly into the owning cell
	vec3 adjusted_pos = local_position;
	if (surface == 1 || surface == 6) {       // NORTH
		adjusted_pos.z += 0.01;
	} else if (surface == 2 || surface == 7) { // EAST
		adjusted_pos.x -= 0.01;
	} else if (surface == 3 || surface == 8) { // SOUTH
		adjusted_pos.z -= 0.01;
	} else if (surface == 4 || surface == 9) { // WEST
		adjusted_pos.x += 0.01;
	}

	ivec2 cell = ivec2(floor(adjusted_pos.xz / cell_size));
	cell = clamp(cell, ivec2(0), grid_size - ivec2(1));

	int tile_x = 0;
	int tile_y = 0;
	int rotation = 0;
	bool flip_h = false;
	bool flip_v = false;
	int atlas_id = 0;
	int wall_align = 0;

	// floor (surface 5) uses default tile (0,0); fence surfaces map to tile data indices 5-8
	int data_surface = surface;
	if (surface >= 6) {
		data_surface = surface - 1;
	}

	if (surface < 5 || surface >= 6) {
		TileInfo tile_info = get_tile_data(cell, data_surface);
		tile_x = tile_info.tile_x;
		tile_y = tile_info.tile_y;
		rotation = tile_info.rotation;
		flip_h = tile_info.flip_h != 0;
		flip_v = tile_info.flip_v != 0;
		atlas_id = tile_info.atlas_id;
		wall_align = tile_info.wall_align;

		if (atlas_id == 255 && tile_x == 255 && tile_y == 255) {
			discard;
		}
	}

	// Fence surfaces share UV logic with their wall counterparts (6→1, 7→2, 8→3, 9→4)
	int uv_surface = surface >= 6 ? surface - 5 : surface;

	vec2 local_uv = get_surface_uv(local_position, uv_surface, wall_align, wall_bounds);
	local_uv = transform_uv(local_uv, rotation, flip_h, flip_v);

	vec2 atlas_uv = get_atlas_uv(tile_x, tile_y, atlas_id, local_uv);
	vec4 albedo = texture(tile_atlas_array, vec3(atlas_uv, float(atlas_id)));

	ALBEDO = albedo.rgb * vertex_color;
	ALPHA = albedo.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = roughness;
	METALLIC = metallic;

	// Selection highlight on top faces only
	bool is_top_face = surface == 0;
	if (selected_cell.x >= 0.0 && is_top_face) {
		vec2 cell_min = selected_cell * cell_size;
		vec2 cell_max = cell_min + vec2(cell_size);
		vec2 pos_xz = local_position.xz;

		if (pos_xz.x >= cell_min.x && pos_xz.x <= cell_max.x &&
			pos_xz.y >= cell_min.y && pos_xz.y <= cell_max.y) {

			vec2 norm_pos = (pos_xz - cell_min) / cell_size;

			if (corner_mode && selected_corner >= 0) {
				vec2 corner_pos;
				if (selected_corner == 0) corner_pos = vec2(0.0, 0.0);
				else if (selected_corner == 1) corner_pos = vec2(1.0, 0.0);
				else if (selected_corner == 2) corner_pos = vec2(1.0, 1.0);
				else corner_pos = vec2(0.0, 1.0);

				vec2 to_pos = norm_pos - corner_pos;
				bool in_corner_region = abs(to_pos.x) < corner_highlight_size && abs(to_pos.y) < corner_highlight_size;

				if (in_corner_region) {
					if (abs(to_pos.x) < selection_border_width || abs(to_pos.y) < selection_border_width) {
						ALBEDO = mix(ALBEDO, selection_color, 0.7);
					} else {
						ALBEDO = mix(ALBEDO, vec3(1.0), 0.1);
					}
				}
			} else {
				float dist_to_left = pos_xz.x - cell_min.x;
				float dist_to_right = cell_max.x - pos_xz.x;
				float dist_to_top = pos_xz.y - cell_min.y;
				float dist_to_bottom = cell_max.y - pos_xz.y;

				float min_dist = min(min(dist_to_left, dist_to_right), min(dist_to_top, dist_to_bottom));
				float border = selection_border_width * cell_size;

				if (min_dist < border) {
					ALBEDO = mix(ALBEDO, selection_color, 0.5);
				} else {
					ALBEDO = mix(ALBEDO, vec3(1.0), 0.12);
				}
			}
		}
	}
}
