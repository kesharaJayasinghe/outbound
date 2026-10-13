extends RefCounted

## Carves a lake and a river into the generator's terrain and fills in its inland-water
## data. Runs after the beaches and seabed are shaped, before baking.
##
## 1. A lake goes in a hilly basin well inland: a bowl with a ragged shoreline and a rim
##    that keeps the water in.
## 2. The river is the cheapest route from the lake shore to the sea, where climbing is
##    heavily penalised, so it follows valleys downhill.
## 3. Its surface never rises along its length: it starts at the lake level and steps
##    down to sea level, cutting through any rise in the way. The channel widens and
##    deepens downstream, and the banks are shaped up or down to meet the water.
##
## Writes gen.heights, gen.water_height, gen.inland_mask, gen.flow_map and gen.deposit_map.

const BANK_WIDTH = 6.0        # Metres of bank shaping either side of the channel (minimum)
const BANK_ABOVE_WATER = 0.35 # Banks finish this far above the water surface
const RIM_RAISE = 0.35        # Lake rim is kept at least this far above the lake surface


## Returns a short description of what was carved, or "" if no lake site was found.
static func carve(gen: Node3D) -> String:
	var size: int = gen.size
	var cell: float = gen.cell_size
	var max_h: float = gen.max_height
	var sea: float = gen.water_level * max_h
	var count := size * size

	# Work in metres
	var h := PackedFloat32Array()
	h.resize(count)
	for i in count:
		h[i] = gen.heights[i] * max_h
	var surface := PackedFloat32Array()
	surface.resize(count)
	surface.fill(sea)
	var inland := PackedFloat32Array()
	inland.resize(count)
	var flow: PackedFloat32Array = gen.flow_map
	var deposit: PackedFloat32Array = gen.deposit_map

	var shape_noise := FastNoiseLite.new()
	shape_noise.seed = gen.terrain_seed + 1013
	shape_noise.frequency = 0.03

	# --- 1. Lake --------------------------------------------------------------------
	var coast := _coast_distance(h, size, sea)
	var radius: float = gen.lake_radius
	var site := _find_lake_site(h, flow, coast, size, cell, sea, max_h, radius)
	if site.x < 0:
		return ""
	var c := Vector2(site.x, site.y)
	var ci := site.y * size + site.x
	var ring_min := _ring_min(h, size, c, radius / cell)
	var lake_level := h[ci] + clampf(ring_min - h[ci] - 0.6, 1.0, 4.0)

	var lake_t := PackedFloat32Array()  # Normalised distance from the lake centre (1 = shore)
	lake_t.resize(count)
	lake_t.fill(INF)
	var reach := int(radius * 1.9 / cell) + 2
	for z in range(maxi(site.y - reach, 0), mini(site.y + reach + 1, size)):
		for x in range(maxi(site.x - reach, 0), mini(site.x + reach + 1, size)):
			var i := z * size + x
			var wx := x * cell
			var wz := z * cell
			var r_eff := radius * (1.0 + 0.28 * shape_noise.get_noise_2d(wx, wz))
			var t := Vector2(x, z).distance_to(c) * cell / r_eff
			lake_t[i] = t
			if t < 1.0:
				var bed: float = lake_level - 0.25 - gen.lake_depth * pow(1.0 - t * t, 0.6)
				h[i] = minf(h[i], bed)
				deposit[i] = 0.0
			elif t < 1.9:
				# Keep the surrounding ground above the water so the lake stays contained:
				# a full rim out past where the water mesh ends, then easing back to the land
				var rim := lake_level + RIM_RAISE + (t - 1.0) * 2.0
				h[i] = maxf(h[i], lerpf(rim, h[i], smoothstep(1.35, 1.9, t)))
			if t < 1.75:
				surface[i] = lake_level
			inland[i] = maxf(inland[i], 1.0 - smoothstep(0.95, 1.1, t))
			flow[i] = maxf(flow[i], 1.0 - smoothstep(1.0, 1.4, t))

	# --- 2. River route -------------------------------------------------------------
	var path := _route_to_sea(h, lake_t, _open_ocean(h, size, sea), size, cell, sea, shape_noise)
	if path.size() < 2:
		gen.heights = _to_normalised(h, max_h)
		gen.water_height = _to_normalised(surface, max_h)
		gen.inland_mask = inland
		gen.flow_map = flow
		gen.deposit_map = deposit
		return "lake at %s (level %.1f m), no route to the sea" % [_world(c, size, cell), lake_level]
	# Start inside the lake so the channel joins it cleanly, then smooth the grid path
	var into_lake := c + (path[0] - c) * 0.75
	path.insert(0, into_lake)
	path = _resample(_chaikin(_chaikin(path)), 1.0)
	path = _resample(_meander(path, shape_noise, cell), 1.0)

	# --- 3. Surface profile: never rising, cutting through any rise in the way -------
	var n := path.size()
	var s := PackedFloat32Array()
	s.resize(n)
	# Limit how far the surface can drop per step so there are no hard steps: a few
	# times the average gradient, never less than a gentle rapid
	var max_drop := maxf(0.25, 2.5 * (lake_level - sea) / (n - 1))
	s[0] = lake_level
	for k in range(1, n):
		var ground := _sample(h, size, path[k])
		s[k] = clampf(ground - 0.4, s[k - 1] - max_drop, s[k - 1])
	# Backwards from the sea, so the last stretch can also reach sea level within the limit
	s[n - 1] = sea
	for k in range(n - 2, -1, -1):
		s[k] = minf(s[k], s[k + 1] + max_drop)
	s[0] = lake_level
	for _pass in 4:  # Smooth, then restore the never-rising rule
		var sm := s.duplicate()
		for k in range(1, n - 1):
			sm[k] = (s[maxi(k - 2, 0)] + s[k - 1] + s[k] + s[k + 1] + s[mini(k + 2, n - 1)]) / 5.0
		s = sm
		s[0] = lake_level
		for k in range(1, n):
			s[k] = clampf(s[k], sea, s[k - 1])
	s[n - 1] = sea

	# --- 4. Carve the channel and banks ----------------------------------------------
	var river_width: float = gen.river_width
	var river_depth: float = gen.river_depth
	var best_d := PackedFloat32Array()
	best_d.resize(count)
	best_d.fill(INF)
	var best_s := PackedFloat32Array()
	best_s.resize(count)
	var best_w := PackedFloat32Array()
	best_w.resize(count)
	var best_depth := PackedFloat32Array()
	best_depth.resize(count)
	var original := h.duplicate()
	var max_reach := int((river_width + 30.0) / cell) + 1
	for k in n - 1:
		var a := path[k]
		var b := path[k + 1]
		var along := float(k) / (n - 1)
		var half_w := river_width * 0.5 * lerpf(0.8, 1.4, along)
		var depth := river_depth * lerpf(0.8, 1.3, along)
		for z in range(maxi(int(minf(a.y, b.y)) - max_reach, 0), mini(int(maxf(a.y, b.y)) + max_reach + 1, size)):
			for x in range(maxi(int(minf(a.x, b.x)) - max_reach, 0), mini(int(maxf(a.x, b.x)) + max_reach + 1, size)):
				var p := Vector2(x, z)
				var ab := b - a
				var u := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
				var d := p.distance_to(a + ab * u) * cell
				var i := z * size + x
				if d < best_d[i]:
					best_d[i] = d
					best_s[i] = lerpf(s[k], s[k + 1], u)
					best_w[i] = half_w
					best_depth[i] = depth
	for i in count:
		var d := best_d[i]
		if d == INF:
			continue
		var w := best_w[i]
		var water := best_s[i]
		var at_sea := water <= sea + 0.02
		var bank_top := water + BANK_ABOVE_WATER
		var bank_w := clampf(absf(original[i] - bank_top) * 1.5, BANK_WIDTH, 20.0)
		if d < w:
			# Even at the channel's edge the bed stays a little under water
			h[i] = minf(h[i], water - 0.15 - best_depth[i] * (1.0 - (d / w) * (d / w)))
			deposit[i] = 0.0
		elif d < w + bank_w + 3.0 * cell and lake_t[i] >= 1.0:
			# Banks: bring the ground to just above the water. Higher ground is cut down
			# from the water's edge; low ground is built up as a levee that stays at full
			# height past the edge of the water mesh, so the river can't show over it.
			# Ground already under the sea is left alone: there the river opens into the
			# sea, and a levee would raise a sand bar across the mouth.
			if original[i] > bank_top:
				h[i] = lerpf(bank_top, h[i], smoothstep(w, w + bank_w, d))
			elif original[i] > sea:
				h[i] = maxf(h[i], lerpf(bank_top, h[i], smoothstep(w + 2.5 * cell, w + 2.5 * cell + bank_w, d)))
		if not at_sea:
			if d < w + bank_w + 2.0 * cell and lake_t[i] >= 1.0:
				surface[i] = water
			# Fades out just above sea level so the river's surface hands over to the sea
			# plane at the mouth instead of overlapping it
			inland[i] = maxf(inland[i], (1.0 - smoothstep(w, w + cell, d)) * smoothstep(sea + 0.03, sea + 0.8, water))
		flow[i] = maxf(flow[i], 1.0 - smoothstep(w, w + bank_w, d))

	gen.heights = _to_normalised(h, max_h)
	gen.water_height = _to_normalised(surface, max_h)
	gen.inland_mask = inland
	gen.flow_map = flow
	gen.deposit_map = deposit
	return "lake at %s (level %.1f m, radius %.0f m) and a %.0f m river dropping to the sea" % [
			_world(c, size, cell), lake_level, radius, (n - 1) * cell]


