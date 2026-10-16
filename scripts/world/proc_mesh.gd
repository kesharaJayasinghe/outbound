extends RefCounted

## Procedural meshes and textures for vegetation and rocks. Everything is generated
## in code, so the project needs no external art assets.
##
## Vertex conventions shared with the shaders:
##   UV2.x = wind sway weight, UV2.y = leaf flutter weight, COLOR.r = per-leaf variation.


## Collects vertex data for one mesh surface.
class Builder:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	func add(v: Vector3, n: Vector3, uv: Vector2, uv2: Vector2, c: Color) -> int:
		verts.append(v)
		normals.append(n)
		uvs.append(uv)
		uv2s.append(uv2)
		colors.append(c)
		return verts.size() - 1

	func tri(a: int, b: int, c: int) -> void:
		indices.append(a)
		indices.append(b)
		indices.append(c)

	func commit(mesh: ArrayMesh, material: Material) -> void:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_TEX_UV2] = uv2s
		arrays[Mesh.ARRAY_COLOR] = colors
		arrays[Mesh.ARRAY_INDEX] = indices
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, material)


## Tapered tube along a polyline (trunks, branches). Uses parallel transport so
## the rings don't twist. UV.y is distance in metres for bark detail.
static func _tube(b: Builder, pts: PackedVector3Array, radii: PackedFloat32Array,
		sway: PackedFloat32Array, sides: int) -> void:
	var n := pts.size()
	var t0 := (pts[1] - pts[0]).normalized()
	var ref := Vector3.FORWARD if absf(t0.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
	var u := t0.cross(ref).normalized()
	var start := b.verts.size()
	var dist := 0.0
	for k in n:
		var t := (pts[mini(k + 1, n - 1)] - pts[maxi(k - 1, 0)]).normalized()
		u = (u - t * u.dot(t)).normalized()
		var w := t.cross(u)
		if k > 0:
			dist += pts[k].distance_to(pts[k - 1])
		for j in sides + 1:
			var th := TAU * j / sides
			var dir := u * cos(th) + w * sin(th)
			b.add(pts[k] + dir * radii[k], dir, Vector2(float(j) / sides, dist), Vector2(sway[k], 0.0), Color.WHITE)
	for k in n - 1:
		for j in sides:
			var a := start + k * (sides + 1) + j
			var c := a + sides + 1
			b.tri(a, c, a + 1)
			b.tri(a + 1, c, c + 1)


## Square leaf card facing roughly along `facing`, lit with `normal`.
static func _card(b: Builder, rng: RandomNumberGenerator, center: Vector3, facing: Vector3,
		normal: Vector3, card_size: float, sway: float, flutter: float) -> void:
	var side_ref := Vector3.UP if absf(facing.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var right := facing.cross(side_ref).normalized()
	var up := right.cross(facing).normalized()
	var spin := rng.randf() * TAU
	var r := (right * cos(spin) + up * sin(spin)) * card_size * 0.5
	var q := (up * cos(spin) - right * sin(spin)) * card_size * 0.5
	var c := Color(rng.randf(), 0.0, 0.0)
	var i0 := b.add(center - r - q, normal, Vector2(0, 1), Vector2(sway, flutter), c)
	var i1 := b.add(center + r - q, normal, Vector2(1, 1), Vector2(sway, flutter), c)
	var i2 := b.add(center + r + q, normal, Vector2(1, 0), Vector2(sway, flutter), c)
	var i3 := b.add(center - r + q, normal, Vector2(0, 0), Vector2(sway, flutter), c)
	b.tri(i0, i2, i1)
	b.tri(i0, i3, i2)


static func _random_unit(rng: RandomNumberGenerator) -> Vector3:
	var v := Vector3(rng.randfn(), rng.randfn(), rng.randfn())
	return v.normalized() if v.length() > 0.0001 else Vector3.UP


## A tuft of tapered, curved grass blades (about 1 m tall before shader scaling).
static func grass_clump(rng: RandomNumberGenerator, material: Material, blades := 7) -> ArrayMesh:
	var b := Builder.new()
	const SEGS = 3
	for i in blades:
		var off := Vector2.from_angle(rng.randf() * TAU) * sqrt(rng.randf()) * 0.14
		var ang := rng.randf() * TAU
		var side := Vector3(cos(ang), 0.0, sin(ang))
		var lean_dir := Vector3(-sin(ang), 0.0, cos(ang)) * (1.0 if rng.randf() < 0.5 else -1.0)
		var h := rng.randf_range(0.35, 0.75)
		var w := rng.randf_range(0.035, 0.06)
		var lean := rng.randf_range(0.1, 0.4)
		var base := Vector3(off.x, 0.0, off.y)
		var first := b.verts.size()
		for k in SEGS + 1:
			var t := float(k) / SEGS
			var center := base + lean_dir * lean * t * t * h + Vector3.UP * h * t
			var tangent := (lean_dir * 2.0 * lean * t * h + Vector3.UP * h).normalized()
			var face := side.cross(tangent).normalized()
			if face.y < 0.0:
				face = -face
			var n := (face * 0.4 + Vector3.UP * 0.6).normalized()
			if k == SEGS:
				b.add(center, n, Vector2(0.5, t), Vector2.ZERO, Color.WHITE)
			else:
				var half := side * w * (1.0 - t * 0.7) * 0.5
				b.add(center - half, n, Vector2(0.0, t), Vector2.ZERO, Color.WHITE)
				b.add(center + half, n, Vector2(1.0, t), Vector2.ZERO, Color.WHITE)
		for k in SEGS - 1:
			var a := first + k * 2
			b.tri(a, a + 2, a + 1)
			b.tri(a + 1, a + 2, a + 3)
		var last := first + (SEGS - 1) * 2
		b.tri(last, last + 2, last + 1)
	var mesh := ArrayMesh.new()
	b.commit(mesh, material)
	return mesh


## Noise-displaced, slightly flattened boulder about 2 m across (scaled per instance).
static func rock(rng: RandomNumberGenerator, material: Material) -> ArrayMesh:
	var sphere := SphereMesh.new()
	sphere.radial_segments = 18
	sphere.rings = 10
	var arrays := sphere.get_mesh_arrays()
	var src: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]

	var noise := FastNoiseLite.new()
	noise.seed = rng.randi()
	noise.frequency = 0.8
	noise.fractal_octaves = 4
	var squash := Vector3(rng.randf_range(0.85, 1.25), rng.randf_range(0.5, 0.8), rng.randf_range(0.85, 1.25))

	var displaced := PackedVector3Array()
	displaced.resize(src.size())
	for i in src.size():
		var d := src[i].normalized()
		var p := d * (1.0 + noise.get_noise_3dv(d * 1.6) * 0.5) * squash
		if p.y < -0.2:
			p.y = -0.2 + (p.y + 0.2) * 0.25 # Flat underside so it sits on the ground
		displaced[i] = p

	# Rebuild from positions only so the UV seam merges and normals stay smooth
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in idx:
		st.add_vertex(displaced[i])
	st.index()
	st.generate_normals()
	st.set_material(material)
	return st.commit()


## Coconut palm: curved ringed trunk with a crown of drooping pinnate fronds.
static func palm(rng: RandomNumberGenerator, bark: Material, fronds: Material) -> ArrayMesh:
	var height := rng.randf_range(7.0, 11.0)
	var lean := rng.randf_range(0.8, 3.0)
	const SEGS = 16

	var trunk := Builder.new()
	var pts := PackedVector3Array()
	var radii := PackedFloat32Array()
	var sway := PackedFloat32Array()
	for k in SEGS + 1:
		var t := float(k) / SEGS
		# Leans out at the base then curves back up towards the light
		pts.append(Vector3(lean * (2.0 * t - t * t), height * t, 0.0))
		radii.append(0.16 + (1.0 - t) * 0.06 + 0.14 * exp(-t * 14.0))
		sway.append(t * t * 0.5)
	_tube(trunk, pts, radii, sway, 8)

	var top := pts[SEGS]
	var leaves := Builder.new()
	var count := rng.randi_range(10, 14)
	for f in count:
		var az := TAU * f / count + rng.randf_range(-0.2, 0.2)
		var elev := rng.randf_range(-0.4, 0.65)
		var length := rng.randf_range(3.2, 4.6)
		var droop := rng.randf_range(0.7, 1.3) + (0.65 - elev) * 0.6
		var age := clampf((0.3 - elev) * 0.8 + rng.randf_range(-0.2, 0.2), 0.0, 1.0)
		var dir0 := Vector3(cos(az) * cos(elev), sin(elev), sin(az) * cos(elev))
		const LEAFLETS = 20
		for i in range(1, LEAFLETS + 1):
			var s := float(i) / LEAFLETS
			var p := top + dir0 * s * length + Vector3.DOWN * droop * s * s * length * 0.5
			var tangent := (dir0 + Vector3.DOWN * droop * s).normalized()
			var side := tangent.cross(Vector3.UP).normalized()
			var leaflet_len := length * 0.3 * pow(sin(PI * minf(s * 1.05, 1.0)), 0.6) + 0.05
			var uv2 := Vector2(0.5 + s * 0.25, s)
			for sgn in [-1.0, 1.0]:
				var ldir: Vector3 = (side * sgn * 0.85 + Vector3.DOWN * 0.45 + tangent * 0.35).normalized()
				var n := tangent.cross(ldir).normalized()
				if n.y < 0.0:
					n = -n
				n = (n + Vector3.UP * 0.5).normalized()
				var c := Color(clampf(age + rng.randf_range(-0.1, 0.1), 0.0, 1.0), 0.0, 0.0)
				var tip := p + ldir * leaflet_len
				var w := length / LEAFLETS * 0.8
				var a := leaves.add(p - tangent * w * 0.5, n, Vector2(0, 1), uv2, c)
				var bb := leaves.add(p + tangent * w * 0.5, n, Vector2(1, 1), uv2, c)
				var t1 := leaves.add(tip, n, Vector2(0, 0), uv2 + Vector2(0.0, 0.3), c)
				var t2 := leaves.add(tip + tangent * w * 0.15, n, Vector2(1, 0), uv2 + Vector2(0.0, 0.3), c)
				leaves.tri(a, t1, bb)
				leaves.tri(bb, t1, t2)

	var mesh := ArrayMesh.new()
	trunk.commit(mesh, bark)
	leaves.commit(mesh, fronds)
	mesh.set_meta(&"crown", top)  # Top of the trunk, where coconuts hang (coconut_cluster)
	return mesh


const CROWN_SWAY = 0.5  # The palm trunk's sway weight at the top (palm's `sway` curve)

## A bunch of 3-6 coconuts hanging just under a palm's crown (`crown` from the palm
## mesh's meta). Drawn with the palm's transform, and swaying as the top of the trunk
## (UV2.x = CROWN_SWAY), so they move with the tree.
static func coconut_cluster(rng: RandomNumberGenerator, crown: Vector3, material: Material) -> ArrayMesh:
	var b := Builder.new()
	var count := rng.randi_range(3, 6)
	var nuts := PackedVector3Array()
	for k in count:
		var az := TAU * k / count + rng.randf_range(-0.3, 0.3)
		var at := crown + Vector3(cos(az) * 0.3, -0.42 - rng.randf_range(0.0, 0.2), sin(az) * 0.3)
		_coconut(b, rng, at, CROWN_SWAY, 1.25)
		nuts.append(at)
	var mesh := ArrayMesh.new()
	b.commit(mesh, material)
	mesh.set_meta(&"nuts", nuts)  # Where each coconut hangs, for knocking them down (pickups.gd)
	return mesh


## One coconut lying on its side on the ground (no sway), resting on y = 0
static func fallen_coconut(rng: RandomNumberGenerator, material: Material) -> ArrayMesh:
	var b := Builder.new()
	# Its widest radius (with the lump) is about 0.11 * 1.15 * 1.06 m, so the centre sits that high
	_coconut(b, rng, Vector3(0.0, 0.135, 0.0), 0.0, 1.15, true)
	var mesh := ArrayMesh.new()
	b.commit(mesh, material)
	return mesh


## A slightly lumpy, egg-shaped coconut (about 25 cm long) centred on `at`
## (`lying`: long axis horizontal, for one on the ground; otherwise hanging, roughly upright)
static func _coconut(b: Builder, rng: RandomNumberGenerator, at: Vector3, sway: float, scale := 1.0, lying := false) -> void:
	const RINGS = 5
	const SIDES = 8
	var size := rng.randf_range(0.9, 1.1) * scale
	var axis := Vector3(rng.randf_range(-0.4, 0.4), 1.0, rng.randf_range(-0.4, 0.4)).normalized()
	if lying:
		axis = Vector3(1.0, 0.0, rng.randf_range(-0.3, 0.3)).normalized()
	var u := axis.cross(Vector3.UP if absf(axis.y) < 0.9 else Vector3.RIGHT).normalized()
	var v := axis.cross(u)
	var first := b.verts.size()
	for r in RINGS + 1:
		var lat := PI * r / RINGS - PI * 0.5
		for k in SIDES:
			var lon := TAU * k / SIDES
			var n := (u * cos(lon) * cos(lat) + v * sin(lon) * cos(lat) + axis * sin(lat)).normalized()
			# Egg-shaped: a little longer along the axis, with a slight three-sided lump
			var radius := 0.11 * size * (1.0 + 0.06 * cos(lon * 3.0))
			var p := at + (u * cos(lon) * cos(lat) + v * sin(lon) * cos(lat)) * radius + axis * sin(lat) * radius * 1.2
			b.add(p, n, Vector2(float(k) / SIDES, float(r) / RINGS * 0.3), Vector2(sway, 0.0), Color.WHITE)
	for r in RINGS:
		for k in SIDES:
			var a := first + r * SIDES + k
			var c := first + r * SIDES + (k + 1) % SIDES
			b.tri(a, a + SIDES, c)
			b.tri(c, a + SIDES, c + SIDES)


## Broadleaf rainforest tree: trunk, a few branches and leaf-card canopy clusters.
static func broadleaf(rng: RandomNumberGenerator, bark: Material, leaf: Material) -> ArrayMesh:
	var height := rng.randf_range(6.0, 10.0)
	var wood := Builder.new()
	var leaves := Builder.new()
	var sway_k := 0.15 / (height * height)  # Stiff trunk; same curve for wood and leaves

	var pts := PackedVector3Array()
	var radii := PackedFloat32Array()
	var sway := PackedFloat32Array()
	var drift := Vector3.ZERO
	const SEGS = 8
	for k in SEGS + 1:
		var t := float(k) / SEGS
		if k > 0:
			drift += Vector3(rng.randf_range(-0.25, 0.25), 0.0, rng.randf_range(-0.25, 0.25))
		var p := Vector3(drift.x, height * t, drift.z)
		pts.append(p)
		radii.append(0.3 - t * 0.16 + 0.22 * exp(-t * 10.0))
		sway.append(p.y * p.y * sway_k)
	_tube(wood, pts, radii, sway, 7)

	var top := pts[SEGS]
	var blobs: Array[Vector3] = [top + Vector3.UP * 1.0]
	var blob_r: Array[float] = [rng.randf_range(2.0, 2.8)]
	for i in rng.randi_range(3, 5):
		var k := rng.randi_range(5, 7)
		var start := pts[k]
		var az := rng.randf() * TAU
		var reach := rng.randf_range(1.8, 3.2)
		var end := start + Vector3(cos(az) * reach, rng.randf_range(1.0, 2.2), sin(az) * reach)
		var mid := (start + end) * 0.5 + Vector3.UP * 0.4
		var bp := PackedVector3Array([start, mid, end])
		var bs := PackedFloat32Array()
		for p in bp:
			bs.append(p.y * p.y * sway_k)
		_tube(wood, bp, PackedFloat32Array([0.12, 0.08, 0.05]), bs, 5)
		blobs.append(end)
		blob_r.append(rng.randf_range(1.5, 2.3))

	var canopy_center := top + Vector3.UP * 0.5
	for bi in blobs.size():
		var center := blobs[bi]
		var radius := blob_r[bi]
		for i in int(radius * radius * 8.0):
			var dir := _random_unit(rng)
			var pos := center + dir * radius * (0.5 + 0.5 * rng.randf())
			pos.y = center.y + (pos.y - center.y) * 0.65  # Canopies are wider than tall
			var out := (pos - canopy_center + Vector3.DOWN * 1.5).normalized()
			var facing := (out + _random_unit(rng) * 0.8).normalized()
			_card(leaves, rng, pos, facing, out, rng.randf_range(1.1, 1.6), pos.y * pos.y * sway_k, 1.0)

	var mesh := ArrayMesh.new()
	wood.commit(mesh, bark)
	leaves.commit(mesh, leaf)
	return mesh


## Low, broad-leaved understorey plant.
static func bush(rng: RandomNumberGenerator, leaf: Material) -> ArrayMesh:
	var b := Builder.new()
	for i in rng.randi_range(2, 3):
		var radius := rng.randf_range(0.6, 1.0)
		var center := Vector3(rng.randf_range(-0.5, 0.5), radius * 0.7, rng.randf_range(-0.5, 0.5))
		for j in int(radius * radius * 16.0):
			var dir := _random_unit(rng)
			dir.y = absf(dir.y) * 0.8 + 0.2
			var pos := center + dir.normalized() * radius * (0.4 + 0.6 * rng.randf())
			var out := (pos - Vector3(0.0, -0.3, 0.0)).normalized()
			var facing := (out + _random_unit(rng) * 0.7).normalized()
			_card(b, rng, pos, facing, out, rng.randf_range(0.6, 0.9), pos.y * 0.04, 0.6)
	var mesh := ArrayMesh.new()
	b.commit(mesh, leaf)
	return mesh


## Paints a cluster of leaves into an RGBA texture. The leaves are near-neutral
## (light, slightly green) so the foliage shader can tint them.
## big = a few large tropical leaves; otherwise many small leaves on a twig.
static func leaf_texture(rng: RandomNumberGenerator, big: bool) -> ImageTexture:
	const SZ = 256
	var img := Image.create(SZ, SZ, false, Image.FORMAT_RGBA8)
	# Leaf-coloured transparent background so mipmaps don't get dark fringes
	img.fill(Color(0.75, 0.85, 0.6, 0.0))
	var count := rng.randi_range(4, 5) if big else rng.randi_range(12, 16)
	for i in count:
		var base: Vector2
		var ang: float
		var length: float
		var width: float
		if big:
			base = Vector2(SZ * 0.5, SZ * 0.95)
			ang = -PI * 0.5 + rng.randf_range(-1.0, 1.0)
			length = rng.randf_range(0.6, 0.85) * SZ
			width = length * rng.randf_range(0.22, 0.3)
		else:
			var t := float(i) / count
			base = Vector2(SZ * 0.5, SZ * (0.95 - t * 0.7))
			ang = -PI * 0.5 + (1.0 if i % 2 == 0 else -1.0) * rng.randf_range(0.5, 1.2) * (1.0 - t * 0.5)
			length = rng.randf_range(0.22, 0.32) * SZ
			width = length * rng.randf_range(0.28, 0.38)
		_paint_leaf(img, base, Vector2.from_angle(ang), length, width, rng.randf_range(0.85, 1.1))
	return ImageTexture.create_from_image(_coverage_mipmaps(img, 0.45))


## Builds the mip chain by hand, rescaling alpha on each level so the area that passes
## the alpha-scissor cut stays the same. Plain mipmaps average alpha down, and distant
## trees would otherwise lose their leaves and look like bare sticks.
static func _coverage_mipmaps(img: Image, cut: float) -> Image:
	var target := _coverage(img.get_data(), cut * 255.0)
	var data := img.get_data()
	var level := img
	var w := img.get_width()
	while w > 1:
		w /= 2
		level = level.duplicate()
		level.resize(w, w, Image.INTERPOLATE_BILINEAR)
		var bytes := level.get_data()
		var lo := 1.0
		var hi := 16.0
		for _i in 10:
			var mid := (lo + hi) * 0.5
			if _coverage(bytes, cut * 255.0 / mid) < target:
				lo = mid
			else:
				hi = mid
		for i in range(3, bytes.size(), 4):
			bytes[i] = mini(255, int(bytes[i] * hi))
		level = Image.create_from_data(w, w, false, Image.FORMAT_RGBA8, bytes)
		data.append_array(bytes)
	return Image.create_from_data(img.get_width(), img.get_height(), true, Image.FORMAT_RGBA8, data)


static func _coverage(rgba: PackedByteArray, threshold: float) -> float:
	var covered := 0
	for i in range(3, rgba.size(), 4):
		if rgba[i] > threshold:
			covered += 1
	return covered * 4.0 / rgba.size()


static func _paint_leaf(img: Image, base: Vector2, dir: Vector2, length: float, width: float, tone: float) -> void:
	var perp := Vector2(-dir.y, dir.x)
	var tip := base + dir * length
	var lo := base.min(tip) - Vector2.ONE * width
	var hi := base.max(tip) + Vector2.ONE * width
	var x0 := clampi(int(lo.x), 0, img.get_width() - 1)
	var x1 := clampi(int(hi.x), 0, img.get_width() - 1)
	var y0 := clampi(int(lo.y), 0, img.get_height() - 1)
	var y1 := clampi(int(hi.y), 0, img.get_height() - 1)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var d := Vector2(x, y) - base
			var u := d.dot(dir) / length
			if u <= 0.0 or u >= 1.0:
				continue
			var v := d.dot(perp) / width
			var half := pow(sin(PI * pow(u, 0.8)), 0.75) * 0.5
			var av := absf(v)
			if av >= half:
				continue
			var shade := 0.78 + 0.22 * (1.0 - av / half)
			if av < 0.025:
				shade *= 0.8   # Midrib
			elif sin((u * 12.0 - av * 6.0) * PI) > 0.92:
				shade *= 0.92  # Side veins
			shade *= tone
			img.set_pixel(x, y, Color(shade * 0.85, shade, shade * 0.72, 1.0))
