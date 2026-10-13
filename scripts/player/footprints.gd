extends Node3D

## Footprint trail left in sand. A fixed pool of Decals is reused oldest-first, so
## nothing is allocated while playing. Each print stays for LIFETIME seconds, fades out
## over FADE seconds and is then hidden (a hidden Decal costs nothing). Per frame the CPU
## only ages the visible prints, and the GPU stops drawing them beyond DRAW_DISTANCE.

const POOL_SIZE = 48          # Enough for ~15 s of sprinting before the oldest is reused
const LIFETIME = 12.0         # Seconds fully visible
const FADE = 3.0              # Seconds to fade out
const DRAW_DISTANCE = 35.0    # Decals fade out between here and DRAW_DISTANCE + 10 m
const PRINT_SIZE = Vector3(0.16, 0.5, 0.34)  # Width, projection depth, length (metres)
const TEX_W = 64
const TEX_H = 128

var _decals: Array[Decal] = []
var _ages := PackedFloat32Array()
var _next := 0
var _active := 0
var _left: Array[Texture2D] = []   # [albedo, normal]
var _right: Array[Texture2D] = []


func _ready() -> void:
	top_level = true  # Prints stay where they were made, not on the moving player
	global_transform = Transform3D.IDENTITY
	_left = _make_textures(false)
	_right = _make_textures(true)
	_ages.resize(POOL_SIZE)
	for i in POOL_SIZE:
		var d := Decal.new()
		d.size = PRINT_SIZE
		d.albedo_mix = 0.85
		d.normal_fade = 0.5
		d.distance_fade_enabled = true
		d.distance_fade_begin = DRAW_DISTANCE
		d.distance_fade_length = 10.0
		d.visible = false
		add_child(d)
		_decals.append(d)


## Exclude render layers (e.g. the character's own body) from receiving prints.
func set_excluded_layers(layers: int) -> void:
	for d in _decals:
		d.cull_mask = 0xFFFFF & ~layers


## Leaves a print at `pos` (on the ground) with the toes pointing along `yaw`.
func add(pos: Vector3, yaw: float, left_foot: bool) -> void:
	var d := _decals[_next]
	if not d.visible:
		_active += 1
	var tex := _left if left_foot else _right
	d.texture_albedo = tex[0]
	d.texture_normal = tex[1]
	d.global_transform = Transform3D(Basis(Vector3.UP, yaw), pos)
	d.modulate.a = 1.0
	d.visible = true
	_ages[_next] = 0.0
	_next = (_next + 1) % POOL_SIZE


func _process(delta: float) -> void:
	if _active == 0:
		return
	for i in POOL_SIZE:
		var d := _decals[i]
		if not d.visible:
			continue
		_ages[i] += delta
		if _ages[i] > LIFETIME:
			var a := 1.0 - (_ages[i] - LIFETIME) / FADE
			if a <= 0.0:
				d.visible = false
				_active -= 1
			else:
				d.modulate.a = a


## Paints a bare-foot print: heel, arch, ball of the foot and five toes. Returns
## [albedo, normal map]. Toes are at the top of the image, which the decal maps to
## its -Z (forward). The right foot is the mirror image of the left.
func _make_textures(right_foot: bool) -> Array[Texture2D]:
	# Depression depth (0..1) per pixel, as a soft union of ellipses
	var depth := PackedFloat32Array()
	depth.resize(TEX_W * TEX_H)
	# [centre u, centre v, radius u, radius v, depth] for a left foot (big toe on the right)
	var parts := [
		[0.48, 0.80, 0.32, 0.16, 1.0],   # Heel
		[0.36, 0.60, 0.25, 0.26, 0.85],  # Outer edge of the sole (the inner arch stays shallow)
		[0.52, 0.39, 0.40, 0.16, 0.95],  # Ball of the foot
		[0.76, 0.18, 0.12, 0.09, 0.9],   # Big toe
		[0.57, 0.14, 0.08, 0.06, 0.8],
		[0.43, 0.15, 0.07, 0.055, 0.75],
		[0.31, 0.18, 0.065, 0.05, 0.7],
		[0.20, 0.23, 0.06, 0.045, 0.65],
	]
	for y in TEX_H:
		for x in TEX_W:
			var u := (x + 0.5) / TEX_W
			if right_foot:
				u = 1.0 - u
			var v := (y + 0.5) / TEX_H
			var d := 0.0
			for p in parts:
				var du: float = (u - p[0]) / p[2]
				var dv: float = (v - p[1]) / p[3]
				d = maxf(d, (1.0 - smoothstep(0.6, 1.0, sqrt(du * du + dv * dv))) * p[4])
			depth[y * TEX_W + x] = d

	var albedo := Image.create(TEX_W, TEX_H, false, Image.FORMAT_RGBA8)
	var normal := Image.create(TEX_W, TEX_H, false, Image.FORMAT_RGBA8)
	for y in TEX_H:
		for x in TEX_W:
			var d := depth[y * TEX_W + x]
			# Compressed sand is a little darker and slightly damp-looking
			var shade := 1.0 - 0.35 * d
			albedo.set_pixel(x, y, Color(0.66 * shade, 0.59 * shade, 0.46 * shade, smoothstep(0.02, 0.3, d)))
			# Normal from the depression's slope (OpenGL convention: green points up the image)
			var dx := depth[y * TEX_W + mini(x + 1, TEX_W - 1)] - depth[y * TEX_W + maxi(x - 1, 0)]
			var dy := depth[mini(y + 1, TEX_H - 1) * TEX_W + x] - depth[maxi(y - 1, 0) * TEX_W + x]
			var n := Vector3(dx * 6.0, -dy * 6.0, 1.0).normalized()
			normal.set_pixel(x, y, Color(n.x * 0.5 + 0.5, n.y * 0.5 + 0.5, n.z * 0.5 + 0.5, smoothstep(0.02, 0.35, d)))
	albedo.generate_mipmaps()
	normal.generate_mipmaps()
	var textures: Array[Texture2D] = [ImageTexture.create_from_image(albedo), ImageTexture.create_from_image(normal)]
	return textures