# --- Helpers ------------------------------------------------------------------------

## Breadth-first distance (in cells) from every vertex to the nearest sea vertex.
static func _coast_distance(h: PackedFloat32Array, size: int, sea: float) -> PackedInt32Array:
	var dist := PackedInt32Array()
	dist.resize(size * size)
	dist.fill(-1)
	var queue := PackedInt32Array()
	for i in size * size:
		if h[i] < sea:
			dist[i] = 0
			queue.append(i)
	var head := 0
	while head < queue.size():
		var i := queue[head]
		head += 1
		var x := i % size
		var z := i / size
		for o in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nx: int = x + o.x
			var nz: int = z + o.y
			if nx < 0 or nz < 0 or nx >= size or nz >= size:
				continue
			var j := nz * size + nx
			if dist[j] < 0:
				dist[j] = dist[i] + 1
				queue.append(j)
	return dist


## Best lake centre: inland, in the hills but below the peaks, not steep, and ideally in
## a valley (high drainage flow) or a natural basin.
static func _find_lake_site(h: PackedFloat32Array, flow: PackedFloat32Array, coast: PackedInt32Array,
		size: int, cell: float, sea: float, max_h: float, radius: float) -> Vector2i:
	var r_cells := radius / cell
	var best := Vector2i(-1, -1)
	var best_score := -INF
	var margin := int(r_cells * 2.0) + 2
	for z in range(margin, size - margin, 2):
		for x in range(margin, size - margin, 2):
			var i := z * size + x
			if coast[i] < r_cells + 20 or h[i] < sea + 10.0 or h[i] > sea + 0.55 * max_h:
				continue
			var slope := (absf(h[i + 1] - h[i - 1]) + absf(h[i + size] - h[i - size])) / (4.0 * cell)
			if slope > 0.35:
				continue
			var basin := _ring_min(h, size, Vector2(x, z), r_cells) - h[i]
			var score := clampf(basin, -6.0, 6.0) + flow[i] * 6.0 - slope * 12.0 + coast[i] * 0.06
			if score > best_score:
				best_score = score
				best = Vector2i(x, z)
	return best


