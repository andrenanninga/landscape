shader_type spatial;
// PBR rendering - works with Godot's lighting and environment

// Tile atlas array texture (multiple atlas sources)
uniform sampler2DArray tile_atlas_array : source_color, filter_nearest, repeat_disable;

// Tile data texture - stores per-cell tile info
// Layout: width = grid_width * 5 (5 surfaces per cell), height = grid_depth
// RGBA8 format: R = local tile index low byte, G = local tile index high byte, B = flags (rotation + flip), A = atlas_id
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

// Selection highlight (kept from original shader)
uniform vec2 selected_cell = vec2(-1.0, -1.0);
uniform int selected_corner = -1;
uniform bool corner_mode = false;
uniform vec3 selection_color : source_color = vec3(1.0, 1.0, 1.0);
uniform float selection_border_width : hint_range(0.01, 0.2) = 0.08;
uniform float corner_highlight_size : hint_range(0.2, 0.7) = 0.5;

varying vec3 world_position;
varying vec3 local_position;
varying flat int surface_type;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	local_position = VERTEX;
	// Decode surface type from vertex color (R channel: 0-5 normalized to 0-1)
	// 0=top, 1=north, 2=east, 3=south, 4=west, 5=floor
	surface_type = int(round(COLOR.r * 5.0));
}

// Tile data struct to hold all unpacked values
struct TileInfo {
	int tile_index;  // Local tile index within atlas
	int rotation;    // 0-3
	int flip_h;      // 0 or 1
	int flip_v;      // 0 or 1
	int atlas_id;    // Which atlas this tile is from
};

// Get tile data from data texture
TileInfo get_tile_data(ivec2 cell, int surface) {
	// Calculate UV for tile data texture
	vec2 data_uv = vec2(
		(float(cell.x * 5 + surface) + 0.5) / float(grid_size.x * 5),
		(float(cell.y) + 0.5) / float(grid_size.y)
	);

	vec4 data = texture(tile_data, data_uv);

	// Unpack: R = local tile index low byte, G = local tile index high byte, B = flags, A = atlas_id
	int tile_low = int(data.r * 255.0);
	int tile_high = int(data.g * 255.0);
	int tile_index = tile_low + (tile_high << 8);
	int flags = int(data.b * 255.0);
	int atlas_id = int(data.a * 255.0);

	TileInfo info;
	info.tile_index = tile_index;
	info.rotation = flags & 3;           // Bits 0-1
	info.flip_h = (flags >> 2) & 1;      // Bit 2
	info.flip_v = (flags >> 3) & 1;      // Bit 3
	info.atlas_id = atlas_id;

	return info;
}

// Apply rotation and flip to UV coordinates
vec2 transform_uv(vec2 uv, int rotation, bool flip_h, bool flip_v) {
	// Apply flip first
	if (flip_h) {
		uv.x = 1.0 - uv.x;
	}
	if (flip_v) {
		uv.y = 1.0 - uv.y;
	}

	// Apply rotation (clockwise: 0=0°, 1=90°, 2=180°, 3=270°)
	if (rotation == 1) {
		uv = vec2(1.0 - uv.y, uv.x);
	} else if (rotation == 2) {
		uv = vec2(1.0 - uv.x, 1.0 - uv.y);
	} else if (rotation == 3) {
		uv = vec2(uv.y, 1.0 - uv.x);
	}

	return uv;
}

// Convert tile index + local UV to atlas UV for a specific atlas
vec2 get_atlas_uv(int tile_index, int atlas_id, vec2 local_uv) {
	int cols = atlas_columns[atlas_id];
	int rows = atlas_rows[atlas_id];

	int tile_x = tile_index % cols;
	int tile_y = tile_index / cols;

	vec2 tile_size = vec2(1.0 / float(cols), 1.0 / float(rows));
	vec2 tile_origin = vec2(float(tile_x), float(tile_y)) * tile_size;

	return tile_origin + local_uv * tile_size;
}

// Get local UV coordinates within a cell based on surface type
// Surface types: 0=top, 1=north, 2=east, 3=south, 4=west, 5=floor
vec2 get_surface_uv(vec3 pos, int surface) {
	if (surface == 0 || surface == 5) {
		// Top/floor surface - use XZ plane
		return fract(pos.xz / cell_size);
	} else if (surface == 1 || surface == 3) {
		// North/South walls - use XY plane
		return vec2(fract(pos.x / cell_size), fract(pos.y / cell_size));
	} else {
		// East/West walls - use ZY plane
		return vec2(fract(pos.z / cell_size), fract(pos.y / cell_size));
	}
}

void fragment() {
	// Use surface type from vertex color (set by mesh builder)
	// 0=top, 1=north, 2=east, 3=south, 4=west, 5=floor
	int surface = surface_type;

	// Adjust position for wall surfaces to get correct cell
	// Walls are on cell boundaries, so we offset slightly into the correct cell
	vec3 adjusted_pos = local_position;
	if (surface == 1) { // NORTH wall - at z = cell_z * cell_size
		adjusted_pos.z += 0.01;
	} else if (surface == 2) { // EAST wall - at x = (cell_x + 1) * cell_size
		adjusted_pos.x -= 0.01;
	} else if (surface == 3) { // SOUTH wall - at z = (cell_z + 1) * cell_size
		adjusted_pos.z -= 0.01;
	} else if (surface == 4) { // WEST wall - at x = cell_x * cell_size
		adjusted_pos.x += 0.01;
	}

	// Determine which cell we're in
	ivec2 cell = ivec2(floor(adjusted_pos.xz / cell_size));
	cell = clamp(cell, ivec2(0), grid_size - ivec2(1));

	// For floor surfaces, use tile 0 with no transformations
	int tile_index = 0;
	int rotation = 0;
	bool flip_h = false;
	bool flip_v = false;
	int atlas_id = 0;

	// Get tile data for non-floor surfaces (floor = 5)
	if (surface < 5) {
		TileInfo tile_info = get_tile_data(cell, surface);
		tile_index = tile_info.tile_index;
		rotation = tile_info.rotation;
		flip_h = tile_info.flip_h != 0;
		flip_v = tile_info.flip_v != 0;
		atlas_id = tile_info.atlas_id;
	}

	// Get local UV within cell
	vec2 local_uv = get_surface_uv(local_position, surface);

	// Apply rotation and flip transformations
	local_uv = transform_uv(local_uv, rotation, flip_h, flip_v);

	// Convert to atlas UV and sample from the atlas array
	vec2 atlas_uv = get_atlas_uv(tile_index, atlas_id, local_uv);
	vec4 albedo = texture(tile_atlas_array, vec3(atlas_uv, float(atlas_id)));

	// Set PBR outputs
	ALBEDO = albedo.rgb;
	ROUGHNESS = roughness;
	METALLIC = metallic;

	// Selection highlight (on top surfaces only)
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
				float size = corner_highlight_size;
				float border = selection_border_width;

				bool in_corner_region = abs(to_pos.x) < size && abs(to_pos.y) < size;

				if (in_corner_region) {
					bool on_x_edge = abs(to_pos.x) < border;
					bool on_y_edge = abs(to_pos.y) < border;

					if (on_x_edge || on_y_edge) {
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
