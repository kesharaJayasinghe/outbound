import bpy, math
from mathutils import Vector, Quaternion
sit = {}; exec(bpy.data.texts["sit_clips.py"].as_string(), sit)
ns = sit["ns"]
ARM, U, F, L, nz, solve = ns["ARM"], ns["U"], ns["F"], ns["L"], ns["nz"], ns["solve"]
P, lean, smooth, curve, head, apply, two_bone = (sit[k] for k in ("P", "lean", "smooth", "curve", "head", "apply", "two_bone"))

# Right-handed overhand throw. Only the spine, head and arms are used in game (player.gd
# overlays them on whatever the legs are doing), so the hips and legs stay neutral.
RELEASE_T = 0.42   # Clip progress when the stone leaves the hand (player.gd: THROW_RELEASE)

def pose(t, g, base):
    """Wind up (chest turned right, arm cocked) -> whip forward -> release -> follow through -> stand."""
    hips = P(0, 0.0, 2.6)
    W, R, FT = 0.3, RELEASE_T, 0.68
    twist = curve([(0, 0.0), (W, -0.75), (R, 0.3), (FT, 0.55), (1, 0.0)], t)    # + turns left
    bend = curve([(0, 0.0), (W, -0.12), (R, 0.15), (FT, 0.4), (1, 0.0)], t)
    aims, extra = {}, {}
    aims["Hips"] = (U, L)
    aims["Spine"] = (lean(bend * 0.4), L); aims["Spine1"] = (lean(bend * 0.8), L)
    aims["Spine2"] = (lean(bend), L); aims["Neck"] = (lean(bend * 0.5 + 0.04), L); aims["Head"] = (lean(0.04), L)
    # The twist builds up the spine; the neck and head turn back so the eyes stay on the target
    for b, k in (("Spine", 0.3), ("Spine1", 0.65), ("Spine2", 1.0), ("Neck", 0.45), ("Head", 0.1)):
        extra[b] = (U, twist * k)
    apply(solve(base, aims, extra), hips)
    rot = Quaternion(U, twist)

    for s, side in ((1, "Left"), (-1, "Right")):
        up, lo = two_bone(head(side+"UpLeg"), g[side+"ankle"], g[side+"thigh"], g[side+"shin"], nz(F + L*s*0.2))
        aims[side+"UpLeg"] = up; aims[side+"Leg"] = lo
        aims[side+"Foot"] = g[side+"foot"]; aims[side+"ToeBase"] = g[side+"toe"]

    # Throwing hand, relative to its shoulder in the twisting chest's frame
    sh = head("RightArm")
    off = curve([(0, P(-0.25, 0.1, -1.7)), (0.12, P(-0.5, -0.2, -1.1)), (W, P(-0.6, -0.5, 0.5)),
                 (R - 0.06, P(-0.35, 0.3, 0.75)), (R, P(-0.2, 1.2, 0.6)), (FT, P(0.75, 0.9, -1.3)),
                 (1, P(-0.25, 0.1, -1.7))], t)
    hand = sh + rot @ off
    pole = nz(rot @ (P(-1, -0.6, -0.2) if t < R else P(-0.6, 0.0, -1.0)))
    up, lo = two_bone(sh, hand, g["Rightupper"], g["Rightfore"], pole)
    aims["RightArm"] = up; aims["RightForeArm"] = lo
    aims["RightHand"] = nz(lo + rot @ (F * (0.4 if R - 0.1 < t < R + 0.1 else 0.0)))

    # Other arm points at the target during the wind-up, then tucks in as the chest turns
    shl = head("LeftArm")
    offl = curve([(0, P(0.25, 0.1, -1.7)), (W, P(0.1, 1.6, 0.15)), (R, P(-0.2, 0.9, -0.9)),
                  (FT, P(0.35, -0.55, -1.55)), (1, P(0.25, 0.1, -1.7))], t)
    lpole = P(1, -0.5, -0.6) if t < R else P(0.3, -1.0, -0.2)
    up, lo = two_bone(shl, shl + rot @ offl, g["Leftupper"], g["Leftfore"], nz(rot @ lpole))
    aims["LeftArm"] = up; aims["LeftForeArm"] = lo
    aims["LeftHand"] = lo
    rots = solve(base, aims, extra)
    apply(rots, hips)
    return rots, hips

def build():
    """Regenerates Throw (overhand, right hand; release at RELEASE_T)."""
    sit["make"]("Throw", 30, pose, False)
