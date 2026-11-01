# How Deep Can You Go?

A 2D side-view game about a crew boring toward the Earth's core in a giant drilling machine,
"Barotrauma, but a drill": keep the machine running, go outside to dig for coal and ore,
repair the hull, and don't get left behind. Up to 4 players crew the same drill online, or two
on one machine (a second player on a controller).

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
| Use the tool in hand (grapple, flare, dynamite, extinguisher) | Right click or Q | Y |
| Switch tool | Tab or mouse wheel | Right stick click |
| Use a station / hold E to repair a breach, a fuse box, beat out a fire, help a downed crewmate up · tap E to carry them | E | B |
| Ping a spot for the crew | F or middle click | LB |
| Restart | R | Back |

**Local co-op:** a second player presses **Start** on a controller to join (that controller is
theirs; player one keeps keyboard + mouse). The camera frames both. Menus answer either player.

**The crew:** each miner has their own colour (blue, red, green, violet) and a name tag, and a
**role** picked on the title screen: **miner** (digs harder, carries more), **engineer**
(repairs twice as fast), **gunner** (turrets reload faster) or **medic** (helps the downed up
fast). Out of health, you're **down**: a crewmate holds E on you to help you up, or taps E to
carry you to the medkit. Nobody comes within 30 s and you've bled out: your bag is lost and
you're back in the drill shortly. The run ends
when everyone is down or the drill is wrecked. **Pings** (F / middle click) mark a spot for the
whole crew, with an arrow at the screen's edge when it's out of view.

**Online co-op (up to 4):** title screen → **Play online**. One player picks **Host a game**
(the toast shows the addresses to share); the others type that address (and their name) and **Join**, any time
during the run. Everyone crews the same drill. The host's machine runs the game, so the host's
money and upgrades are the crew's. Only the host restarts runs, and everyone comes along to the
next one. Over the internet the host has to forward the port (default 24680, UDP) on their router.
Online the pause menu doesn't stop the game.

Bindings live in `src/game/controls.gd`.

**Playtest switch:** `project.godot` → `[game] infinite_resources=true` gives free upgrades,
endless ropes and drill fuel, and stops the game writing the save (so nothing sticks).
Set it to `false` for the real economy.

## How it plays

- **The drill** is the crew's base. The **helm** sets its speed; it bores down in bites,
  chewing only the rock in front of its cutters, and drops through caves it breaks into.
  Inside: **sonar**, **gunner's seat** (two hull turrets), **coolant** (vent heat),
  **workbench** (sell ore, upgrades, modules, restock), **furnace** (drives the generator),
  **medkit**, and two **fuse boxes** on the walls. Braces grip the walls when it stops.
- **Power:** the furnace's generator runs Low / Normal / Boost (E at the furnace). The head,
  turrets, pump and modules all draw on it; too little browns everything out (slower head,
  stuttering lights, slow turrets) and a long brownout blows a fuse; Boost on a light load
  wastes heat. A blown fuse kills what's on its box until someone holds E on it.
- **Danger to the drill:** heat, hull breaches (boulders, crawlers, borers, the worm, crashes),
  flooding through breaches in water, and **fire** (overheating, sparking fuses, blasts): it
  spreads, eats the hull and burns the crew. Beat it out (hold E), spray it (extinguisher),
  or let the sprinklers or the flood put it out.
- **Modules** built at the workbench show on the hull: cargo hold (keeps the ore the head
  grinds), floodlights, sprinklers, a defence drone, a crew bunk.
- **Going outside:** dig (mouse aims the swing), the **grapple** (unlimited, a short cooldown:
  hook rock, get hauled up, climb onto ledges or hang and hook again; hook the hull to climb
  back in at a door), **flares** (creatures keep away), **dynamite**, dodge roll, swim. Your
  bag holds so much (the ore sled upgrade carries more). Sell ore at the workbench.
- **Radio jobs** come in from the surface: sell so much ore, hunt so many creatures, or rescue
  a miner trapped in a cave below (carry them to the drill), each before a deadline depth.
- **Quakes** past 50 m: rubble fills tunnels near you, the shaft above the drill caves in.
- **The world is procedurally generated** from a seed every run: topsoil, the **fungal
  caves** (~60-140 m, glowing mushroom forests), the **crystal caverns** (~150-300 m), the
  **ice** (~300-400 m, slippery), the **magma layer** (400 m+) with **ancient halls** and
  their relics, the cavern above the Floor. Layer boundaries wander; ore and coal; water and
  lava that flow; boulders; **ruined camps** with crates and **miners' notes**.
- **Creatures:** watching eyes, crawlers, bat roosts, **mite swarms** (they get in through
  breaches), **borers** (tunnel to the drill, chew in, gnaw fuse boxes), the burrowing worm,
  the **Broodmother** (a mid-boss in the ice), and the Eye at the bottom.
- **Between runs:** upgrades, best depth and notes are kept; **unlocks** (drills with their
  own trade-offs, helmet colours) are picked in the **Hangar**. **Save and quit** from the
  pause menu, then **Continue** on the title screen (single player).
