# Blender clip scripts

The scripts that generate the player's hand-keyed animation clips. In Blender they run as text
blocks of the same names inside `player-swim.blend`. That file lives outside the repo, in
`/Users/keshara/dev/blender-dev/outbound/`. These files are the versioned copies.

| File | What it does |
|---|---|
| `swim_tools.py` | Body frame (U, F, L), aim solver, Idle base pose, clip helpers |
| `sit_clips.py` | Two-bone IK and posing helpers; SitDown, SitIdle |
| `swim_clips.py` | SwimTread, SwimCrawl |
| `pick_clips.py` | PickUp |
| `throw_clips.py` | Throw (overhand, upper body) |

The scripts load each other by text-block name (`bpy.data.texts["swim_tools.py"]`), so run
them inside the .blend, not as standalone files.

**Keep the two copies in step:**

- After editing a text block in Blender, write it back here:
  ```python
  open(f"{repo}/tools/blender/{t.name}", "w").write(t.as_string())
  ```
- To restore or update the .blend from here, for each file:
  ```python
  bpy.data.texts[name].from_string(open(path).read())
  ```

The `player-animation` skill (`.claude/skills/player-animation/`) has the full workflow: authoring,
export, `tools/convert_anims.gd`, and wiring into `player.gd`.
