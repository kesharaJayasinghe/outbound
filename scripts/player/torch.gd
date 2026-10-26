extends Node3D

## A hand-held burning torch: a wooden shaft with a wrapped, smouldering head, a flame of
## additive particles with embers rising off it, a warm flickering light that casts
## shadows, and a crackle. The origin is the grip and +Y runs up the shaft; hotbar.gd
## places it at the hand every frame (it's top-level, like the held stone).
##
## The particles are simulated in world space, so the flame trails behind when the player
## moves and always rises, whichever way the torch tilts.

const SHAFT_LENGTH = 0.62
const GRIP = 0.2              # How far up the shaft the hand holds it (metres from the bottom)
const HEAD_LENGTH = 0.14
const LIGHT_COLOR = Color(1.0, 0.56, 0.24)
const LIGHT_ENERGY = 2.4
const LIGHT_RANGE = 11.0
const CRACKLE = preload("res://audio/fire/torch_fire.wav")
const OWN_LAYER = 1 << 19      # Render layer of the torch's own meshes: its light skips them
                               # (a few centimetres away, it would wash them out)

var lit := true:
	set(value):
		lit = value
		if is_inside_tree():
			_apply_lit()

var flame: GPUParticles3D
var embers: GPUParticles3D
var light: OmniLight3D
var crackle: AudioStreamPlayer3D
var head: MeshInstance3D
var _time := 0.0
var _noise := FastNoiseLite.new()


func _ready() -> void:
	_noise.frequency = 2.5
	_noise.seed = randi()
	var top := SHAFT_LENGTH - GRIP  # Top of the shaft, above the grip

	var shaft := MeshInstance3D.new()
	var stick := CylinderMesh.new()
	stick.top_radius = 0.017
	stick.bottom_radius = 0.022
	stick.height = SHAFT_LENGTH
	stick.radial_segments = 8
	stick.rings = 1
	stick.material = _material(Color(0.36, 0.25, 0.15), 0.85)
	shaft.mesh = stick
	shaft.position.y = top - SHAFT_LENGTH * 0.5
	shaft.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	shaft.layers = OWN_LAYER
	add_child(shaft)

	# Fibre wrapped round the top, charred and glowing where it burns
	head = MeshInstance3D.new()
	var wrap := CylinderMesh.new()
	wrap.top_radius = 0.034
	wrap.bottom_radius = 0.04
	wrap.height = HEAD_LENGTH
	wrap.radial_segments = 10
	wrap.rings = 2
	var charred := _material(Color(0.1, 0.07, 0.05), 1.0)
	charred.emission_enabled = true
	charred.emission = Color(0.9, 0.25, 0.04)
	charred.emission_energy_multiplier = 2.5
	charred.emission_texture = _embers_texture()
	charred.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY  # The default adds, washing it out
	wrap.material = charred
	head.mesh = wrap
	head.position.y = top - HEAD_LENGTH * 0.5 + 0.02
	head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	head.layers = OWN_LAYER
	add_child(head)

	var flame_at := Vector3(0.0, top + 0.07, 0.0)  # Clear of the wrap, or the glow washes it out
	flame = _flame()
	flame.position = flame_at
	add_child(flame)
	embers = _embers()
	embers.position = flame_at
	add_child(embers)

	light = OmniLight3D.new()
	light.light_color = LIGHT_COLOR
	light.light_energy = LIGHT_ENERGY
	light.omni_range = LIGHT_RANGE
	light.light_cull_mask = ~OWN_LAYER
	light.omni_attenuation = 1.3
	light.shadow_enabled = true
	# Two hemispheres instead of six cube faces: about 1 ms instead of 4-5 in the forest
	light.omni_shadow_mode = OmniLight3D.SHADOW_DUAL_PARABOLOID
	light.shadow_bias = 0.08
	light.position = flame_at + Vector3.UP * 0.18
	add_child(light)

	crackle = AudioStreamPlayer3D.new()
	crackle.stream = CRACKLE
	crackle.bus = &"SFX"
	crackle.unit_size = 2.5
	crackle.max_distance = 30.0
	crackle.volume_db = 2.0
	crackle.position = flame_at
	add_child(crackle)
	_apply_lit()


## Shows or hides the whole torch, e.g. when it's put away
func set_shown(shown: bool) -> void:
	if shown == visible:
		return
	visible = shown
	_apply_lit()


func _apply_lit() -> void:
	var burning := lit and visible
	flame.emitting = burning
	embers.emitting = burning
	light.visible = burning
	(head.mesh.material as StandardMaterial3D).emission_enabled = burning
	if burning and not crackle.playing:
		crackle.play(randf() * CRACKLE.get_length())
	elif not burning:
		crackle.stop()


