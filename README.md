# Tiny Block Gameplay

The shared Godot gameplay runtime for [Tiny Block](https://tinyblock.nosuchgames.com) and [Tiny Block Server](https://github.com/hardtab/tinyblock-server).

This repository is the single source of truth for world simulation, block and biome definitions, rendering helpers, multiplayer protocol code, profiles, reactions, voice chat, and world persistence. The game client and dedicated server both pin the same commit as a Git submodule at `gameplay/`.

## Integration

```bash
git submodule update --init --recursive
```

Godot consumers load scripts from `res://gameplay/scripts/`. Platform integrations stay in the parent repositories:

- Tiny Block owns input, stores, ads, achievements, analytics, music, and CrazyGames integration.
- Tiny Block Server owns the headless entry point, deployment, and its analytics adapter.
- Each consumer owns the native WebRTC binaries required by its target platforms.

`WorldStore` accepts an optional persistence adapter. The web client injects its CrazyGames adapter; dedicated servers and native clients use local storage.

## Compatibility rule

Gameplay changes are released here first. Consumer repositories then update their submodule pointer and run their own full test/export pipelines. A client and server built from the same gameplay commit share exactly the same mechanics.

## License

[MIT](./LICENSE). Third-party emoji artwork remains under its license in [`assets/emoji/LICENSE.txt`](./assets/emoji/LICENSE.txt).