static func _ring_min(h: PackedFloat32Array, size: int, c: Vector2, r_cells: float) -> float:
	var lo := INF
	for a in 16:
		var p := c + Vector2.from_angle(TAU * a / 16.0) * r_cells
		lo = minf(lo, _sample(h, size, p))
	return lo


## Marks (1) the below-sea-level vertices connected to the map edge: the open ocean, as
## opposed to enclosed hollows behind the beach that merely dip below sea level.
static func _open_ocean(h: PackedFloat32Array, size: int, sea: float) -> PackedByteArray:
	var ocean := PackedByteArray()
	ocean.resize(size * size)
	var queue := PackedInt32Array()
	for k in size:
		for i in [k, (size - 1) * size + k, k * size, k * size + size - 1]:
			if h[i] < sea and ocean[i] == 0:
				ocean[i] = 1
				queue.append(i)
	var head := 0
	while head < queue.size():
		var i := queue[head]
		head += 1
		var x := i % size
		var z := i / size
		for o in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nx: int = x + o.x
			var nz: int = z + o.y
			if nx < 0 or nz < 0 or nx >= size or nz >= size:
				continue
			var j := nz * size + nx
			if ocean[j] == 0 and h[j] < sea:
				ocean[j] = 1
				queue.append(j)
	return ocean


