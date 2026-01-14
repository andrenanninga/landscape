shader_type spatial;
render_mode unshaded;

// Textures with nearest filtering for pixelated look
uniform sampler2D top_albedo : source_color, filter_nearest, repeat_enable;
uniform sampler2D side_albedo : source_color, filter_nearest, repeat_enable;

//// Distinct colors for each direction (6 faces of a cube)
//uniform vec3 color_up : source_color = vec3(0.2, 0.0, 0.9);       // Top - blue
//uniform vec3 color_down : source_color = vec3(0.9, 0.8, 0.2);     // Bottom - yellow
//uniform vec3 color_north : source_color = vec3(0.9, 0.2, 0.2);    // North (-Z) - red
//uniform vec3 color_south : source_color = vec3(0.2, 0.8, 0.3);    // South (+Z) - green
//uniform vec3 color_east : source_color = vec3(0.95, 0.5, 0.1);    // East (+X) - orange
//uniform vec3 color_west : source_color = vec3(0.6, 0.3, 0.8);     // West (-X) - purple
//
//// Checkerboard colors (darker variants for contrast)
//uniform vec3 checker_color_up : source_color = vec3(0.1, 0.0, 0.7);
//uniform vec3 checker_color_down : source_color = vec3(0.7, 0.6, 0.1);
//uniform vec3 checker_color_north : source_color = vec3(0.7, 0.1, 0.1);
//uniform vec3 checker_color_south : source_color = vec3(0.1, 0.6, 0.2);
//uniform vec3 checker_color_east : source_color = vec3(0.75, 0.35, 0.05);
//uniform vec3 checker_color_west : source_color = vec3(0.45, 0.2, 0.6);

// Main colors
uniform vec3 color_up : source_color      = vec3(0.10, 0.07, 0.04); // Bottom – dark soil
uniform vec3 color_down : source_color        = vec3(0.18, 0.42, 0.18); // Top – grass green
uniform vec3 color_north : source_color     = vec3(0.30, 0.22, 0.14); // North – shaded dirt
uniform vec3 color_south : source_color     = vec3(0.38, 0.28, 0.18); // South – lighter dirt
uniform vec3 color_east : source_color      = vec3(0.42, 0.32, 0.20); // East – sunlit dirt
uniform vec3 color_west : source_color      = vec3(0.26, 0.20, 0.13); // West – darker dirt

// Checkerboard (darker variants for shading/variation)
uniform vec3 checker_color_up : source_color  = vec3(0.07, 0.05, 0.03);
uniform vec3 checker_color_down : source_color    = vec3(0.14, 0.34, 0.14);
uniform vec3 checker_color_north : source_color = vec3(0.24, 0.18, 0.11);
uniform vec3 checker_color_south : source_color = vec3(0.32, 0.24, 0.15);
uniform vec3 checker_color_east : source_color  = vec3(0.36, 0.27, 0.17);
uniform vec3 checker_color_west : source_color  = vec3(0.21, 0.16, 0.10);

// Texture parameters
uniform float uv_scale : hint_range(0.1, 10.0) = 1.0;
uniform float checker_scale : hint_range(0.5, 8.0) = 4.0;
uniform float slope_threshold : hint_range(0.0, 1.0) = 0.7;

// Whether textures are assigned
uniform bool use_top_texture = false;
uniform bool use_side_texture = false;

// Selection highlight
uniform vec2 selected_cell = vec2(-1.0, -1.0);
uniform float cell_size = 1.0;
uniform int selected_corner = -1;
uniform bool corner_mode = false;
uniform vec3 selection_color : source_color = vec3(1.0, 1.0, 1.0);
uniform float selection_border_width : hint_range(0.01, 0.2) = 0.08;
uniform float corner_highlight_size : hint_range(0.2, 0.7) = 0.5;

varying vec3 world_position;
varying vec3 local_position;

// Get checkerboard value (0 or 1) based on world position and face direction
float get_checker(vec3 pos, vec3 normal) {
	vec3 abs_normal = abs(normal);
	vec2 checker_uv;

	// Choose UV plane based on dominant normal direction
	if (abs_normal.y > abs_normal.x && abs_normal.y > abs_normal.z) {
		// Top/bottom face - use XZ plane
		checker_uv = pos.xz;
	} else if (abs_normal.x > abs_normal.z) {
		// East/west face - use YZ plane
		checker_uv = pos.yz;
	} else {
		// North/south face - use XY plane
		checker_uv = pos.xy;
	}

	// Scale and compute checkerboard
	checker_uv *= checker_scale;
	vec2 grid = floor(checker_uv);
	return mod(grid.x + grid.y, 2.0);
}

