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

**Playtest switch:** `project.godot` → `[game] infinite_resources=true` gives free upgrades,
endless ropes and drill fuel, and stops the game writing the save (so nothing sticks).
Set it to `false` for the real economy.

## How it plays

- **The drill** is the crew's base. The **helm** sets its speed; it bores down in bites,
  chewing only the rock in front of its cutters, and drops through caves it breaks into.
  Inside: **sonar** (see caves, ore and creatures), **gunner's seat** (two hull turrets),
  **coolant** (vent heat), **workbench** (sell ore, upgrades, ropes), **furnace** (coal ->
  fuel; fuel is unlimited for now), **medkit**. Braces grip the walls when it stops; the
  telescoping ladders come down whenever someone is outside.
- **Danger to the drill:** heat (rises with depth, cutting magma, lava), hull breaches
  (boulders, crawlers, the burrowing worm, crashes) that leak hull until you hold E on them,
  and flooding (breached in water: the cabin fills, the engine drowns, the pump drains it).
- **Going outside:** dig (mouse aims the swing, it hits the first rock that way), ropes,
  dodge roll, swim (watch your breath), stay out of lava. Carry ore back to sell.
- **The world is procedurally generated** from a seed every run: topsoil, the **crystal
  caverns** (~150-300 m), deep basalt, the **magma layer** (400 m+), with wandering layer
  boundaries; caves; ore (copper, silver, gold, amethyst) and coal; **water and lava** that
  really flow (water on lava -> rock); loose boulders; **ruined camps** of the crews who dug
  here before, with crates and **miners' notes** telling their story.
- **Creatures:** watching eyes, crawlers, bat roosts, and below 40 m the worm, which tunnels
  through rock to ram the drill.
- Upgrades, best depth and found notes are saved (`user://progress.json`); settings in
  `user://settings.cfg`.

## Code layout

All game code is in `src/` (one system per file):

