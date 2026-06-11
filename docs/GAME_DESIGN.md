# Extraction RPG — Game Design (Co-op MVP Vertical Slice)

> Working title: **EXTRACT**
> A top-down **2D** RPG-paced extraction game for 1–3 friends. Inspired by Tarkov / Arc Raiders /
> Zero Sievert, built in **Godot 4.6 (.NET build), GDScript-first**, leaning hard into the engine's strengths.
> Closest shipped analogs: **Zero Sievert** (presentation, loop) + **Escape from Duckov** (accessibility, tone of loss).

---

## 0. The market said yes (June 2026 reality check)

- **Escape from Duckov**: 3M sales in 3 weeks; its **#1 documented complaint is "no co-op."** That gap is this game's whole pitch.
- **Zero Sievert**: ~86% positive; proves top-down extraction works. Its #1 complaint (off-screen deaths) is fixed here *by rule* (§4).
- **ZERO Sievert 2** (announced April 2026, EA likely late 2026/2027): 4-player co-op top-down extraction — direct competitor AND
  concept validation. **Differentiation: 2–3 player rescue-driven intimacy (death = rescue objective, shared vision teamwork)
  and short 15–25 min raids — not simulation depth.** Don't try to out-Tarkov them.

## 1. Design pillars

1. **Tension over twitch.** Positioning, information, cooldowns, and knowing when *not* to fight. Slow-ish TTK
   (lethal but readable) + top-down = decisions beat reflexes.
2. **The vision cone IS the game.** Zero Sievert-style ~90° sight cone + fog of war. In co-op it compounds for free:
   friends' cones overlap, covering each other's backs becomes emergent teamwork with zero extra systems.
   This is also Godot's single best 2D trick (2D lights + occluders) — engine strength and core mechanic are the same thing.
3. **Loss stings, friends rescue.** Dying drops your gear — but a friend can revive you, or carry your gear out and
   hand it back. A wipe is a story; a death is an objective, not a quit-to-lobby moment.

## 2. The core loop (one raid, 15–25 min)

```
CAMP (stash/loadout) → DEPLOY (1–3 friends) → RAID: loot + fight AI raiders → EXTRACT or DIE → CAMP
```
- **Extract** = keep everything carried. **Die** = your corpse bag stays on the map; friends can recover your gear, or you can run back next raid (Duckov model).
- **Secure pocket**: small, upgradeable container (keys/quest items/1 valuable) that survives death — the genre's
  highest-leverage rage-quit reducer (Tarkov gamma / Duckov pet slot).
