# How Deep Can You Go — Ideas & Plan

Rule: build one small piece, play it, then add the next. Nothing here is lost — it's just "later".

## Step 1 — "Is digging fun?" (done)
- [x] Little guy, run + jump
- [x] Dig down / sideways / up through generated ground (endless, made in chunks)
- [x] Depth counter (1 tile = 1 m), best depth
- [x] Gets harder deeper (dirt → stone → hard rock), gets darker deeper
- [x] Basic juice: dust particles, screen shake, crack overlay

## Step 2 — "Why dig, and when to go back up?" (done)
- [x] Pickaxe hits (cracks, then breaks), swings need room, click/hold to dig
- [x] Sound: hits per rock, breaking, steps, landing, ambience by depth, drips, creatures
- [x] Ore types by depth (copper, silver, gold), carried until you reach the surface
- [x] Surface camp + merchant shop: pickaxe, arms, lamp, coat, rope bag upgrades (saved)
- [x] Ropes to climb back out (refilled at the surface)
- [x] Loose boulders that drop when undermined
- [x] First creature: cave crawler (chase, lunge, bite); fight with the pickaxe; health + death
- [ ] Lamp oil / fuel: on hold, the lamp never runs out for now

## Step 3 — "Barotrauma, but a drill" (prototype in)
Direction chosen 2026-10-31 (with a friend's input): the crew runs a giant drilling machine
boring toward the core; going outside on foot is the "diving suit" part. Co-op is planned for
sure, so everything is built per-player and the drill keeps all its state in one place.
- [x] Drill that descends, carries the crew, cuts a shaft, falls into caves, crashes
- [x] Stations: helm (speed), furnace (coal → fuel), workbench (sell ore, upgrades, ropes), medkit
- [x] Hull + breaches (boulders, crawlers, crashes) repaired by holding E
- [x] Coal ore; ore the drill grinds through is lost
- [x] Drill sounds (engine loop/idle, start, stall, alarm, hull hits, breach, repair, furnace, lever)
- [ ] Blender art pass for the drill (now drawn in code)
- [ ] Heat / pressure / gas as you go deeper; more systems to juggle (power, coolant)
- [ ] Co-op (Godot multiplayer): next big step once the solo loop is fun
- [ ] Layers (flooded caves, crystal caverns, magma) and a real bottom with an ending

## Decisions made (can change later)
- Engine: Godot 4 (built-in 2D lighting/glow for the Dead Cells-style look, exports to web)
- Theme: digging toward the Earth's core
- Co-op: yes, for sure (later). Build every system per-player now.

## Later list (rough order, pick what sounds most fun after playing)
1. **Fuel / stamina** — the "go deeper or turn back" tension (on hold)
2. **Ore + upgrades** — sell ore, better pickaxe/drill, more fuel, lamp radius
3. **Enemies + combat** — cave creatures, Dead Cells-style hits/dodges/weapons
4. **Earth layers** — crust, mantle, core, each with its own look, hazards, creatures
5. **The Drill** — giant moving base you return to (test if it's fun vs. simple surface camp)
6. **Surface camp** — small town that grows with unlocks
7. **Graphics pass** — Blender 3D → pixel sprites pipeline, dynamic lights, glow, parallax, particles
8. **Co-op** — couch first; online if decided
9. **Modes**
   - Classic (10–20 min runs)
   - Real Scale 1:1 — dig to Earth's center (6,371 km), real milestones
     (4 km deepest mine, 12.2 km Kola borehole, ~35 km mantle, 2,900 km outer core)
     needs exponential speed upgrades + floating origin
   - Time Attack (5 min), Daily Dig (shared seed + leaderboard), Hardcore (one life)
   - Ocean 1:1 (Mariana Trench, 11 km)
