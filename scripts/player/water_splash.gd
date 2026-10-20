extends Node3D

## Splashes kicked up by steps in shallow water (and jumping in). Each one is a burst of
## droplets thrown up and forward from the foot, plus a foam ring that spreads on the
## water surface and fades. A fixed pool of emitters and rings is reused oldest-first,
## so nothing is allocated while playing; idle ones are hidden.

const POOL_SIZE = 8           # Sprinting through water makes about three steps a second
const DROPLETS = 48           # Per splash at full strength
const DROPLET_LIFETIME = 0.8
const RING_TIME = 0.9         # Seconds for a foam ring to spread and fade
const RING_SIZE = Vector2(0.25, 1.1)  # Ring diameter at the start and end (metres, strength 1)

var _emitters: Array[GPUParticles3D] = []
var _rings: Array[MeshInstance3D] = []
var _ages := PackedFloat32Array()
var _sizes := PackedFloat32Array()
var _next := 0


func _ready() -> void:
	top_level = true  # Splashes stay where they were made, not on the moving player
	global_transform = Transform3D.IDENTITY
	var droplet := _droplet_mesh()
	var ring_material := ShaderMaterial.new()
	ring_material.shader = preload("res://shaders/splash_ring.gdshader")
	ring_material.render_priority = 1  # Over the (transparent) water surface
	var ring_mesh := PlaneMesh.new()
	ring_mesh.size = Vector2.ONE
	ring_mesh.material = ring_material
	_ages.resize(POOL_SIZE)
	_sizes.resize(POOL_SIZE)
	_ages.fill(RING_TIME)
	for i in POOL_SIZE:
		var p := GPUParticles3D.new()
		p.amount = DROPLETS
		p.lifetime = DROPLET_LIFETIME
		p.one_shot = true
		p.explosiveness = 0.85
		p.emitting = false
		p.local_coords = false
		p.process_material = _droplet_process()
		p.draw_pass_1 = droplet
		p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		p.visibility_aabb = AABB(Vector3(-2.0, -1.0, -2.0), Vector3(4.0, 3.0, 4.0))
		add_child(p)
		_emitters.append(p)
		var ring := MeshInstance3D.new()
		ring.mesh = ring_mesh
		ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		ring.visible = false
		add_child(ring)
		_rings.append(ring)


## A splash at `pos` (on the water surface). `motion` is the walker's horizontal
## velocity: the spray is kicked along it. `strength` is about 0.5 (walking) to 1.5
## (jumping in).
func add(pos: Vector3, motion: Vector3, strength: float) -> void:
	var i := _next
	_next = (_next + 1) % POOL_SIZE

	var p := _emitters[i]
	var m := p.process_material as ParticleProcessMaterial
	var kick := Vector3(motion.x, 0.0, motion.z) * 0.12
	m.direction = (Vector3.UP + kick).normalized()
	m.initial_velocity_min = 1.3 * strength
	m.initial_velocity_max = 3.4 * strength
	m.emission_sphere_radius = 0.06 + 0.06 * strength
	p.amount_ratio = clampf(0.35 + 0.5 * strength, 0.0, 1.0)
	p.global_position = pos
	p.restart()

	var ring := _rings[i]
	ring.global_position = pos + Vector3.UP * 0.05  # Clear of the wave crests
	ring.rotation.y = randf() * TAU
	ring.visible = true
	_ages[i] = 0.0
	_sizes[i] = clampf(strength, 0.4, 1.6)
	_update_ring(i)


func _process(delta: float) -> void:
	for i in POOL_SIZE:
		if _ages[i] >= RING_TIME:
			continue
		_ages[i] += delta
		if _ages[i] >= RING_TIME:
			_rings[i].visible = false
		else:
			_update_ring(i)


func _update_ring(i: int) -> void:
	var t := _ages[i] / RING_TIME
	var spread := 1.0 - pow(1.0 - t, 2.5)  # Fast at first, then slowing
	var diameter := lerpf(RING_SIZE.x, RING_SIZE.y, spread) * _sizes[i]
	var ring := _rings[i]
	ring.scale = Vector3(diameter, 1.0, diameter)
	ring.set_instance_shader_parameter(&"age", t)


func _droplet_process() -> ParticleProcessMaterial:
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.emission_sphere_radius = 0.1
	m.direction = Vector3.UP
	m.spread = 28.0
	m.gravity = Vector3(0.0, -9.8, 0.0)
	m.damping_min = 0.5
	m.damping_max = 1.5
	m.scale_min = 0.35
	m.scale_max = 1.9
	var shrink := Curve.new()
	shrink.add_point(Vector2(0.0, 1.0))
	shrink.add_point(Vector2(1.0, 0.35))
	var shrink_tex := CurveTexture.new()
	shrink_tex.curve = shrink
	m.scale_curve = shrink_tex
	var fade := Gradient.new()
	fade.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
	fade.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	fade.add_point(0.65, Color(1.0, 1.0, 1.0, 0.85))
	var fade_tex := GradientTexture1D.new()
	fade_tex.gradient = fade
	m.color_ramp = fade_tex
	return m


## A small soft-edged billboard: white spray, unshaded so it reads against the water
func _droplet_mesh() -> QuadMesh:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(0.93, 0.96, 1.0, 0.75)
	mat.albedo_texture = _soft_dot()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.042, 0.042)
	quad.material = mat
	return quad


func _soft_dot() -> ImageTexture:
	var n := 32
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var r := Vector2(x + 0.5 - n * 0.5, y + 0.5 - n * 0.5).length() / (n * 0.5)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, clampf(1.0 - smoothstep(0.15, 1.0, r), 0.0, 1.0)))
	return ImageTexture.create_from_image(img)