- **Loot-loss severity is a lobby toggle** (Zero Sievert's Hunter mode model) — friends self-tune the punishment.

## 3. Co-op death & extraction design (a core MVP system, NOT post-MVP)

- **Downed state** before death: interact-revive by a friend (Arc Raiders model). Downed in extract zone blocks the timer.
- **Dead**: corpse bag persists; living friends can carry the dead player's gear out and return it (self-insurance via friendship).
- **Dead players spectate through teammates' vision cones** — nearly free given the vision system, and turns waiting into scouting.
- **Extraction grammar (Hunt: Showdown rules)**: individual extraction allowed (no hostage situations); standing together shares
  one ~30s countdown; nearby enemies pause it; opening inventory resets it (anti-AFK tension). Small bonus for extracting together.
- **Difficulty scales mildly with player count** (enemy count + aggression — NEVER bullet-sponge HP).

## 4. Combat design

- **TTK**: lethal but readable, ~1.5–3s sustained in the open; longer with cover/abilities. Slightly longer than ZS solo so a
  buddy has a revive-reaction window. Lethality via **armor-tier chunking** (ZS model: blocked shot ≈ 15% damage,
  unblocked 100%, ammo-vs-armor sets block chance) — never raw HP inflation.
- **Outs**: dodge roll (cooldown), hard cover (occluders block sight AND shots), 1 active ability (smoke/dash) on cooldown, heal consumable.
- **THE HARD RULE — no off-screen deaths**: AI may not acquire or engage a player beyond (camera view + aim-extend distance).
  Symmetrical vision between player and AI. This rule fixes Zero Sievert's most-cited complaint at zero content cost.
- Aim-extend: holding aim shifts the camera toward the cursor (ZS pattern) — information as a verb.

## 5. Technical architecture (Godot 4.6.3 .NET — decided & researched 2026-06)

### Pins & language (do not drift)
- **Godot 4.6.3 .NET, PINNED.** Auto-adopt 4.6.x patches. **Skip 4.7.0** (stable lands mid-project); re-evaluate at 4.7.1+ only if it ships something we need.
- **GDScript, typed, enforced**: Project Settings → promote *untyped declaration* warnings to **errors**. Use `Dictionary[K,V]` and abstract classes for item/loot/AI data models.
- **C# is a reserve, not a start**: ~84/16 community split favors GDScript; C# can't see GDExtension classes natively; in-editor .NET reload is fragile.
  If a C# module ever appears, it sits behind a narrow GDScript-facing API and **never touches Steam/networking**.
- **GodotSteam GDExtension v4.19.1-gde** — from **Codeberg** (codeberg.org/godotsteam; the GitHub org is archived — ignore it). Steamworks SDK 1.64. Asset Library id 2445.

### Networking model (the load-bearing decisions)
- **Transport**: Godot high-level multiplayer (`@rpc`, MultiplayerSpawner/Synchronizer) over GodotSteam's **SteamMultiplayerPeer**
  (Steam relay, NAT traversal, friends-list "Join Game", $0 servers). Production-proven by Dome Keeper (April 2026, 8-player co-op).
  Transport-agnostic: ENet for local dev, Steam for real sessions — zero gameplay-code change.
- **SPLIT AUTHORITY** (not naive host-auth — Godot has no client prediction, so host-simulated movement would lag every keypress by a full RTT):
  - **Each client owns its own player's transform/aim/animation** (Synchronizer authority = that peer). Friend-trust accepted.
  - **Host owns the world**: AI raiders, damage resolution, loot rolls, container contents, extraction timers.
  - **Request → grant for all loot/equip/transfer**: client requests, host adjudicates, host broadcasts. Kills the two-players-grab-one-item dupe race.
- **MultiplayerSynchronizer = transforms and simple primitives ONLY.** Inventory/loot/extraction state goes over explicit
  **reliable RPCs with serialized payloads (item IDs in PackedByteArray/JSON)** — engine limits are real: can't sync Objects/Textures,
  runtime-added properties don't replicate, >64 on-change properties break.
- **Session model**: raids are **lobby-locked** (no join-in-progress — late-join has open engine issues); **host disconnect ends the raid,
  gear preserved** (no host migration exists); **stash is per-client local** — host RPCs each client an authoritative
  "you extracted with X" payload at raid end, so rotating hosts never forks saves (matches ZS2's published co-op model).

### ⚠️ Security rule (non-negotiable)
- **Saves are JSON via FileAccess (or object-free `var_to_bytes`) ONLY.** Never load Resources, `str_to_var` with objects,
  or ConfigFile as *player* save files — embedded-Object deserialization executes code on parse (godot#80562, still open 2026),
  and extraction players *will* share/edit stash files. ConfigFile only for video/audio settings.
- **Never enable `allow_object_decoding` on RPCs.** Item **IDs** travel the wire; `.tres` Resources stay local.

### Engine-strength feature map
| System | Godot tool (verified current, 4.6) | Note |
|---|---|---|
| Vision cone + fog | **PointLight2D (cone texture, shadows) + LightOccluder2D + CanvasModulate** | TWO systems: rendered cone (lights) + detection cone (raycast fan) for AI. Budget: ≤16 lights/CanvasItem, few shadow-casters, PCF5. Cone is client-local rendering over host-synced positions (friends-only ⇒ acceptable) |
| Maps | **TileMapLayer** (TileMap is deprecated) + occluders in the TileSet occlusion layer | Every wall tile blocks sight automatically |
| AI navigation | **NavigationRegion2D baked navmesh + NavigationAgent2D** (node API, not raw server) | Never per-tile nav; RVO off or cosmetic |
| Items/loot | **Custom Resource classes** (.tres) as definitions; loot tables as Resources | Definitions only — runtime state is plain data |
| Inventory UI | Control-node **slot grid** with drag-and-drop | Slot grid, NOT Tetris multi-cell (multi-week trap) |
| Saves | JSON via FileAccess, per-client | See security rule |
| Art pipeline | **Free-rotation sprites** (body/weapon layers rotate to aim), CC0/paid top-down packs, additive sprites for glow/muzzle flash | 8-direction animation sets silently re-import the art cost the 2D pivot avoided |
| Renderer | GL Compatibility (already set) | Fine for 2D + 2D lights; runs on anything |

### Future PvP door (kept open at zero present cost)
- **netfox** (rollback netcode, MIT, actively developed — commits June 2026) is the competitive-PvP path. Adopting it later swaps the
  *sync layer*, not the transport. To keep that a refactor instead of a rewrite: in every networked gameplay node, **separate
  input-gathering from state-mutation in `_physics_process`**, few writers per state property, never mix input-owner and
  state-owner on one node. Do NOT adopt netfox in the MVP.

## 6. Key risks & mitigations

| Risk | Mitigation |
|---|---|
| Vision cone doesn't feel good (it justifies the whole 2D pivot) | **Prototype it week 1–2** — it's the pivot's validation gate |
| Steam transport sharp edges (disconnect crashes, rejoin timeouts reported) | ENet-first walking skeleton, then Steam swap; exported-build testing; fallback ladder: FishyFacepunch-equivalent → noray relay |
| Scope explosion | HARD CAP: 1 map, 1–2 weapons, 2 raider archetypes, slot inventory, no vendors/quests, minimal camp. Vertical-slice gate ~wk 6–8 |
| First-timer learning Godot + Steamworks + netcode at once | GDScript-first (the tutorial ecosystem), two-step skeleton ladder, Skillet example + Dome Keeper "Keeper to Keepers" talk as references |
| OneDrive | Project lives at `C:\GameDev\ExtractionRPG\` (done, git initialized). Docs stay in OneDrive |
| ZS2 ships first | Differentiate: 2–3 player rescue intimacy, short raids, accessibility & humor (the Duckov lesson) |
| Offline-decay/FOMO temptation | NEVER. (The Forever Winter's water system nearly killed it and was removed) |
