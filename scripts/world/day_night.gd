extends Node

## Day and night. The clock runs a full day in `day_length` real seconds, with the night
## hours passing `night_speed` times faster. The sun follows a tropical path (rising in
## the east, nearly overhead at noon, setting in the west), and a full moon rises opposite.
##
## The scene's one DirectionalLight3D is the sun by day and the moon by night: it changes
## over while both are below the horizon at dusk (and back at dawn), so there's only ever
## one shadow-casting light. Moonlight is faked a little: it never comes from lower than
## MOON_LIGHT_MIN_HEIGHT, it keeps most of its strength while the moon is low, and the sky
## light is turned up at night, so the whole night is playable. The sky (shaders/sky.gdshader), fog, exposure and light
## colours all follow the sun's height through the palettes below.
##
## Sun and moon directions go to global shader parameters every frame. The sky's colours
## are material uniforms, set every SKY_UPDATE seconds: each change re-renders the sky's
## lighting cubemap (ambient light and reflections), which is too costly to do every frame.
##
## Unshaded materials (spray, mist) don't get darker at night by themselves: register them
## with `dim_at_night` and their colour follows the `daylight` global, which shaders can
## also read (`global uniform vec3 daylight`).

const LATITUDE = 12.0        # Degrees north: the sun passes a little to the south at noon
const DECLINATION = 4.0      # The sun's declination (degrees): days a bit longer than nights
const MOON_LAG = 0.8         # Hours the moon trails exactly opposite the sun
const SUN_ENERGY = 1.3
const MOON_ENERGY = 0.3
const MOON_LIGHT_MIN_HEIGHT = 0.45  # Moonlight comes from at least this high (sine), so nights
                                    # aren't pitch black while the moon is low or down
const SKY_UPDATE = 0.5       # Seconds between sky colour updates
const DAY_EXPOSURE = 1.15
const NIGHT_EXPOSURE = 1.6   # The eye adapting: nights stay readable
const NIGHT_AMBIENT = Color(0.13, 0.16, 0.25)  # Flat ambient mixed in at night, so shade isn't pitch black
const NIGHT_SKY_AMBIENT = 0.35  # How much of the ambient comes from the (dark) sky at night

## Palettes keyed by the sun's height (the sine of its elevation, -1..1): night, dusk,
## sunset, golden hour, day
const SKY_TOP := [[-0.3, Color(0.01, 0.016, 0.042)], [-0.12, Color(0.022, 0.038, 0.095)],
		[-0.03, Color(0.09, 0.12, 0.28)], [0.06, Color(0.16, 0.3, 0.62)], [0.3, Color(0.16, 0.38, 0.78)]]
const SKY_HORIZON := [[-0.3, Color(0.035, 0.05, 0.09)], [-0.12, Color(0.08, 0.09, 0.16)],
		[-0.03, Color(0.38, 0.3, 0.38)], [0.06, Color(0.8, 0.66, 0.58)], [0.3, Color(0.62, 0.76, 0.9)]]
const TWILIGHT := [[-0.22, Color(0, 0, 0)], [-0.1, Color(0.28, 0.1, 0.06)], [-0.02, Color(0.9, 0.36, 0.12)],
		[0.08, Color(0.6, 0.32, 0.14)], [0.28, Color(0, 0, 0)]]
const SUN_COLOR := [[-0.05, Color(1.0, 0.35, 0.12)], [0.05, Color(1.0, 0.58, 0.32)],
		[0.2, Color(1.0, 0.85, 0.68)], [0.45, Color(1.0, 0.94, 0.84)]]
const CLOUD_LIGHT := [[-0.3, Color(0.07, 0.08, 0.11)], [-0.1, Color(0.3, 0.2, 0.25)],
		[0.0, Color(1.0, 0.6, 0.42)], [0.12, Color(1.0, 0.84, 0.7)], [0.3, Color(1.0, 0.92, 0.8)]]