- Saves: `user://progress.json`, `user://run.save`; settings in `user://settings.cfg`.

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
| `contracts.gd` | Radio jobs (sell, hunt, rescue) |
| `unlocks.gd` | Drill variants and helmet colours, and what unlocks them |
| `run_save.gd` | Saving a run and continuing it |
| **world/** | |
| `world.gd` | The dig grid: chunks, fill/damage/material/liquid per cell, digging, chunk images + collision |
| `world_gen.gd` | Making the world from the seed: noise, layers, caves, ore, liquid pockets, boulders, props |
| `camps.gd` / `ruins.gd` / `camp_items.gd` | Ruined camps / ancient halls (generated) / crates, notes, relics |
| `quakes.gd` | Quakes and cave-ins |
| `liquids.gd` | Water + lava flow simulation, drawn by `liquid_*.gdshader` |
| `terrain*.gdshader` / `terrain_common.gdshaderinc` | Smooth rock with outlines, cracks, materials; crystal/magma glow |
| `boulder.gd`, `backdrop.gd`, `backwall.gdshader` | Falling boulders, parallax backgrounds (per layer), cave back wall |
| **drill/** | |
| `drill.gd` | The machine: hull, fuel, speed, damage, breaches, stations, braces, ladders |
| `drill_cutter.gd` | Boring down in bites, reamers, falling into caves, crashes |
| `drill_heat.gd` / `drill_flood.gd` / `drill_guns.gd` | Heat + coolant / flooding + pump / turrets + gunner's seat |
| `drill_power.gd` / `junction.gd` | The generator, brownouts / the fuse boxes |
| `drill_fires.gd` | Fire in the cabin (spreading, damage, putting it out) |
| `drill_modules.gd`, `drone.gd` | Modules built onto the drill / the defence drone |
| `stations.gd`, `station.gd` | Helm, furnace, workbench, medkit, sonar, gunner seat, coolant, breaches |
| `drill_art.gd`, `turret.gd` | How it looks (sprites + lights + effects), turrets |
| **player/** | |
| `player.gd` | Movement, roll, ropes/ladders, swimming + breath, health, bag, animation, lamp |
| `pickaxe.gd` | Swings: aim (mouse direction or keys), room check, impact, hitting creatures |
| `interactor.gd` | Per-player "use the thing in front of you" (E / hold E) |
| `player_input.gd` | One player's controls (action prefix, mouse or not); all player input goes through it |
| `player_tools.gd`, `thrown.gd`, `ore_sled.gd` | The tool belt (grapple, flares, dynamite, extinguisher) / thrown things / the sled |
| `roles.gd` | Crew roles and their perks |
| `revive_spot.gd`, `survivor.gd` | Helping a downed crewmate up or carrying them / trapped survivors (rescue jobs) |
| `crew_color.gdshader` | Each miner's clothes in their colour, helmets in theirs |
| **creatures/** | `crawler.gd`, `bat.gd`, `mite.gd`, `borer.gd`, `worm.gd`, `watcher.gd`, `broodmother.gd`, `the_eye.gd`, `creature_sprite.gd` (sheet + glow helper), `spawner.gd` (who spawns where) |
| **fx/** | `fx.gd` (particles, impacts, hit-stop), `ping.gd` (crew markers), `sfx.gd` (autoload `Sfx`: sounds, ambience, music), `art.gd` (sprites + normal maps) |
| **net/** (online co-op) | |
| `net.gd` | Autoload `Net`: hosting / joining (ENet), the handshake, sending messages, echoing the host's calls |
| `net_session.gd` | One online run: who's in the crew, what's sent 20×/s, menus and buying for remote players |
| `net_input.gd` | A remote miner's controls (and packing this machine's to send) |
| `net_world.gd` | Dug rock + liquid: changed cells in batches, whole chunks for late joiners |
| `net_entities.gd` | Snapshots of the drill, miners, creatures and things; smoothing them on clients |
| **ui/** | `hud.gd`, `shop.gd`, `sonar_view.gd`, `menus.gd` (title / pause / settings / online / hangar / run summary / notes), `ui_style.gd` |

**How online works:** the host simulates everything; clients generate the same world from the
seed, send their controls, and show what the host sends back. A synced thing joins group `net`
and has `puppet` (true on clients: shown, not simulated), `net_state()` and `net_apply()`; new
kinds are registered in `NetEntities.TYPES`. Effects, sounds and toasts called on the host play
on clients too (`Net.echo` in `Fx`, `Sfx`, `Hud`).

## Tests

Headless, no window or sound:

```
godot --headless --path . --fixed-fps 60 res://tests/feel_test.tscn
godot --headless --path . --fixed-fps 60 res://tests/systems_test.tscn
```

`feel_test` checks digging never gets stuck and how fast each direction is per material;
`systems_test` plays through the drill (riding it, braces, grappling back in, hatches,
furnace, workbench + shop, breaches, heat + coolant, flooding, power and fuses, fire, the
modules), the tools (flares, dynamite, the grapple), the bag, radio jobs and a rescue, quakes,
the ice, ruins, mites, a borer breaking in, the Broodmother, unlocks, saving and continuing,
the layers, sonar and the worm vs the turrets, mouse aiming, climbing out of a shaft, camps +
notes, bats, water and lava, gas, a crawler fight, the roll, co-op (colours, pings, helping a
crewmate up, carrying them to the medkit), the bottom and a falling boulder, and prints
PASS/FAIL. Tests use a fixed world seed, no random spawns, and never write the real saves.

```
tests/net_test.sh                # online: a host and two clients as separate processes on localhost
SHOTS=/tmp/shots tests/net_test.sh   # same, rendered offscreen, saving what the clients see
```

The host acts and asks the clients what they see: same ground, same dug holes and water, the
drill and miners in the same places, the client's controls and pickaxe working, creatures,
money, toasts, a station menu on the right screen, a player joining mid-run and leaving, and the
whole crew moving to the next run.

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
