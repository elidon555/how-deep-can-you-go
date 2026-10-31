# How Deep Can You Go?

A 2D side-view digging game: dig down toward the Earth's core. Depth is your score.

Built with **Godot 4.7**.

## Play

```
godot --path .
```

Or open `project.godot` in the Godot editor and press F5.

## Controls

| Action | Keyboard / mouse | Controller |
|---|---|---|
| Move | A / D | Left stick / D-pad |
| Jump | Space or W | A |
| Dig (click = one swing, hold = keep swinging) | Left click or J | X |
| Aim the pick | W up · S down · S + A/D diagonal · otherwise the way you face | Stick / D-pad |
| Hang a rope (climb with W / S, jump off with Space) | Q or right click | Y |
| Trade at the merchant's stall | E | B |
| Restart | R | Back |

Bindings live in `src/game/controls.gd`.

## How it plays

- Dig down for depth. Swings need room: in a cramped spot the pick knocks the rock first.
- Ore (copper, deeper silver, deep gold) is carried in your bag and only banked when you
  get back to the surface; die and it's lost. Ropes get you back up (refilled at the surface).
- Spend money at the merchant's stall: sharper pickaxe, stronger arms, brighter lamp, thicker
  coat (+health), rope bag. Upgrades and best depth are saved (`user://progress.json`).
- Loose boulders drop when you dig out what holds them up. Crawlers hunt in the caves below
  25 m; fight them with the pickaxe.

See [IDEAS.md](IDEAS.md) for the plan and everything coming later.

## Code layout

All game code is in `src/`:

| File | What it does |
|---|---|
| `main.gd` / `main.tscn` | Puts the game together; rules across systems (selling, ropes, death, milestones) |
| `game/controls.gd` | Input bindings (keyboard, mouse, controller) |
| `game/progress.gd` | Autoload `Progress`: money, upgrades, best depth, save file |
| `world/world.gd` | Endless diggable ground: generation, fill/damage grid, collision, ore, props |
| `world/boulder.gd` | Loose boulders that fall when undermined |
| `world/rope.gd` | Climbable ropes |
| `world/camp.gd` | Surface camp with the merchant's stall |
| `world/backdrop.gd` | Back wall and parallax sky / cave layers |
| `world/terrain.gdshader` / `backwall.gdshader` | Smooth rock with outlines and cracks / cave back wall |
| `player/player.gd` | Movement, rope climbing, health, animation, helmet lamp |
| `player/pickaxe.gd` | Swings: aim, room check, impact timing, hitting creatures, swoosh trail |
| `creatures/crawler.gd` | Cave crawler: patrol, chase, lunge, take hits |
| `creatures/watcher.gd` | Glowing eyes in the dark |
| `creatures/spawner.gd` | Spawns / despawns creatures around the player |
| `fx/fx.gd` | Particle bursts, impacts, hit-stop |
| `fx/sfx.gd` | Autoload `Sfx`: sound effects, cave ambience, drips |
| `ui/hud.gd` / `ui/shop.gd` | On-screen info / the merchant's shop |

## Tests

Headless, no window or sound:

```
godot --headless --path . --fixed-fps 60 res://tests/feel_test.tscn
godot --headless --path . --fixed-fps 60 res://tests/systems_test.tscn
```

`feel_test` checks digging never gets stuck and how fast each direction is per material;
`systems_test` plays through rope climbing + selling, the shop, a crawler fight and a falling
boulder and prints PASS/FAIL.

## Art pipeline

All art is generated, so it can be tweaked and rebuilt:

| What | Command |
|---|---|
| Terrain textures + normal maps | `python3 tools/gen_textures.py` |
| Parallax backgrounds | `python3 tools/gen_backgrounds.py` |
| Miner sprite sheet (Blender) | `blender -b --factory-startup -P tools/miner_blender.py -- /tmp/miner && python3 tools/miner_sheet.py /tmp/miner` |
| Crawler creature sheet + eye glow (Blender) | `blender -b --factory-startup -P tools/crawler_blender.py -- /tmp/crawler && python3 tools/crawler_sheet.py /tmp/crawler` |
| Cave props, rope, boulder, camp stall (Blender) | `blender -b --factory-startup -P tools/props_blender.py -- /tmp/props && python3 tools/props_sheet.py /tmp/props` |

The character scripts take an optional anim list after the output dir to re-render only
those rows (e.g. `-- /tmp/miner climb,hurt`); the sheet script still needs every frame in the dir.
The miner, crawler and props are low-poly 3D models rendered to cel-shaded pixel art with outlines
(the same idea Dead Cells used). Terrain is a fine dig grid drawn as smooth outlined rock by
`terrain.gdshader`.
