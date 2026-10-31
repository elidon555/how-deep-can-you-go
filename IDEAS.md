# How Deep Can You Go — Ideas & Plan

Rule: build one small piece, play it, then add the next. Nothing here is lost — it's just "later".

## Now: Step 1 — "Is digging fun?"
- [x] Little guy, run + jump
- [x] Dig down / sideways / up through generated ground (endless, made in chunks)
- [x] Depth counter (1 tile = 1 m), best depth
- [x] Gets harder deeper (dirt → stone → hard rock), gets darker deeper
- [x] Basic juice: dust particles, screen shake, crack overlay

## Decisions made (can change later)
- Engine: Godot 4 (built-in 2D lighting/glow for the Dead Cells-style look, exports to web)
- Theme: digging toward the Earth's core
- Co-op: "maybe" → Step 1 is single player, decide online yes/no before enemies get added

## Later list (rough order, pick what sounds most fun after playing)
1. **Fuel / stamina** — the "go deeper or turn back" tension
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
