# How Deep Can You Go?

A 2D side-view game about a crew boring toward the Earth's core in a giant drilling machine,
"Barotrauma, but a drill": keep the machine running, go outside to dig for coal and ore,
repair the hull, and don't get left behind. Single player for now; co-op is planned and the
code is built for it (no system assumes there's only one player).

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
| Dig (click = one swing, hold = keep swinging) | Left click: swings the way the mouse points, hitting the first rock in front (arm's reach) · or J | X |
| Aim the pick with J / controller | W up · S down · S + A/D diagonal · otherwise the way you face | Stick / D-pad |
| Hang a rope (climb with W / S, jump off with Space) | Q or right click | Y |
| Use a station (helm, furnace, workbench, medkit) / hold to repair a breach | E | B |
| Restart | R | Back |

Bindings live in `src/game/controls.gd`.

## How it plays

- You start inside the drill at the surface. The **helm** sets its speed (stopped / slow /
  full); it bores down on its own, carrying you, and drops through caves it breaks into.
- It burns **fuel**. Go out the side doors, drop into the gap beside the hull and dig into
  the rock for **coal** (shovel it into the **furnace**) and metal ore (copper, silver deeper,
  gold deep), which the **workbench** sells for upgrades (drill head, hull plating, fuel tank,
  pickaxe, arms, lamp, coat, rope bag) and where ropes are restocked. Ladders on the hull get
  you back in. The drill keeps going without you, so don't get left behind.
- Falling boulders, crawlers chewing the hull and hard crashes tear **breaches** that leak
  hull until someone holds E on them. Hull at 0 = the drill is wrecked. Ore the drill grinds
  through itself is lost; only what you dig out by hand counts.
- Swings need room; loose boulders drop when undermined; crawlers hunt below 25 m.
- Upgrades and best depth are saved (`user://progress.json`).

See [IDEAS.md](IDEAS.md) for the plan and everything coming later.

## Code layout

All game code is in `src/`:

| File | What it does |
|---|---|
| `main.gd` / `main.tscn` | Puts the game together; rules across systems (who gets ore, ropes, death, wreck, milestones) |
| `drill/drill.gd` | The drilling machine: descent, cutting, fuel, hull, breaches, engine sound |
| `drill/drill_art.gd` | How the drill looks (cutaway hull, head, lights), drawn in code for now |
| `drill/station.gd` / `stations.gd` | Usable things on the drill: helm, furnace, workbench, medkit, breach |
| `game/controls.gd` | Input bindings (keyboard, mouse, controller) |
| `game/progress.gd` | Autoload `Progress`: money, upgrades, best depth, save file |
| `world/world.gd` | Endless diggable ground: generation, fill/damage grid, collision, ore, props |
| `world/boulder.gd` | Loose boulders that fall when undermined |
| `world/rope.gd` | Climbable ropes |
| `world/backdrop.gd` | Back wall and parallax sky / cave layers |
| `world/terrain.gdshader` / `backwall.gdshader` | Smooth rock with outlines and cracks / cave back wall |
| `player/player.gd` | Movement, rope/ladder climbing, health, bag, animation, helmet lamp |
| `player/interactor.gd` | Per-player "use the thing in front of you" (E / hold E) |
| `player/pickaxe.gd` | Swings: aim, room check, impact timing, hitting creatures, swoosh trail |
| `creatures/crawler.gd` | Cave crawler: patrol, chase, lunge, take hits |
| `creatures/watcher.gd` | Glowing eyes in the dark |
| `creatures/spawner.gd` | Spawns / despawns creatures around the player |
| `fx/fx.gd` | Particle bursts, impacts, hit-stop |
| `fx/sfx.gd` | Autoload `Sfx`: sound effects, cave ambience, drips |
| `ui/hud.gd` / `ui/shop.gd` | On-screen info + drill panel / the workbench's upgrades |

## Tests

Headless, no window or sound:

```
godot --headless --path . --fixed-fps 60 res://tests/feel_test.tscn
godot --headless --path . --fixed-fps 60 res://tests/systems_test.tscn
```

`feel_test` checks digging never gets stuck and how fast each direction is per material;
`systems_test` plays through the drill (riding it, furnace, workbench + shop, a breach and its
repair), rope climbing, a crawler fight and a falling boulder and prints PASS/FAIL. Tests use a
fixed world seed and never write the real save.

## Art pipeline

All art is generated, so it can be tweaked and rebuilt:

| What | Command |
|---|---|
| Terrain textures + normal maps | `python3 tools/gen_textures.py` |
| Parallax backgrounds | `python3 tools/gen_backgrounds.py` |
| Miner sprite sheet (Blender) | `blender -b --factory-startup -P tools/miner_blender.py -- /tmp/miner && python3 tools/miner_sheet.py /tmp/miner` |
| Crawler creature sheet + eye glow (Blender) | `blender -b --factory-startup -P tools/crawler_blender.py -- /tmp/crawler && python3 tools/crawler_sheet.py /tmp/crawler` |
| Cave props, rope, boulder, camp stall (Blender) | `blender -b --factory-startup -P tools/props_blender.py -- /tmp/props && python3 tools/props_sheet.py /tmp/props` |
| Drill machine: hull, back wall, head, stations (Blender) | `blender -b --factory-startup -P tools/drill_blender.py -- /tmp/drill && python3 tools/drill_sheet.py /tmp/drill` |

The character scripts take an optional anim list after the output dir to re-render only
those rows (e.g. `-- /tmp/miner climb,hurt`); the sheet script still needs every frame in the dir.
The miner, crawler and props are low-poly 3D models rendered to cel-shaded pixel art with outlines
(the same idea Dead Cells used). Terrain is a fine dig grid drawn as smooth outlined rock by
`terrain.gdshader`.
