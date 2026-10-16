import bpy, math
from mathutils import Vector
ns = {}; exec(bpy.data.texts["swim_tools.py"].as_string(), ns)
ARM, U, F, L, nz, solve = ns["ARM"], ns["U"], ns["F"], ns["L"], ns["nz"], ns["solve"]
MW = ARM.matrix_world

SEAT_H = 0.39        # Hips head height when sitting on the ground (Blender units; x0.338 in game)
SEAT_F = -1.05       # How far behind the feet origin the seat ends up
HAND_GROUND = (0.78, -1.85, 0.24)   # Seated hand support (L, F, U), mirrored
FOOT_SEAT = (0.42, 0.62, 0.215)   # Seated ankle (L, F, U), mirrored

def P(l, f, u): return L*l + F*f + U*u
def lean(a): return nz(U*math.cos(a) + F*math.sin(a))   # tilt U towards F by a (radians)
def smooth(e0, e1, x):
    x = min(1.0, max(0.0, (x - e0) / (e1 - e0))); return x*x*(3 - 2*x)

def curve(points, t):
    """Cubic Hermite through (t, value) waypoints, with finite-difference tangents."""
    for i in range(len(points) - 1):
        t0, v0 = points[i]; t1, v1 = points[i+1]
        if t <= t1 or i == len(points) - 2:
            h = t1 - t0; s = min(1.0, max(0.0, (t - t0) / h))
            m0 = (v1 - v0) if i == 0 else (v1 - points[i-1][1]) * (h / (t1 - points[i-1][0]))
            m1 = (v1 - v0) if i == len(points) - 2 else (points[i+2][1] - v0) * (h / (points[i+2][0] - t0))
            if i == 0: m0 = m0 * 0
            if i == len(points) - 2: m1 = m1 * 0
            s2, s3 = s*s, s*s*s
            return v0*(2*s3 - 3*s2 + 1) + m0*(s3 - 2*s2 + s) + v1*(-2*s3 + 3*s2) + m1*(s3 - s2)

def head(name): return MW @ ARM.pose.bones[name].head
def tail(name): return MW @ ARM.pose.bones[name].tail

def apply(rots, hips_world):
    for pb in ARM.pose.bones:
        pb.rotation_quaternion = rots[pb.name]
    b = ARM.data.bones["Hips"]
    ARM.pose.bones["Hips"].location = b.matrix_local.inverted() @ (MW.inverted() @ hips_world)
    bpy.context.view_layer.update()

def two_bone(root, target, l1, l2, pole):
    d = target - root
    dist = min(d.length, (l1 + l2) * 0.999); dist = max(dist, abs(l1 - l2) + 1e-3)
    dn = d.normalized()
    ca = max(-1.0, min(1.0, (l1*l1 + dist*dist - l2*l2) / (2*l1*dist)))
    a = math.acos(ca)
    p = (pole - dn*pole.dot(dn)).normalized()
    upper = dn*math.cos(a) + p*math.sin(a)
    joint = root + upper*l1
    return upper, (root + dn*dist - joint).normalized()

def measure(base):
    """Limb lengths and the standing foot/hand placement, from the Idle pose."""
    apply(solve(base, {}), MW @ (ARM.data.bones["Hips"].matrix_local @ base["Hips"][1]))
    g = {}
    for s in ("Left", "Right"):
        g[s+"thigh"] = (head(s+"Leg") - head(s+"UpLeg")).length
        g[s+"shin"] = (head(s+"Foot") - head(s+"Leg")).length
        g[s+"upper"] = (head(s+"ForeArm") - head(s+"Arm")).length
        g[s+"fore"] = (head(s+"Hand") - head(s+"ForeArm")).length
        g[s+"ankle"] = head(s+"Foot")
        g[s+"foot"] = (tail(s+"Foot") - head(s+"Foot")).normalized()
        g[s+"toe"] = (tail(s+"ToeBase") - head(s+"ToeBase")).normalized()
    return g

