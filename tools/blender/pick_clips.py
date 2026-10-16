import bpy, math
from mathutils import Vector
sit = {}; exec(bpy.data.texts["sit_clips.py"].as_string(), sit)
ns = sit["ns"]
ARM, U, F, L, nz, solve = ns["ARM"], ns["U"], ns["F"], ns["L"], ns["nz"], ns["solve"]
P, lean, smooth, curve, head, apply, two_bone = (sit[k] for k in ("P", "lean", "smooth", "curve", "head", "apply", "two_bone"))

# Where the right hand grabs, relative to the feet origin (Blender units; x0.338 in game).
# player.gd stands the player so the coconut is here: PICK_REACH in metres.
GRAB = (-0.44, 1.48, 0.95)     # (L, F, U): ahead and a little to the right, wrist just above a coconut
GRAB_T = 0.42                  # Clip progress at the grab (player.gd: PICK_GRAB)

def pose(t, g, base):
    """Stand -> lunge down -> right hand on the coconut -> stand up holding it -> stow."""
    hips = curve([(0, P(0, 0.0, 2.6)), (GRAB_T, P(0.05, -0.15, 1.55)), (0.62, P(0, -0.05, 2.0)), (1, P(0, 0.0, 2.6))], t)
    bend = curve([(0, 0.0), (GRAB_T - 0.05, 0.85), (GRAB_T + 0.06, 0.85), (0.7, 0.25), (1, 0.0)], t)
    pelvis = bend * 0.45
    aims, extra = {}, {}
    aims["Hips"] = (lean(pelvis), L)
    aims["Spine"] = (lean(bend * 0.7), L)
    aims["Spine1"] = (lean(bend), L)
    aims["Spine2"] = (lean(bend * 1.05), L)
    # Look at the coconut on the way down and as it comes up
    aims["Neck"] = (lean(bend * 1.1 + 0.08), L)
    aims["Head"] = (lean(bend * 1.25 + 0.1), L)
    twist = -0.18 * smooth(0.0, GRAB_T, t) * (1 - smooth(0.6, 1.0, t))   # turn the chest towards the right hand
    extra["Spine1"] = (U, twist); extra["Spine2"] = (U, twist)
    apply(solve(base, aims, extra), hips)

    for s, side in ((1, "Left"), (-1, "Right")):
        up, lo = two_bone(head(side+"UpLeg"), g[side+"ankle"], g[side+"thigh"], g[side+"shin"], nz(F + U*0.3 + L*s*0.3))
        aims[side+"UpLeg"] = up; aims[side+"Leg"] = lo
        aims[side+"Foot"] = g[side+"foot"]; aims[side+"ToeBase"] = g[side+"toe"]

    # Right hand: hang, reach down to the coconut, lift it in front of the hip, back to the side
    sh = head("RightArm")
    hang = sh + P(-0.25, 0.1, -1.7)
    grab = P(*GRAB)
    held = sh + P(-0.3, 0.55, -1.35)
    w_down = smooth(0.08, GRAB_T, t)
    hand = hang.lerp(grab, w_down)
    if t > GRAB_T:
        hand = grab.lerp(held, smooth(GRAB_T + 0.05, 0.75, t)).lerp(hang, smooth(0.8, 1.0, t))
    up, lo = two_bone(sh, hand, g["Rightupper"], g["Rightfore"], nz(L*-1.0 - F*0.4 + U*0.2))
    aims["RightArm"] = up; aims["RightForeArm"] = lo
    reach = smooth(0.15, GRAB_T, t) * (1 - smooth(0.75, 1.0, t))
    aims["RightHand"] = nz(lo.lerp(nz(-U + F*0.35 + L*0.05), reach))
    # Left hand braces on the left knee while bent over
    shl = head("LeftArm")
    lhang = shl + P(0.25, 0.1, -1.7)
    apply(solve(base, aims, extra), hips)
    knee = head("LeftLeg") + P(0.05, 0.15, 0.25)
    lhand = lhang.lerp(knee, smooth(0.1, GRAB_T - 0.05, t) * (1 - smooth(0.55, 0.85, t)))
    up, lo = two_bone(shl, lhand, g["Leftupper"], g["Leftfore"], nz(L*1.0 - F*0.5))
    aims["LeftArm"] = up; aims["LeftForeArm"] = lo
    aims["LeftHand"] = nz(lo.lerp(nz(F - U*0.6), smooth(0.1, GRAB_T, t) * (1 - smooth(0.55, 0.85, t))))
    rots = solve(base, aims, extra)
    apply(rots, hips)
    return rots, hips

def build():
    """Regenerates PickUp (bend down, grab with the right hand at GRAB, stand up holding it)."""
    sit["make"]("PickUp", 40, pose, False)
