shader_type spatial;
// PBR rendering - works with Godot's lighting and environment

// Tile atlas textures
uniform sampler2D tile_atlas : source_color, filter_nearest, repeat_disable;
uniform sampler2D tile_atlas_normal : hint_normal, filter_nearest, repeat_disable;
uniform bool use_normal_map = false;

// Tile data texture - stores per-cell tile info
// Layout: width = grid_width * 5 (5 surfaces per cell), height = grid_depth
// RG8 format: R = tile index, G = flags (rotation + flip)
uniform sampler2D tile_data : filter_nearest, repeat_disable;

// Grid configuration
uniform ivec2 grid_size = ivec2(8, 8);
uniform float cell_size = 1.0;

// Atlas configuration
uniform int atlas_columns = 4;
uniform int atlas_rows = 4;

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

// Get tile data from data texture
// Returns: x = tile_index, y = rotation (0-3), z = flip_h (0 or 1), w = flip_v (0 or 1)
ivec4 get_tile_data(ivec2 cell, int surface) {
	// Calculate UV for tile data texture
	vec2 data_uv = vec2(
		(float(cell.x * 5 + surface) + 0.5) / float(grid_size.x * 5),
		(float(cell.y) + 0.5) / float(grid_size.y)
	);

	vec4 data = texture(tile_data, data_uv);

	// Unpack: R = tile index, G = flags
	int tile_index = int(data.r * 255.0);
	int flags = int(data.g * 255.0);

	int rotation = flags & 3;           // Bits 0-1
	int flip_h = (flags >> 2) & 1;      // Bit 2
	int flip_v = (flags >> 3) & 1;      // Bit 3

	return ivec4(tile_index, rotation, flip_h, flip_v);
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

// Convert tile index + local UV to atlas UV
vec2 get_atlas_uv(int tile_index, vec2 local_uv) {
	int tile_x = tile_index % atlas_columns;
	int tile_y = tile_index / atlas_columns;

	vec2 tile_size = vec2(1.0 / float(atlas_columns), 1.0 / float(atlas_rows));
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

	// Get tile data for non-floor surfaces (floor = 5)
	if (surface < 5) {
		ivec4 tile_info = get_tile_data(cell, surface);
		tile_index = tile_info.x;
		rotation = tile_info.y;
		flip_h = tile_info.z != 0;
		flip_v = tile_info.w != 0;
	}

	// Get local UV within cell
	vec2 local_uv = get_surface_uv(local_position, surface);

	// Apply rotation and flip transformations
	local_uv = transform_uv(local_uv, rotation, flip_h, flip_v);

	// Convert to atlas UV and sample
	vec2 atlas_uv = get_atlas_uv(tile_index, local_uv);
	vec4 albedo = texture(tile_atlas, atlas_uv);

	// Set PBR outputs
	ALBEDO = albedo.rgb;
	ROUGHNESS = roughness;
	METALLIC = metallic;

	// Normal map if available
	if (use_normal_map) {
		vec3 normal_sample = texture(tile_atlas_normal, atlas_uv).rgb;
		NORMAL_MAP = normal_sample;
	}

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