def pose(t, g, base, idle=None):
    """Full-body pose at sit-down progress t (0 standing, 1 seated); idle = (phase) adds the seated loop."""
    breath = look = sway = 0.0
    if idle is not None:
        a = math.tau * idle
        breath = math.sin(2*a)                 # two breaths per loop
        look = 0.45*math.sin(a) + 0.12*math.sin(3*a)
        sway = math.sin(a + 0.6)
    hips = curve([(0, P(0, 0.0, 2.6)), (0.3, P(0, -0.3, 1.9)), (0.58, P(0, -0.75, 1.15)),
                  (0.8, P(0, -1.0, 0.55)), (1, P(0, SEAT_F, SEAT_H))], t)
    lean_a = curve([(0, 0.0), (0.3, 0.55), (0.58, 0.5), (0.8, 0.0), (1, -0.38)], t) + 0.015*breath
    pelvis = curve([(0, 0.0), (0.3, 0.35), (0.58, 0.3), (0.8, -0.1), (1, -0.32)], t)
    aims, extra = {}, {}
    aims["Hips"] = (lean(pelvis), L)
    aims["Spine"] = (lean(pelvis*0.5 + lean_a*0.6), L)
    aims["Spine1"] = (lean(lean_a), L)
    aims["Spine2"] = (lean(lean_a*0.9 - 0.02*breath), L)
    aims["Neck"] = (lean(lean_a*0.5 + 0.08), L)
    aims["Head"] = (lean(min(0.0, -lean_a*0.15) + 0.04 + 0.1*max(0.0, lean_a)), L)
    if look:
        extra["Neck"] = (U, look*0.4); extra["Head"] = (U, look*0.6)
    apply(solve(base, aims, extra), hips)

    for s, side in ((1, "Left"), (-1, "Right")):
        # Feet stay planted, then shuffle forward into the seated stance as the seat lands
        stand = g[side+"ankle"]
        seat = P(FOOT_SEAT[0]*s, FOOT_SEAT[1], FOOT_SEAT[2])
        if s < 0: stand = stand.lerp(P(-0.3, -0.25, stand.z), smooth(0.05, 0.3, t))  # rear foot steps up
        k = smooth(0.62 if s > 0 else 0.7, 0.92 if s > 0 else 0.98, t)
        ankle = stand.lerp(seat, k) + U*0.12*math.sin(math.pi*k)
        if idle is not None and s < 0:
            ankle = ankle + L*0.08*sway                            # right knee rocks idly
        knee_pole = nz(F + U*0.4 + L*s*0.25)
        up, lo = two_bone(head(side+"UpLeg"), ankle, g[side+"thigh"], g[side+"shin"], knee_pole)
        aims[side+"UpLeg"] = up; aims[side+"Leg"] = lo
        flat = nz(F + U*-0.4 + L*s*0.12)
        aims[side+"Foot"] = nz(g[side+"foot"].lerp(flat, k))
        aims[side+"ToeBase"] = nz(g[side+"toe"].lerp(nz(F + L*s*0.12), k))

        # Hands: hang, reach forward for balance, then swing back to take the weight on the ground
        sh = head(side+"Arm")
        hang = sh + P(s*0.25, 0.1, -1.7)
        fwd = sh + P(s*0.15, 1.2, -1.05)
        ground = P(HAND_GROUND[0]*s, HAND_GROUND[1], HAND_GROUND[2])
        reach = hang.lerp(fwd, smooth(0.0, 0.35, t) * (1 - smooth(0.4, 0.62, t)))
        hand = reach.lerp(ground, smooth(0.45 if s < 0 else 0.5, 0.8 if s < 0 else 0.86, t))
        elbow_pole = nz(-F*0.6 + L*s*1.0 - U*0.3) if t < 0.5 else nz(-F + L*s*0.8)
        up, lo = two_bone(sh, hand, g[side+"upper"], g[side+"fore"], elbow_pole)
        aims[side+"Arm"] = up; aims[side+"ForeArm"] = lo
        w = smooth(0.55, 0.85, t)
        aims[side+"Hand"] = nz(lo.lerp(nz(-F*0.55 + L*s*0.45 + U*0.05), w))
    rots = solve(base, aims, extra)
    apply(rots, hips)
    return rots, hips

def key(rots, hips, frame):
    for pb in ARM.pose.bones:
        pb.rotation_quaternion = rots[pb.name]
        pb.keyframe_insert("rotation_quaternion", frame=frame)
    b = ARM.data.bones["Hips"]
    hb = ARM.pose.bones["Hips"]
    hb.location = b.matrix_local.inverted() @ (MW.inverted() @ hips)
    hb.keyframe_insert("location", frame=frame)

def make(name, frames, fn, loop):
    base = ns["idle_basis"]()
    g = measure(base)
    old = bpy.data.actions.get(name)
    if old: bpy.data.actions.remove(old)
    act = bpy.data.actions.new(name); act.use_fake_user = True
    ARM.animation_data.action = act
    n = frames + 1
    for i in range(n):
        x = (i % frames) / frames if loop else i / frames
        rots, hips = fn(x, g, base)
        key(rots, hips, i + 1)
    for fc in ns["_fcurves"](act):
        for k in fc.keyframe_points: k.interpolation = "LINEAR"
    act.frame_range = (1, n); act.use_frame_range = True
    return act

def build():
    """Regenerates SitDown (stand -> seated; played backwards to stand up) and SitIdle (seated loop)."""
    make("SitDown", 48, lambda x, g, b: pose(x, g, b), False)
    make("SitIdle", 180, lambda x, g, b: pose(1.0, g, b, x), True)
