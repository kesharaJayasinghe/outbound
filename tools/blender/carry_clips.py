import bpy, math
sit = {}; exec(bpy.data.texts["sit_clips.py"].as_string(), sit)
ns = sit["ns"]
U, F, L, nz, solve = ns["U"], ns["F"], ns["L"], ns["nz"], ns["solve"]
P, head, apply, two_bone = (sit[k] for k in ("P", "head", "apply", "two_bone"))

# Carrying a torch high in the right hand. Only the right arm's bones are used in game
# (player.gd layers them over walking and running), so the rest stays neutral.
HAND = (-0.5, 0.5, 0.72)    # Wrist from the right shoulder (L, F, U, Blender units): out, forward, about head height

def pose(t, g, base):
    hips = sit["MW"] @ (ns["ARM"].data.bones["Hips"].matrix_local @ base["Hips"][1])
    aims = {"Hips": (U, L), "Spine": (U, L), "Spine1": (U, L), "Spine2": (U, L),
            "Neck": (U, L), "Head": (U, L)}
    apply(solve(base, aims), hips)
    sh = head("RightArm")
    up, lo = two_bone(sh, sh + P(*HAND), g["Rightupper"], g["Rightfore"], nz(-U - L*0.6 + F*0.2))
    aims["RightArm"] = up; aims["RightForeArm"] = lo
    aims["RightHand"] = nz(lo + F*0.2)       # Wrist straight, a touch forward
    rots = solve(base, aims)
    apply(rots, hips)
    return rots, hips

def build():
    """Regenerates CarryTorch (a held pose, looped)."""
    sit["make"]("CarryTorch", 10, pose, True)