## Cheapest path (Dijkstra) from the lake shore to the open ocean. Moving costs more on high
## ground and much more uphill, so the route follows valleys down to the coast; noise
## in the cost makes it meander.
static func _route_to_sea(h: PackedFloat32Array, lake_t: PackedFloat32Array, ocean: PackedByteArray,
		size: int, cell: float, sea: float, wander: FastNoiseLite) -> PackedVector2Array:
	var count := size * size
	var cost := PackedFloat32Array()
	cost.resize(count)
	cost.fill(INF)
	var prev := PackedInt32Array()
	prev.resize(count)
	prev.fill(-1)
	var heap := MinHeap.new()
	for i in count:
		if lake_t[i] >= 1.0 and lake_t[i] < 1.15:
			cost[i] = 0.0
			heap.push(0.0, i)
	var goal := -1
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
			Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1)]
	while not heap.is_empty():
		var c := heap.peek_cost()
		var i := heap.pop()
		if c > cost[i]:
			continue
		if ocean[i] == 1 and h[i] < sea - 0.5:
			goal = i
			break
		var x := i % size
		var z := i / size
		for o in dirs:
			var nx: int = x + o.x
			var nz: int = z + o.y
			if nx < 1 or nz < 1 or nx >= size - 1 or nz >= size - 1:
				continue
			var j := nz * size + nx
			if lake_t[j] < 1.0:
				continue
			var step := 1.4142 if o.x != 0 and o.y != 0 else 1.0
			# Noise in the cost makes the route wander, so the river meanders
			var meander := 1.0 + 1.2 * (wander.get_noise_2d(nx * 2.3, nz * 2.3) * 0.5 + 0.5)
			var nc := c + step * meander * (1.0 + maxf(h[j] - sea, 0.0) / 25.0) + maxf(h[j] - h[i], 0.0) * 15.0
			if nc < cost[j]:
				cost[j] = nc
				prev[j] = i
				heap.push(nc, j)
	var path := PackedVector2Array()
	var i := goal
	while i >= 0:
		path.append(Vector2(i % size, i / size))
		i = prev[i]
	path.reverse()
	return path


