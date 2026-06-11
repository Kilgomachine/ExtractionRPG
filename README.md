# EXTRACT (working title)

A top-down **2D co-op extraction RPG** for 1–3 friends. Deploy into a raid, loot, fight AI bandits,
and decide: push for more, or extract with what you've got. Die and your gear stays behind — but your
friends can revive you, or carry your gear out and hand it back.

Slower, RPG-paced combat (positioning, abilities, vision) instead of shooter reflexes — the bet is that
top-down + readable TTK makes extraction tension *fun* instead of frustrating.

## Docs

- [Game Design](docs/GAME_DESIGN.md) — pillars, core loop, co-op death/extraction design, architecture
- [Roadmap](docs/ROADMAP.md) — MVP phases, gates, and the hard scope cap

## Version pins (do not drift)

| Dependency | Version | Notes |
|---|---|---|
| Godot | **4.6.3 .NET** | Take 4.6.x patches; **skip 4.7.0**; re-evaluate at 4.7.1+ only if needed |
| GodotSteam | **GDExtension v4.19.1-gde** | From [Codeberg](https://codeberg.org/godotsteam/godotsteam) (GitHub org is archived) / Asset Library id 2445 |
| Steamworks SDK | 1.64 | Bundled with GodotSteam build |
| Steam App ID (dev) | 480 (SpaceWar) | Until a real App ID exists |

## Ground rules (full rationale in the design doc)

- **Typed GDScript everywhere**; untyped-declaration warnings are promoted to errors.
  C# is reserve-only, behind a GDScript-facing API, and never touches Steam/networking.
- **Split authority**: clients own their own avatar; the host owns the world (AI, damage, loot, extraction).
  All loot pickup is request → grant via reliable RPCs.
- **MultiplayerSynchronizer syncs transforms only** — inventory/loot/extraction state travels as item-ID
  payloads over reliable RPCs, never as Resources/objects.
- **Player saves are JSON only** — never Resources or ConfigFile (object deserialization executes code on parse).
- Networked gameplay nodes keep input-gathering separate from state-mutation (keeps the future PvP/rollback door open).

## Getting started

1. Install **Godot 4.6.3 (.NET build)** and open `project.godot`.
2. Install the GodotSteam GDExtension (Asset Library id 2445) into `addons/`.
3. Steam must be running; dev App ID 480 is configured for local testing.
