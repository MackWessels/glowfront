# Glowfront — 3D Tower Defense

Glowfront is a custom 3D tower defense game built with [Godot 4.4.1](https://godotengine.org/).  
It features dynamic pathfinding, an evolving upgrade economy, and highly interactive building systems.  
The goal is to defend your base against waves of UFO-style enemies by building, upgrading, and reshaping the battlefield.

---

## Core Features

### Dynamic Tile Board
- Grid-based world with interactive tiles that can host towers, walls, and resource buildings.
- Real-time path recalculation: when a wall or tower is placed, enemies reroute immediately using dynamically generated paths.

### Build & Defend
- Towers: classic laser turret, Mortar (2×2 splash damage), Tesla Tower (chain lightning), Sniper Tower (long-range precision).
- Economy buildings: Miner (generates minerals during a run), Shard Miner (produces persistent meta-currency: shards).
- Walls: force enemies to take longer paths or reroute around defenses.

### Power-Up & Progression
- Two-currency system:
  - Minerals — earned and spent during each run for towers and upgrades.
  - Shards — persistent meta-currency for global upgrades.
- Upgrade options: tower damage, fire rate, range, critical chance/multiplier, multishot, base health and regeneration, board expansions.

### Smarter Enemies
- UFO enemy tiers: basic, elite, and carriers that drop minions mid-path.
- Scaling difficulty: enemy health, speed, and spawn variety increase with wave count.
- Spawner logic: burst spawning, lane offsets, and pacing adjustments (slow early waves, faster mid/late game).

### Player Experience
- Camera controls: orbit, zoom, pan, Q/E rotate, left-click drag for view vs. build mode.
- Visual feedback: tile highlights (buildable, blocked, pending), hatch animations for multi-tile builds.
- Lighting and materials: steel-like tile materials, glowing energy effects, dynamic board lighting.

---

## Current Status

Glowfront is actively under development:
- All major building systems are functional.
- Enemy waves spawn and scale properly.
- Core UI and camera systems are in place.
- Ongoing work: performance optimization, lighting polish, new tower types.

---

## Tech Stack

- Game Engine: Godot 4.4.1 (GDScript)
- 3D Assets: Custom-made with Blender (turrets, enemies, tiles)
- Version Control: Git & GitHub
- Target Platform: Desktop (Windows — main test environment)

---

## How to Play (Development Build)

1. Open the project in **Godot 4.4.1**.
2. Start a run from the main scene.
3. Use minerals to place turrets, miners, and walls on tiles.
4. Force enemy reroutes by strategically blocking paths.
5. Collect minerals and shards to strengthen defenses.
6. Survive as many waves as possible.

---

## Planned Features

- Additional turret types (AoE, slow, support).
- More advanced meta-upgrade tree.
- Improved visual effects and UI feedback.
- Leaderboards and run statistics.
- Save/load persistent meta-progression.

---

## Development Notes

This project emphasizes:
- Performance — efficient pathfinding and grid updates.
- Modular design — towers, economy, and UI built for easy expansion.
- Iterative testing — gameplay systems refined incrementally (spawn pacing, lighting, materials).

Contributions and feedback are welcome.  
For ideas, bug reports, or improvements, open an issue or pull request.

---

## License

This game is developed for personal and portfolio use.  
Check `LICENSE` (if present) for details before reusing code or assets.