// Determine dominant direction and return corresponding colors
void get_direction_colors(vec3 normal, out vec3 primary, out vec3 secondary) {
	vec3 abs_normal = abs(normal);

	// Find dominant axis
	if (abs_normal.y >= abs_normal.x && abs_normal.y >= abs_normal.z) {
		// Vertical faces (up or down)
		if (normal.y > 0.0) {
			primary = color_up;
			secondary = checker_color_up;
		} else {
			primary = color_down;
			secondary = checker_color_down;
		}
	} else if (abs_normal.x >= abs_normal.z) {
		// East or West
		if (normal.x > 0.0) {
			primary = color_east;
			secondary = checker_color_east;
		} else {
			primary = color_west;
			secondary = checker_color_west;
		}
	} else {
		// North or South
		if (normal.z > 0.0) {
			primary = color_south;
			secondary = checker_color_south;
		} else {
			primary = color_north;
			secondary = checker_color_north;
		}
	}
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	local_position = VERTEX;
}

void fragment() {
	// Compute flat face normal from screen-space derivatives
	vec3 face_normal = normalize(cross(dFdx(world_position), dFdy(world_position)));

	// Calculate UV from world position for seamless tiling
	vec2 top_uv = floor(world_position.xz * uv_scale) / uv_scale;

	// Triplanar UVs for side textures (pixelated)
	vec2 side_uv_x = floor(world_position.zy * uv_scale) / uv_scale;
	vec2 side_uv_z = floor(world_position.xy * uv_scale) / uv_scale;

	// Get direction-based colors
	vec3 primary_color;
	vec3 secondary_color;
	get_direction_colors(face_normal, primary_color, secondary_color);

	// Calculate checkerboard pattern
	float checker = get_checker(world_position, face_normal);

	vec3 final_color;

	if (use_top_texture || use_side_texture) {
		// Determine if this is a top/bottom face or a wall
		float up_dot = abs(dot(face_normal, vec3(0.0, 1.0, 0.0)));
		bool is_horizontal = up_dot > slope_threshold;

		vec4 tex_color;
		if (is_horizontal && use_top_texture) {
			tex_color = texture(top_albedo, top_uv * uv_scale);
		} else if (use_side_texture) {
			// Triplanar blend for walls
			vec3 blend_weights = abs(face_normal);
			blend_weights = normalize(blend_weights);
			vec4 side_tex_x = texture(side_albedo, side_uv_x * uv_scale);
			vec4 side_tex_z = texture(side_albedo, side_uv_z * uv_scale);
			tex_color = side_tex_x * blend_weights.x + side_tex_z * blend_weights.z;
			tex_color /= (blend_weights.x + blend_weights.z + 0.0001);
		} else {
			tex_color = vec4(mix(primary_color, secondary_color, checker), 1.0);
		}
		final_color = tex_color.rgb;
	} else {
		// Use checkerboard pattern with direction-based colors
		final_color = mix(primary_color, secondary_color, checker);
	}

	// Apply selection highlight only on top faces (use local position since cell coords are in local space)
	// Use abs() because derivative cross product direction can vary
	bool is_top_face = abs(face_normal.y) > 0.5;
	if (selected_cell.x >= 0.0 && is_top_face) {
		// Calculate cell bounds
		vec2 cell_min = selected_cell * cell_size;
		vec2 cell_max = cell_min + vec2(cell_size);

		// Check if we're inside the selected cell (on XZ plane)
		vec2 pos_xz = local_position.xz;
		if (pos_xz.x >= cell_min.x && pos_xz.x <= cell_max.x &&
			pos_xz.y >= cell_min.y && pos_xz.y <= cell_max.y) {

			// Normalize position within cell (0-1)
			vec2 norm_pos = (pos_xz - cell_min) / cell_size;

			if (corner_mode && selected_corner >= 0) {
				// Corner mode: highlight with chevron shape pointing outward from corner
				vec2 corner_pos;
				if (selected_corner == 0) corner_pos = vec2(0.0, 0.0);      // NW
				else if (selected_corner == 1) corner_pos = vec2(1.0, 0.0); // NE
				else if (selected_corner == 2) corner_pos = vec2(1.0, 1.0); // SE
				else corner_pos = vec2(0.0, 1.0);                            // SW

				vec2 to_pos = norm_pos - corner_pos;
				float size = corner_highlight_size;
				float border = selection_border_width;

				// Check if within the corner region
				bool in_corner_region = abs(to_pos.x) < size && abs(to_pos.y) < size;

				if (in_corner_region) {
					// Draw border on the inner edges (closest to corner)
					bool on_x_edge = abs(to_pos.x) < border;
					bool on_y_edge = abs(to_pos.y) < border;

					if (on_x_edge || on_y_edge) {
						final_color = mix(final_color, selection_color, 0.7);
					} else {
						final_color = mix(final_color, vec3(1.0), 0.1);
					}
				}
			} else {
				// Cell mode: highlight entire cell with border
				float dist_to_left = pos_xz.x - cell_min.x;
				float dist_to_right = cell_max.x - pos_xz.x;
				float dist_to_top = pos_xz.y - cell_min.y;
				float dist_to_bottom = cell_max.y - pos_xz.y;

				float min_dist = min(min(dist_to_left, dist_to_right), min(dist_to_top, dist_to_bottom));
				float border = selection_border_width * cell_size;

				// Draw border or brighten cell
				if (min_dist < border) {
					final_color = mix(final_color, selection_color, 0.5);
				} else {
					final_color = mix(final_color, vec3(1.0), 0.12);
				}
			}
		}
	}

	ALBEDO = final_color;
}
