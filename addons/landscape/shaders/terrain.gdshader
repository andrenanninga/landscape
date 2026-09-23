shader_type spatial;
render_mode unshaded;

// Fallback look when no tile set is assigned: a flat, unlit two-tone checkerboard whose
// colors depend on which face of the cell is drawn. Faces are identified through the
// surface type TerrainMeshBuilder stores in the vertex color alpha.

uniform vec3 color_top : source_color = vec3(0.18, 0.42, 0.18);
uniform vec3 color_floor : source_color = vec3(0.10, 0.07, 0.04);
uniform vec3 color_north : source_color = vec3(0.30, 0.22, 0.14);
uniform vec3 color_east : source_color = vec3(0.42, 0.32, 0.20);
uniform vec3 color_south : source_color = vec3(0.38, 0.28, 0.18);
uniform vec3 color_west : source_color = vec3(0.26, 0.20, 0.13);

uniform vec3 checker_color_top : source_color = vec3(0.14, 0.34, 0.14);
uniform vec3 checker_color_floor : source_color = vec3(0.07, 0.05, 0.03);
uniform vec3 checker_color_north : source_color = vec3(0.24, 0.18, 0.11);
uniform vec3 checker_color_east : source_color = vec3(0.36, 0.27, 0.17);
uniform vec3 checker_color_south : source_color = vec3(0.32, 0.24, 0.15);
uniform vec3 checker_color_west : source_color = vec3(0.21, 0.16, 0.10);

// Checker squares per world unit
uniform float checker_scale : hint_range(0.5, 8.0) = 4.0;

const int SURFACE_TOP = 0;
const int SURFACE_NORTH = 1;
const int SURFACE_EAST = 2;
const int SURFACE_SOUTH = 3;
const int SURFACE_WEST = 4;
const int SURFACE_FLOOR = 5;
const int SURFACE_FENCE_NORTH = 6;
const int SURFACE_TYPE_COUNT = 10;

varying vec3 world_position;
varying flat int surface_type;
varying vec3 vertex_color;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	surface_type = int(round(COLOR.a * float(SURFACE_TYPE_COUNT - 1)));
	vertex_color = COLOR.rgb;
}

void get_surface_colors(int surface, out vec3 primary, out vec3 secondary) {
	if (surface == SURFACE_TOP) {
		primary = color_top;
		secondary = checker_color_top;
	} else if (surface == SURFACE_FLOOR) {
		primary = color_floor;
		secondary = checker_color_floor;
	} else if (surface == SURFACE_NORTH) {
		primary = color_north;
		secondary = checker_color_north;
	} else if (surface == SURFACE_EAST) {
		primary = color_east;
		secondary = checker_color_east;
	} else if (surface == SURFACE_SOUTH) {
		primary = color_south;
		secondary = checker_color_south;
	} else {
		primary = color_west;
		secondary = checker_color_west;
	}
}

// Checker value (0 or 1) on the plane the face lies in
float get_checker(vec3 pos, int surface) {
	vec2 checker_uv;
	if (surface == SURFACE_TOP || surface == SURFACE_FLOOR) {
		checker_uv = pos.xz;
	} else if (surface == SURFACE_NORTH || surface == SURFACE_SOUTH) {
		checker_uv = pos.xy;
	} else {
		checker_uv = pos.zy;
	}

	vec2 grid = floor(checker_uv * checker_scale);
	return mod(grid.x + grid.y, 2.0);
}

void fragment() {
	// Fences take the colors of the wall facing the same way (6..9 -> 1..4)
	int surface = surface_type >= SURFACE_FENCE_NORTH ? surface_type - SURFACE_FENCE_NORTH + SURFACE_NORTH : surface_type;

	vec3 primary_color;
	vec3 secondary_color;
	get_surface_colors(surface, primary_color, secondary_color);

	float checker = get_checker(world_position, surface);
	ALBEDO = mix(primary_color, secondary_color, checker) * vertex_color;
}
