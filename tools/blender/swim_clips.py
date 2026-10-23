import bpy, math
ns = {}; exec(bpy.data.texts["swim_tools.py"].as_string(), ns)
U, F, L, nz = ns["U"], ns["F"], ns["L"], ns["nz"]

def bump(p, c, w):
    d = (p - c + 0.5) % 1.0 - 0.5
    return math.cos(min(1.0, abs(d) / w) * math.pi) * 0.5 + 0.5 if abs(d) < w else 0.0

def tread(p):
    a = p * math.tau
    aims, extra = {}, {}
    for s, side in ((1, "Left"), (-1, "Right")):
        sw = math.sin(a)
        aims[side+"Arm"] = nz(L*s*0.9 + U*-0.42 + F*(0.22 + 0.14*sw))
        fore = nz(L*s*(0.55 + 0.35*sw) + F*(0.62 - 0.1*sw) + U*-0.3)
        aims[side+"ForeArm"] = fore
        aims[side+"Hand"] = nz(fore + U*-0.12)
        extra[side+"Hand"] = (fore, s*0.6*math.cos(a))           # palms pitch with each sweep
        c = a + (0 if s > 0 else math.pi)
        aims[side+"UpLeg"] = nz(L*s*0.5 + U*-0.6 + F*0.72)
        aims[side+"Leg"] = nz(L*s*(0.25 + 0.4*math.cos(c)) + U*-0.9 + F*(-0.3 + 0.3*math.sin(c)))
        aims[side+"Foot"] = nz(F*0.7 + U*-0.3 + L*s*0.4*math.cos(c))
    # Square the hips and spine to the body frame (the Idle stance is twisted), leaning forward a little
    aims["Hips"] = (U, L)
    aims["Spine"] = (nz(U + F*0.14), L); aims["Spine1"] = (nz(U + F*0.08), L); aims["Spine2"] = (nz(U + F*0.02), L)
    aims["Neck"] = (nz(U + F*0.02), L); aims["Head"] = (U, L)
    return aims, extra

def crawl(p):
    aims, extra = {}, {}
    for s, side, off in ((1, "Left", 0.0), (-1, "Right", 0.5)):
        ph = (p + off) % 1.0
        if ph < 0.5:   # catch, pull under the chest, push past the hip
            th = math.pi * ph / 0.5
            up = nz(U*math.cos(th) + F*0.8*math.sin(th) + L*s*0.16)
            tf = th + 0.8*math.sin(th)
            fore = nz(U*math.cos(tf) + F*math.sin(tf) - L*s*0.25*math.sin(th))
        else:          # recovery: elbow high and leading, hand hanging close to the body
            r = (ph - 0.5) / 0.5; th = math.pi + math.pi*r
            sn = abs(math.sin(th))
            up = nz(U*math.cos(th) - F*0.85*sn + L*s*0.5*sn + L*s*0.14)
            k = math.sin(math.pi * r) ** 0.8
            fore = nz(up*(1 - k) + (F*1.0 + U*0.45 - L*s*0.05)*k)
        aims[side+"Arm"] = up; aims[side+"ForeArm"] = fore
        aims[side+"Hand"] = nz(fore + F*0.12)
        kk = math.tau*3*p + (0.0 if s > 0 else math.pi)       # six-beat flutter kick
        thigh = nz(-U + F*0.2*math.sin(kk) + L*s*0.05)
        aims[side+"UpLeg"] = thigh
        shin = nz(thigh - F*0.3*(0.5 + 0.5*math.sin(kk + 1.3)))
        aims[side+"Leg"] = shin
        aims[side+"Foot"] = nz(shin + F*0.35)
    roll = -0.55 * math.sin(math.tau * p)           # drop the shoulder of the pulling arm
    for b in ("Hips", "Spine", "Spine1", "Spine2", "Neck", "Head"): aims[b] = (U, L)
    for b, k in (("Hips", 0.45), ("Spine", 0.25), ("Spine1", 0.2), ("Spine2", 0.15)):
        extra[b] = (U, roll * k)
    turn = -1.25 * bump(p, 0.16, 0.17)              # breathe to the right as the right shoulder rises
    extra["Neck"] = (U, -roll*0.6 + turn*0.35)
    extra["Head"] = (U, turn*0.65)
    return aims, extra