| File | What it does |
|---|---|
| `main.gd` / `main.tscn` | Puts the game together; rules across systems (who gets ore, ropes, death, wreck, milestones, run stats) |
| **game/** | |
| `controls.gd` | Input bindings (keyboard, mouse, controller) |
| `progress.gd` | Autoload `Progress`: money, upgrades, best depth, found notes, save file |
| `settings.gd` | Autoload `Settings`: volumes, fullscreen, audio buses |
| `game_config.gd` | Playtest switches from `project.godot` `[game]` |
| `lore.gd` | The miners' notes and dealing them out per run |
| **world/** | |
| `world.gd` | The dig grid: chunks, fill/damage/material/liquid per cell, digging, chunk images + collision |
| `world_gen.gd` | Making the world from the seed: noise, layers, caves, ore, liquid pockets, boulders, props |
| `camps.gd` / `camp_items.gd` | Ruined camps (generated) / their crates and notes |
| `liquids.gd` | Water + lava flow simulation, drawn by `liquid_*.gdshader` |
| `terrain*.gdshader` / `terrain_common.gdshaderinc` | Smooth rock with outlines, cracks, materials; crystal/magma glow |
| `boulder.gd`, `rope.gd`, `backdrop.gd`, `backwall.gdshader` | Falling boulders, ropes, parallax backgrounds, cave back wall |
| **drill/** | |
| `drill.gd` | The machine: hull, fuel, speed, damage, breaches, stations, braces, ladders |
| `drill_cutter.gd` | Boring down in bites, reamers, falling into caves, crashes |
| `drill_heat.gd` / `drill_flood.gd` / `drill_guns.gd` | Heat + coolant / flooding + pump / turrets + gunner's seat |
| `stations.gd`, `station.gd` | Helm, furnace, workbench, medkit, sonar, gunner seat, coolant, breaches |
| `drill_art.gd`, `drill_ladder.gd`, `turret.gd` | How it looks (sprites + lights + effects), telescoping ladders, turrets |
| **player/** | |
| `player.gd` | Movement, roll, ropes/ladders, swimming + breath, health, bag, animation, lamp |
| `pickaxe.gd` | Swings: aim (mouse direction or keys), room check, impact, hitting creatures |
| `interactor.gd` | Per-player "use the thing in front of you" (E / hold E) |
| **creatures/** | `crawler.gd`, `bat.gd`, `worm.gd`, `watcher.gd`, `spawner.gd` (who spawns where) |
| **fx/** | `fx.gd` (particles, impacts, hit-stop), `sfx.gd` (autoload `Sfx`: sounds, ambience, music), `art.gd` (sprites + normal maps) |
| **ui/** | `hud.gd`, `shop.gd`, `sonar_view.gd`, `menus.gd` (title / pause / settings / run summary / notes), `ui_style.gd` |

## Tests

Headless, no window or sound:

```
godot --headless --path . --fixed-fps 60 res://tests/feel_test.tscn
godot --headless --path . --fixed-fps 60 res://tests/systems_test.tscn
```

`feel_test` checks digging never gets stuck and how fast each direction is per material;
`systems_test` plays through the drill (riding it, braces, ladders, furnace, workbench + shop,
breaches, heat + coolant, sonar, the worm vs the turrets), layers, camps + notes, bats, water
and lava, mouse aiming, ropes, a crawler fight, the dodge roll and a falling boulder, and prints
PASS/FAIL. Tests use a fixed world seed and never write the real save.

## Art pipeline

All art is generated, so it can be tweaked and rebuilt:

| What | Command |
|---|---|
| Terrain textures + normal maps | `python3 tools/gen_textures.py` |
| Parallax backgrounds | `python3 tools/gen_backgrounds.py` |
| Miner sprite sheet + normal map (Blender) | `blender -b --factory-startup -P tools/miner_blender.py -- /tmp/miner && python3 tools/miner_sheet.py /tmp/miner` |
| Crawler creature sheet + normal map + eye glow (Blender) | `blender -b --factory-startup -P tools/crawler_blender.py -- /tmp/crawler && python3 tools/crawler_sheet.py /tmp/crawler` |
| Cave props, rope, boulder, camp stall, ruined-camp props, lava pool + normal maps (Blender) | `blender -b --factory-startup -P tools/props_blender.py -- /tmp/props && python3 tools/props_sheet.py /tmp/props` |
| Drill machine: hull, back wall, head, gripper braces, turrets, stations (helm, furnace, workbench, medkit, sonar, gunner, coolant) + normal maps (Blender) | `blender -b --factory-startup -P tools/drill_blender.py -- /tmp/drill && python3 tools/drill_sheet.py /tmp/drill` |
| Burrowing worm: body segments + head in 16 directions + normal maps (Blender) | `blender -b --factory-startup -P tools/worm_blender.py -- /tmp/worm && python3 tools/worm_sheet.py /tmp/worm` |
| Cave bat sheet + normal map + eye glow (Blender) | `blender -b --factory-startup -P tools/bat_blender.py -- /tmp/bat && python3 tools/bat_sheet.py /tmp/bat` |
| Final boss: THE EYE + its vein nodes, normal maps + glow (Blender) | `blender -b --factory-startup -P tools/eye_blender.py -- /tmp/eye && python3 tools/eye_sheet.py /tmp/eye` |

The character scripts take an optional anim list after the output dir to re-render only
those rows (e.g. `-- /tmp/miner climb,hurt`); the sheet script still needs every frame in the dir.
The miner, crawler, props and drill are 3D models rendered tiny without anti-aliasing to
cel-shaded pixel art with outlines (the same idea Dead Cells used). Every sprite X.png also gets
X_n.png, a normal map with the same layout for in-game lighting: Blender renders a camera-normal
pass (`tools/normal_pass.py`) and `tools/normal_maps.py` snaps it to 17 directions so the lit
result stays crisp. That module also holds `BAKED_CONTRAST`, how strong the cel bands baked
into the colour sheets are now that the game lights the sprites. Terrain is a fine dig grid drawn as smooth outlined rock by
`terrain.gdshader`.