const CLOUD_SHADE := [[-0.3, Color(0.025, 0.03, 0.05)], [-0.1, Color(0.12, 0.1, 0.14)],
		[0.0, Color(0.4, 0.3, 0.36)], [0.15, Color(0.54, 0.55, 0.63)], [0.3, Color(0.58, 0.64, 0.74)]]
## How bright unshaded things (spray, mist, the fruit's glow) should look
const DAYLIGHT := [[-0.3, Color(0.07, 0.085, 0.13)], [-0.08, Color(0.18, 0.17, 0.24)],
		[0.0, Color(0.7, 0.55, 0.48)], [0.15, Color(1.0, 0.95, 0.9)], [0.3, Color(1, 1, 1)]]

static var _dimmed: Array = []  # [material, its daytime colour]

var hour := 9.0              # 0..24
var day_length := 1440.0     # Real seconds for a whole day
var night_speed := 2.0
var running := true
var sun_height := 0.0        # Sine of the sun's elevation
var night := 0.0             # 0 by day, 1 once it's properly dark

var light: DirectionalLight3D
var env: Environment
var sky_material: ShaderMaterial
var _hours_per_unit := 1.0
var _sky_timer := 0.0
var _palettes := {}


## A material whose albedo should darken at night (unshaded spray, mist)
static func dim_at_night(material: BaseMaterial3D) -> void:
	_dimmed.append([material, material.albedo_color])


func setup(sun: DirectionalLight3D, environment: Environment, start_hour: float, length_seconds: float,
		night_rate: float, advance: bool) -> void:
	light = sun
	env = environment
	if env and env.sky:
		sky_material = env.sky.sky_material as ShaderMaterial
	hour = fposmod(start_hour, 24.0)
	day_length = maxf(length_seconds, 1.0)
	night_speed = maxf(night_rate, 0.01)
	running = advance
	_palettes = {"sky_top": SKY_TOP, "sky_horizon": SKY_HORIZON, "twilight": TWILIGHT, "sun": SUN_COLOR,
			"cloud_light": CLOUD_LIGHT, "cloud_shade": CLOUD_SHADE, "daylight": DAYLIGHT}
	for key: String in _palettes:
		_palettes[key] = _gradient(_palettes[key])
	# Game hours per "unit", where a unit is how far the clock moves in a second at day
	# speed: chosen so the whole day (night hours running faster) takes day_length
	var units := 0.0
	var steps := 480
	for i in steps:
		units += (24.0 / steps) / _rate(_sun_dir(24.0 * (i + 0.5) / steps).y)
	_hours_per_unit = units / day_length
	_apply(true)


## "HH:MM", for the HUD
func clock() -> String:
	var minutes := int(hour * 60.0) % 1440
	return "%02d:%02d" % [floori(minutes / 60.0), minutes % 60]


func _process(delta: float) -> void:
	if running:
		hour = fposmod(hour + delta * _hours_per_unit * _rate(sun_height), 24.0)
	_sky_timer -= delta
	_apply(_sky_timer <= 0.0)


## How fast the clock runs, relative to the day: night_speed once it's dark
func _rate(height: float) -> float:
	return lerpf(1.0, night_speed, 1.0 - smoothstep(-0.15, -0.03, height))


## Direction towards the sun at a time of day (x = east, -z = north, y = up)
func _sun_dir(at_hour: float, declination := DECLINATION) -> Vector3:
	var h := (at_hour - 12.0) / 24.0 * TAU
	var lat := deg_to_rad(LATITUDE)
	var dec := deg_to_rad(declination)
	var east := -cos(dec) * sin(h)
	var north := sin(dec) * cos(lat) - cos(dec) * sin(lat) * cos(h)
	var up := sin(lat) * sin(dec) + cos(lat) * cos(dec) * cos(h)
	return Vector3(east, up, -north).normalized()


