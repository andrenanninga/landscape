@tool
class_name TerrainTextureSet
extends Resource

@export var top_albedo: Texture2D
@export var top_normal: Texture2D
@export var side_albedo: Texture2D
@export var side_normal: Texture2D
@export var uv_scale: float = 1.0
@export var slope_threshold: float = 0.7
@export var roughness: float = 0.8
@export var metallic: float = 0.0


func create_material() -> ShaderMaterial:
	var shader := preload("res://addons/landscape/shaders/terrain.gdshader")
	var material := ShaderMaterial.new()
	material.shader = shader

	if top_albedo:
		material.set_shader_parameter("top_albedo", top_albedo)
	if top_normal:
		material.set_shader_parameter("top_normal", top_normal)
	if side_albedo:
		material.set_shader_parameter("side_albedo", side_albedo)
	if side_normal:
		material.set_shader_parameter("side_normal", side_normal)

	material.set_shader_parameter("uv_scale", uv_scale)
	material.set_shader_parameter("slope_threshold", slope_threshold)
	material.set_shader_parameter("roughness", roughness)
	material.set_shader_parameter("metallic", metallic)

	return material
