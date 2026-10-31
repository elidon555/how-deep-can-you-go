# How Deep Can You Go?

A 2D side-view digging game: dig down toward the Earth's core. Depth is your score.

Built with **Godot 4.7**.

## Play

```
godot --path .
```

Or open `project.godot` in the Godot editor and press F5.

## Controls

| Action | Keyboard | Controller |
|---|---|---|
| Move | A / D | Left stick / D-pad |
| Jump | Space | A |
| Dig down | S | Down |
| Dig up | W | Up |
| Dig sideways | Walk into a wall | Walk into a wall |
| Restart | R | Back |

## Status

Step 1 prototype: endless generated ground with caves, dirt → stone → hard rock,
darkness + helmet lamp, depth counter and best depth.

See [IDEAS.md](IDEAS.md) for the plan and everything coming later.

## Code layout

| File | What it does |
|---|---|
| `main.gd` | Sets up the scene: world, player, camera, lighting, backgrounds, HUD, milestones |
| `world.gd` | Endless diggable ground: generation, fill/damage grid, collision, cave props |
| `player.gd` | Movement, animation, helmet lamp |
| `pickaxe.gd` | Swings: what the keys dig, room check, impact timing, swoosh trail |
| `fx.gd` | One-shot effects: particle bursts, pickaxe impacts, hit-stop |
| `watcher.gd` | Glowing eyes in the dark |
| `terrain.gdshader` / `backwall.gdshader` | Smooth rock with outlines and cracks / cave back wall |

## Feel test

Headless check that digging never gets stuck and how fast each direction is per material:

```
godot --headless --path . --fixed-fps 60 -s tests/feel_test.gd
```

## Art pipeline

All art is generated, so it can be tweaked and rebuilt:

| What | Command |
|---|---|
| Terrain textures + normal maps | `python3 tools/gen_textures.py` |
| Parallax backgrounds | `python3 tools/gen_backgrounds.py` |
| Miner sprite sheet (Blender) | `blender -b --factory-startup -P tools/miner_blender.py -- /tmp/miner && python3 tools/miner_sheet.py /tmp/miner` |
| Cave props (Blender) | `blender -b --factory-startup -P tools/props_blender.py -- /tmp/props && python3 tools/props_sheet.py /tmp/props` |

The miner and props are low-poly 3D models rendered to cel-shaded pixel art with outlines
(the same idea Dead Cells used). Terrain is a fine dig grid drawn as smooth outlined rock by
`terrain.gdshader`.