func _apply(update_sky: bool) -> void:
	var sun := _sun_dir(hour)
	var moon := _sun_dir(hour + 12.0 - MOON_LAG, -DECLINATION)
	sun_height = sun.y
	night = 1.0 - smoothstep(-0.16, -0.06, sun.y)
	RenderingServer.global_shader_parameter_set(&"sun_direction", sun)
	RenderingServer.global_shader_parameter_set(&"moon_direction", moon)

	# One light: the sun until it's below the horizon, then the moon
	var sun_colour := _sample("sun", sun.y)
	var sun_energy := SUN_ENERGY * smoothstep(-0.05, 0.22, sun.y)
	var moon_energy := MOON_ENERGY * lerpf(0.7, 1.0, smoothstep(-0.1, 0.3, moon.y)) * night
	var moon_colour := Color(0.62, 0.72, 1.0)
	if light:
		var by_sun := sun.y > -0.055
		var towards := sun
		if not by_sun:
			var flat := Vector2(moon.x, moon.z).normalized() * sqrt(1.0 - MOON_LIGHT_MIN_HEIGHT ** 2)
			towards = moon if moon.y > MOON_LIGHT_MIN_HEIGHT else Vector3(flat.x, MOON_LIGHT_MIN_HEIGHT, flat.y)
		light.light_energy = sun_energy if by_sun else moon_energy
		light.light_color = sun_colour if by_sun else moon_colour
		light.visible = light.light_energy > 0.002
		if light.visible:
			var up := Vector3.UP if absf(towards.y) < 0.98 else Vector3.FORWARD
			light.global_basis = Basis.looking_at(-towards, up)

	var daylight := _sample("daylight", sun.y)
	RenderingServer.global_shader_parameter_set(&"daylight", Vector3(daylight.r, daylight.g, daylight.b))
	for entry in _dimmed:
		var base: Color = entry[1]
		(entry[0] as BaseMaterial3D).albedo_color = Color(base.r * daylight.r, base.g * daylight.g,
				base.b * daylight.b, base.a)

	if env:
		env.fog_light_color = _sample("sky_horizon", sun.y).lerp(_sample("sky_top", sun.y), 0.25)
		env.tonemap_exposure = lerpf(DAY_EXPOSURE, NIGHT_EXPOSURE, night)
		env.ambient_light_color = NIGHT_AMBIENT
		env.ambient_light_sky_contribution = lerpf(1.0, NIGHT_SKY_AMBIENT, night)

	if update_sky and sky_material:
		_sky_timer = SKY_UPDATE
		var horizon := _sample("sky_horizon", sun.y)
		sky_material.set_shader_parameter(&"sky_top_color", _sample("sky_top", sun.y))
		sky_material.set_shader_parameter(&"sky_horizon_color", horizon)
		sky_material.set_shader_parameter(&"ground_horizon_color", horizon)
		sky_material.set_shader_parameter(&"ground_bottom_color", horizon * Color(0.16, 0.29, 0.33))
		sky_material.set_shader_parameter(&"twilight_color", _sample("twilight", sun.y))
		var disc := smoothstep(-0.03, 0.0, sun.y)  # Gone once it has set
		sky_material.set_shader_parameter(&"sun_color", sun_colour * SUN_ENERGY * disc)
		var moon_show := smoothstep(-0.05, 0.02, moon.y) * lerpf(0.25, 1.0, night)
		sky_material.set_shader_parameter(&"moon_color", Color(0.9, 0.93, 1.0) * 1.1 * moon_show)
		sky_material.set_shader_parameter(&"stars", night)
		sky_material.set_shader_parameter(&"cloud_light", _sample("cloud_light", sun.y))
		sky_material.set_shader_parameter(&"cloud_shade", _sample("cloud_shade", sun.y))


func _sample(palette: String, height: float) -> Color:
	return (_palettes[palette] as Gradient).sample(clampf((height + 1.0) * 0.5, 0.0, 1.0))


## A Gradient from [[sun height, colour], ...], with the heights mapped to 0..1
func _gradient(keys: Array) -> Gradient:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array()
	g.colors = PackedColorArray()
	for k in keys:
		g.add_point((float(k[0]) + 1.0) * 0.5, k[1])
	return g
