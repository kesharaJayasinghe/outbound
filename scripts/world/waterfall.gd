extends Node3D

## Draws one waterfall carved by water_carver.gd: a curtain of falling water that
## leaves the lip and arcs down into the plunge pool, churning foam where it lands,
## drifting mist, and the roar of the falls.

const SHEET_SHADER = preload("res://shaders/waterfall.gdshader")
const FOAM_SHADER = preload("res://shaders/waterfall_foam.gdshader")
const ROAR = preload("res://audio/river_rush.wav")

const GRAVITY = 9.8
const LIP_SPEED = 2.2      # Metres per second the water leaves the lip at
const ROWS = 28            # Mesh rows down the fall
const COLUMNS = 10         # Mesh columns across it
const SPREAD = 0.45        # How much wider the curtain gets by the bottom (fraction)


## `fall`: {top (lip centre, metres), dir (downstream, horizontal), drop (metres), width}
func build(fall: Dictionary) -> void:
	var top: Vector3 = fall.top
	var dir: Vector3 = fall.dir
	var drop: float = fall.drop
	var width: float = fall.width
	var side := Vector3(-dir.z, 0.0, dir.x)
	var fall_time := sqrt(2.0 * drop / GRAVITY)
	var landing := top + dir * LIP_SPEED * fall_time + Vector3.DOWN * drop

	add_child(_sheet(top, dir, side, drop, width, fall_time))
	add_child(_foam(landing, width))
	add_child(_mist(landing, width))

	var roar := AudioStreamPlayer3D.new()
	roar.name = "Roar"
	roar.stream = ROAR
	roar.pitch_scale = 0.7       # Deeper and heavier than the river's rapids
	roar.volume_db = 6.0
	roar.unit_size = 14.0
	roar.max_distance = 260.0
	roar.attenuation_filter_cutoff_hz = 2500.0
	roar.autoplay = true
	roar.position = landing + Vector3.UP * drop * 0.3
	add_child(roar)


## The falling curtain. Starts a little upstream on the river surface, curls over the
## lip and follows a ballistic arc. UV.x runs across, UV.y is metres travelled (for the
## streaks); COLOR.r is 0 at the lip and 1 at the pool.
func _sheet(top: Vector3, dir: Vector3, side: Vector3, drop: float, width: float, fall_time: float) -> MeshInstance3D:
	var centre := PackedVector3Array()
	centre.append(top - dir * 1.5)
	centre.append(top - dir * 0.4)
	for r in ROWS + 1:
		var t := fall_time * (float(r) / ROWS) * 1.04  # A touch past the surface, into the pool
		centre.append(top + dir * LIP_SPEED * t + Vector3.DOWN * 0.5 * GRAVITY * t * t)

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var travelled := 0.0
	for r in centre.size():
		if r > 0:
			travelled += centre[r].distance_to(centre[r - 1])
		var frac := clampf((centre[r].y - top.y) / -drop, 0.0, 1.0)
		var tangent := (centre[mini(r + 1, centre.size() - 1)] - centre[maxi(r - 1, 0)]).normalized()
		var normal := tangent.cross(side).normalized()
		var w := width * (1.0 + SPREAD * frac)
		for col in COLUMNS + 1:
			var u := float(col) / COLUMNS
			verts.append(centre[r] + side * (u - 0.5) * w)
			normals.append(normal)
			uvs.append(Vector2(u, travelled))
			colors.append(Color(frac, 0.0, 0.0, 1.0))
	var indices := PackedInt32Array()
	for r in centre.size() - 1:
		for col in COLUMNS:
			var i := r * (COLUMNS + 1) + col
			indices.append_array([i, i + 1, i + COLUMNS + 1, i + 1, i + COLUMNS + 2, i + COLUMNS + 1])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := ShaderMaterial.new()
	mat.shader = SHEET_SHADER
	mat.set_shader_parameter("width_m", width)
	var sheet := MeshInstance3D.new()
	sheet.name = "Sheet"
	sheet.mesh = mesh
	sheet.material_override = mat
	sheet.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return sheet


## Churning white water on the pool where the curtain lands
func _foam(landing: Vector3, width: float) -> MeshInstance3D:
	var plane := PlaneMesh.new()
	plane.size = Vector2.ONE * (width * 2.6 + 4.0)
	var mat := ShaderMaterial.new()
	mat.shader = FOAM_SHADER
	var foam := MeshInstance3D.new()
	foam.name = "Foam"
	foam.mesh = plane
	foam.material_override = mat
	foam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	foam.position = landing + Vector3.UP * 0.06
	return foam


## Soft spray clouds billowing up and out from the landing point
func _mist(landing: Vector3, width: float) -> GPUParticles3D:
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = width * 0.9
	process.direction = Vector3.UP
	process.spread = 80.0
	process.initial_velocity_min = 0.8
	process.initial_velocity_max = 2.4
	process.gravity = Vector3(0.0, 0.25, 0.0)
	process.damping_min = 0.3
	process.damping_max = 0.6
	process.scale_min = 0.6
	process.scale_max = 1.2
	var grow := Curve.new()
	grow.add_point(Vector2(0.0, 0.4))
	grow.add_point(Vector2(1.0, 1.6))
	var grow_tex := CurveTexture.new()
	grow_tex.curve = grow
	process.scale_curve = grow_tex
	var fade := Gradient.new()
	fade.set_color(0, Color(1, 1, 1, 0.0))
	fade.set_color(1, Color(1, 1, 1, 0.0))
	fade.add_point(0.2, Color(1, 1, 1, 0.13))
	fade.add_point(0.6, Color(1, 1, 1, 0.07))
	var fade_tex := GradientTexture1D.new()
	fade_tex.gradient = fade
	process.color_ramp = fade_tex

	var puff := Gradient.new()
	puff.set_color(0, Color(1, 1, 1, 1))
	puff.set_color(1, Color(1, 1, 1, 0))
	var puff_tex := GradientTexture2D.new()
	puff_tex.gradient = puff
	puff_tex.fill = GradientTexture2D.FILL_RADIAL
	puff_tex.fill_from = Vector2(0.5, 0.5)
	puff_tex.fill_to = Vector2(1.0, 0.5)
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(0.92, 0.96, 1.0)
	mat.albedo_texture = puff_tex
	mat.proximity_fade_enabled = true
	mat.proximity_fade_distance = 1.5
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * 5.5
	quad.material = mat

	var mist := GPUParticles3D.new()
	mist.name = "Mist"
	mist.amount = 48
	mist.lifetime = 4.5
	mist.preprocess = 4.5
	mist.process_material = process
	mist.draw_pass_1 = quad
	mist.visibility_aabb = AABB(Vector3(-12, -2, -12), Vector3(24, 16, 24))
	mist.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mist.position = landing + Vector3.UP * 0.3
	return mist