## Pushes the path sideways in irregular S-curves (a few metres, wavelength ~40 m),
## fading out at both ends so it still leaves the lake and meets the sea where routed.
static func _meander(p: PackedVector2Array, noise: FastNoiseLite, cell: float) -> PackedVector2Array:
	const AMPLITUDE = 5.0    # Metres
	const WAVELENGTH = 40.0  # Metres
	var out := PackedVector2Array()
	var n := p.size()
	for k in n:
		var tangent := (p[mini(k + 1, n - 1)] - p[maxi(k - 1, 0)]).normalized()
		var side := Vector2(-tangent.y, tangent.x)
		var along := k * cell  # Points are one cell apart
		var taper := smoothstep(0.0, 12.0, float(k)) * smoothstep(0.0, 12.0, float(n - 1 - k))
		var wobble := sin(TAU * along / WAVELENGTH + noise.get_noise_1d(along * 0.5) * 3.0)
		var amp := AMPLITUDE * (0.6 + 0.8 * (noise.get_noise_1d(along * 0.2 + 100.0) * 0.5 + 0.5))
		out.append(p[k] + side * wobble * amp * taper / cell)
	return out


## Corner-cutting smoothing: turns the staircase grid path into gentle curves.
static func _chaikin(p: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array([p[0]])
	for k in p.size() - 1:
		out.append(p[k].lerp(p[k + 1], 0.25))
		out.append(p[k].lerp(p[k + 1], 0.75))
	out.append(p[p.size() - 1])
	return out


## Evenly spaced points `spacing` cells apart along a polyline.
static func _resample(p: PackedVector2Array, spacing: float) -> PackedVector2Array:
	var out := PackedVector2Array([p[0]])
	var carry := 0.0
	for k in p.size() - 1:
		var a := p[k]
		var seg := p[k + 1] - a
		var length := seg.length()
		var t := spacing - carry
		while t <= length:
			out.append(a + seg * (t / length))
			t += spacing
		carry = length - (t - spacing)
	if out[out.size() - 1].distance_to(p[p.size() - 1]) > 0.01:
		out.append(p[p.size() - 1])
	return out


## Bilinear sample of a vertex grid at fractional cell coordinates.
static func _sample(h: PackedFloat32Array, size: int, p: Vector2) -> float:
	var x := clampf(p.x, 0.0, size - 1.001)
	var z := clampf(p.y, 0.0, size - 1.001)
	var cx := int(x)
	var cz := int(z)
	var i := cz * size + cx
	return lerpf(lerpf(h[i], h[i + 1], x - cx), lerpf(h[i + size], h[i + size + 1], x - cx), z - cz)


static func _to_normalised(m: PackedFloat32Array, max_h: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(m.size())
	for i in m.size():
		out[i] = m[i] / max_h
	return out


static func _world(c: Vector2, size: int, cell: float) -> String:
	var half := (size - 1) * 0.5
	return "(%.0f, %.0f)" % [(c.x - half) * cell, (c.y - half) * cell]


## Minimal binary min-heap of (cost, node) pairs for the route search.
class MinHeap:
	var costs := PackedFloat32Array()
	var nodes := PackedInt32Array()

	func is_empty() -> bool:
		return nodes.is_empty()

	func peek_cost() -> float:
		return costs[0]

	func push(cost: float, node: int) -> void:
		costs.append(cost)
		nodes.append(node)
		var i := nodes.size() - 1
		while i > 0:
			var parent := (i - 1) / 2
			if costs[parent] <= costs[i]:
				break
			_swap(i, parent)
			i = parent

	func pop() -> int:
		var top := nodes[0]
		var last := nodes.size() - 1
		_swap(0, last)
		costs.resize(last)
		nodes.resize(last)
		var i := 0
		while true:
			var l := i * 2 + 1
			var r := l + 1
			var smallest := i
			if l < last and costs[l] < costs[smallest]:
				smallest = l
			if r < last and costs[r] < costs[smallest]:
				smallest = r
			if smallest == i:
				break
			_swap(i, smallest)
			i = smallest
		return top

	func _swap(a: int, b: int) -> void:
		var c := costs[a]
		costs[a] = costs[b]
		costs[b] = c
		var n := nodes[a]
		nodes[a] = nodes[b]
		nodes[b] = n