func _process(delta: float) -> void:
	if not light.visible:
		return
	# Flicker: two speeds of noise, with the odd deeper dip
	_time += delta
	var n := _noise.get_noise_1d(_time) * 0.6 + _noise.get_noise_1d(_time * 3.7 + 40.0) * 0.4
	light.light_energy = LIGHT_ENERGY * (0.88 + 0.22 * n)
	light.position.x = n * 0.03
	light.position.z = _noise.get_noise_1d(_time * 1.3 + 90.0) * 0.03


func _material(colour: Color, roughness: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = colour
	m.roughness = roughness
	return m


func _flame() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = 64
	p.lifetime = 0.55
	p.local_coords = false
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.visibility_aabb = AABB(Vector3(-1.0, -0.5, -1.0), Vector3(2.0, 2.0, 2.0))
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.emission_sphere_radius = 0.03
	m.direction = Vector3.UP
	m.spread = 12.0
	m.initial_velocity_min = 0.35
	m.initial_velocity_max = 0.75
	m.gravity = Vector3(0.0, 1.4, 0.0)   # Hot air rises
	m.damping_min = 0.6
	m.damping_max = 1.2
	m.scale_min = 0.7
	m.scale_max = 1.25
	m.angle_min = -180.0
	m.angle_max = 180.0
	m.scale_curve = _curve_texture([Vector2(0.0, 0.55), Vector2(0.25, 1.0), Vector2(1.0, 0.15)])
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.2, 0.55, 1.0])
	ramp.colors = PackedColorArray([Color(1.0, 0.8, 0.45, 0.9), Color(1.0, 0.52, 0.14, 0.8),
			Color(0.85, 0.22, 0.04, 0.45), Color(0.3, 0.05, 0.01, 0.0)])
	var ramp_tex := GradientTexture1D.new()
	ramp_tex.gradient = ramp
	m.color_ramp = ramp_tex
	p.process_material = m
	p.draw_pass_1 = _glow_quad(0.17, 0.8)
	return p


func _embers() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = 10
	p.lifetime = 1.3
	p.randomness = 0.6
	p.local_coords = false
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.visibility_aabb = AABB(Vector3(-1.5, -0.5, -1.5), Vector3(3.0, 3.5, 3.0))
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.emission_sphere_radius = 0.04
	m.direction = Vector3.UP
	m.spread = 30.0
	m.initial_velocity_min = 0.5
	m.initial_velocity_max = 1.3
	m.gravity = Vector3(0.0, 0.6, 0.0)
	m.damping_min = 0.3
	m.damping_max = 0.8
	m.turbulence_enabled = true
	m.turbulence_noise_strength = 1.5
	m.turbulence_influence_min = 0.05
	m.turbulence_influence_max = 0.15
	m.scale_curve = _curve_texture([Vector2(0.0, 1.0), Vector2(1.0, 0.0)])
	var ramp := Gradient.new()
	ramp.colors = PackedColorArray([Color(1.0, 0.75, 0.35, 1.0), Color(1.0, 0.3, 0.05, 0.0)])
	var ramp_tex := GradientTexture1D.new()
	ramp_tex.gradient = ramp
	m.color_ramp = ramp_tex
	p.process_material = m
	p.draw_pass_1 = _glow_quad(0.018, 3.0)
	return p


## A soft round billboard, added on top of what's behind it (fire gives off light)
func _glow_quad(size: float, energy: float) -> QuadMesh:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(energy, energy, energy)
	mat.albedo_texture = _soft_dot()
	mat.disable_receive_shadows = true
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	quad.material = mat
	return quad


## Glowing cracks for the burning wrap: bright where noise peaks, dark char elsewhere
func _embers_texture() -> ImageTexture:
	var noise := FastNoiseLite.new()
	noise.frequency = 0.12
	var img := Image.create(64, 32, false, Image.FORMAT_RGB8)
	for y in 32:
		for x in 64:
			var v := smoothstep(0.15, 0.55, noise.get_noise_2d(x, y * 2.0) * 0.5 + 0.5)
			v *= lerpf(0.4, 1.0, float(31 - y) / 31.0)  # Hotter towards the top
			img.set_pixel(x, y, Color(v, v, v))
	return ImageTexture.create_from_image(img)


func _curve_texture(points: Array) -> CurveTexture:
	var curve := Curve.new()
	for pt: Vector2 in points:
		curve.add_point(pt)
	var tex := CurveTexture.new()
	tex.curve = curve
	return tex


func _soft_dot() -> ImageTexture:
	var n := 32
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var r := Vector2(x + 0.5 - n * 0.5, y + 0.5 - n * 0.5).length() / (n * 0.5)
			var a := clampf(1.0 - smoothstep(0.0, 1.0, r), 0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a * a))
	return ImageTexture.create_from_image(img)