# --- Breaststroke (normal swimming; the crawl is the sprint) ---------------------------------
# Posed with the IK helpers from sit_clips.py. The game pitches the body forward (BREAST_PITCH
# in player.gd), so in this upright frame U is "ahead" for the swimmer, -U "towards the feet",
# F "down into the water" and -F "up to the sky".

def breast_pose(p, g, base):
    """Pull (and breathe) -> hands together under the chin -> shoot forward while the legs
    draw up -> whip kick -> glide."""
    sit = ns_sit
    P, lean, curve, head, apply, two_bone = (sit[k] for k in ("P", "lean", "curve", "head", "apply", "two_bone"))
    MW = sit["MW"]
    hips = MW @ (ns["ARM"].data.bones["Hips"].matrix_local @ base["Hips"][1])   # Same as tread/crawl
    breathe = curve([(0, 0.0), (0.12, 0.3), (0.32, 1.0), (0.45, 0.5), (0.6, 0.0), (1, 0.0)], p)
    aims, extra = {}, {}
    aims["Hips"] = (U, L)
    aims["Spine"] = (lean(-0.08 * breathe), L)
    aims["Spine1"] = (lean(-0.18 * breathe), L)
    aims["Spine2"] = (lean(-0.3 * breathe), L)
    aims["Neck"] = (lean(-0.35 - 0.35 * breathe), L)     # Head up: looking ahead, more so to breathe
    aims["Head"] = (lean(-0.55 - 0.45 * breathe), L)
    apply(ns["solve"](base, aims, extra), hips)

    for s, side in ((1, "Left"), (-1, "Right")):
        # Arms, relative to the shoulder
        sh = head(side+"Arm")
        glide = U*1.68 + L*s*0.12 + F*0.12
        off = curve([(0, glide), (0.14, U*1.3 + L*s*0.85 + F*0.25), (0.27, U*0.65 + L*s*0.7 + F*0.75),
                     (0.37, U*0.35 - L*s*0.38 + F*0.55), (0.55, glide), (1, glide)], p)
        pulling = p < 0.33
        pole = nz(L*s - F*0.6) if pulling else nz(L*s*0.4 + F*0.8)
        up, lo = two_bone(sh, sh + off, g[side+"upper"], g[side+"fore"], pole)
        aims[side+"Arm"] = up; aims[side+"ForeArm"] = lo
        aims[side+"Hand"] = nz(lo + F*(0.35 if pulling else 0.1))

        # Legs, relative to the hip joint: straight and together, heels up to the seat, kick round
        hip = head(side+"UpLeg")
        straight = -U*2.38 + L*s*0.06 - F*0.5     # Legs lifted ~12 degrees towards the surface
        leg = curve([(0, straight), (0.36, straight), (0.52, -U*0.95 + L*s*0.35 - F*0.75),
                     (0.6, -U*1.65 + L*s*0.85 - F*0.6), (0.72, straight), (1, straight)], p)
        up, lo = two_bone(hip, hip + leg, g[side+"thigh"], g[side+"shin"], nz(F + L*s*0.6))
        aims[side+"UpLeg"] = up; aims[side+"Leg"] = lo
        flex = curve([(0, 0.0), (0.4, 0.0), (0.5, 1.0), (0.6, 1.0), (0.7, 0.0), (1, 0.0)], p)
        pointed = nz(lo + F*0.2)                       # Toes pointed back in the glide
        turned = nz(L*s*0.8 - F*0.4 + lo*0.3)          # Flexed and turned out to push on the water
        aims[side+"Foot"] = nz(pointed.lerp(turned, flex))
        aims[side+"ToeBase"] = aims[side+"Foot"]
    rots = ns["solve"](base, aims, extra)
    apply(rots, hips)
    return rots, hips

ns_sit = {}


def build():
    """Regenerates the swim clips. The armature must be in its imported (untilted) placement."""
    ns["make_clip"]("SwimTread", 72, tread)
    ns["make_clip"]("SwimCrawl", 40, crawl)
    ns_sit.clear(); exec(bpy.data.texts["sit_clips.py"].as_string(), ns_sit)
    ns_sit["make"]("SwimBreast", 42, breast_pose, True)
