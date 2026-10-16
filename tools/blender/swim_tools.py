import bpy, math
from mathutils import Vector, Quaternion, Matrix

ARM = bpy.data.objects["Human Armature"]
# Body frame in world space: U = towards the head, F = the way the character faces, L = its left.
# In the game the model is turned to face Blender's -Y here (the FBX's +Z, flipped by the Human
# node in player.tscn) and pitched about +X for the crawl, so the clips must use exactly these
# axes. (The FBX's hips sit ~43 degrees off them, so don't derive the frame from the hips.)
U = Vector((0, 0, 1)); F = Vector((0, -1, 0)); L = U.cross(F)
_W2A = ARM.matrix_world.to_3x3().normalized().inverted()

def to_arm(v):
    return (_W2A @ v).normalized()

def idle_basis():
    """Rotation of every bone in the Idle clip's first frame: the base pose for untouched bones."""
    act = bpy.data.actions["Human Armature|Human Armature|Idle"]
    ARM.animation_data.action = act
    bpy.context.scene.frame_set(int(act.frame_range[0]))
    out = {pb.name: (pb.rotation_quaternion.copy(), pb.location.copy()) for pb in ARM.pose.bones}
    ARM.animation_data.action = None
    return out

def solve(base, aims, extra=None):
    """Bone rotations (pose basis quaternions) for one frame.
    aims: bone -> world-space direction the bone (head->tail) should point, or a
    (Y direction, X direction) pair to set its whole orientation.
    extra: bone -> (world axis, angle) twist applied after aiming, about the bone's own head."""
    extra = extra or {}
    M = {}
    out = {}
    for b in ARM.data.bones:   # parents come before children
        rest = b.matrix_local.to_3x3()
        if b.parent:
            prest = b.parent.matrix_local.to_3x3()
            default = M[b.parent.name] @ prest.inverted() @ rest
        else:
            default = rest
        q0 = base[b.name][0]
        cur = default @ q0.to_matrix()
        if b.name in aims:
            aim = aims[b.name]
            if isinstance(aim, tuple):   # (bone Y, bone X) directions: full orientation
                y = to_arm(aim[0]); x = to_arm(aim[1])
                x = (x - y * x.dot(y)).normalized()
                cur = Matrix((x, y, x.cross(y))).transposed()
            else:
                d0 = (cur @ Vector((0, 1, 0))).normalized()
                cur = d0.rotation_difference(to_arm(aim)).to_matrix() @ cur
        if b.name in extra:
            axis, ang = extra[b.name]
            cur = Quaternion(to_arm(axis), ang).to_matrix() @ cur
        M[b.name] = cur
        out[b.name] = (default.inverted() @ cur).to_quaternion()
    return out

def key_frame(action, frame, rots, base, keep_loc=True):
    for pb in ARM.pose.bones:
        pb.rotation_quaternion = rots[pb.name]
        pb.keyframe_insert("rotation_quaternion", frame=frame)
    hips = ARM.pose.bones["Hips"]
    hips.location = base["Hips"][1]
    hips.keyframe_insert("location", frame=frame)

def make_clip(name, frames, pose_fn):
    """pose_fn(phase 0..1) -> (aims, extra). Keys frames 1..frames+1 (last == first for a clean loop)."""
    base = idle_basis()
    old = bpy.data.actions.get(name)
    if old: bpy.data.actions.remove(old)
    act = bpy.data.actions.new(name); act.use_fake_user = True
    ARM.animation_data.action = act
    for i in range(frames + 1):
        aims, extra = pose_fn((i % frames) / frames)
        key_frame(act, i + 1, solve(base, aims, extra), base)
    for fc in _fcurves(act):
        for k in fc.keyframe_points: k.interpolation = "LINEAR"
    act.frame_range = (1, frames + 1); act.use_frame_range = True
    return act

def _fcurves(act):
    if hasattr(act, "fcurves") and len(getattr(act, "fcurves", [])):
        return list(act.fcurves)
    out = []
    for layer in getattr(act, "layers", []):
        for strip in layer.strips:
            for cb in strip.channelbags:
                out.extend(cb.fcurves)
    return out

def nz(v):
    return v.normalized()
