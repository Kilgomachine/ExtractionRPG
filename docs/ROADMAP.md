# MVP Roadmap — EXTRACT (Godot 4.6.3 .NET, 1–3 player co-op vertical slice)

Solo dev, part-time (~10–15 hrs/wk), some scripting background, first Godot project.
**Honest timeline: 14–20 weeks part-time with the scope cap below. Uncapped, a first-timer building
everything multiplayer-aware realistically lands at 20–30 — the cap is the plan, respect it.**

> **HARD SCOPE CAP (the anti-explosion contract):** 1 map · 1–2 weapons · 2 bandit archetypes ·
> slot-grid inventory (NOT Tetris) · no vendors/quests · minimal camp · lobby-locked raids (no join-in-progress).
>
> **Golden rules:**
> 1. Project lives at `C:\GameDev\ExtractionRPG\` — never OneDrive. ✅ (done, git initialized)
> 2. **Pin Godot 4.6.3 .NET.** Take 4.6.x patches; **skip 4.7.0**; re-evaluate at 4.7.1+ only if needed.
> 3. **Typed GDScript enforced**: untyped-declaration warnings promoted to ERRORS in Project Settings.
> 4. Split authority: *client owns its own avatar; host owns the world; loot is request → grant.*
> 5. Synchronizer = transforms only. Inventory/loot/extraction = reliable RPCs with item-ID payloads.
> 6. Saves = JSON only (never Resources/ConfigFile for player data — code-execution risk, godot#80562).
> 7. All Steam/lobby/peer code is GDScript, forever. C# (if ever) sits behind a GDScript-facing API.
> 8. In networked gameplay nodes: input-gathering separated from state-mutation (keeps the netfox/PvP door open free).
> 9. Every system is built networked from day one. (Dome Keeper devs on retrofitting: "unreasonable, usually prohibitive.")

---

## Phase 0 — Setup  ·  ~3–4 days  ·  ✅ DONE 2026-06-11
- [x] Godot 4.6.3 .NET installed; project created (relocated to `C:\GameDev\ExtractionRPG`, git initialized, renamed EXTRACT).
- [x] Open the project from the new location.
- [ ] Delete the old OneDrive copy (`OneDrive/Documents/Project/new-game-project`).
- [x] Project Settings: untyped GDScript warnings promoted to errors (set in project.godot; addons excluded by default).
- [x] **GodotSteam GDExtension v4.19.1-gde** installed from Codeberg, bundled in `addons/godotsteam/`.
- [x] Pins recorded in README: Godot 4.6.3 .NET, GodotSteam 4.19.1, Steamworks SDK 1.64.
- [ ] Watch **"Keeper to Keepers"** (GodotFest 2025, Chris Ridenour) — the production postmortem of this exact stack. Skim the **Skillet** example (GodotSteam org).

**Exit:** ✅ project opens, GodotSteam loads — `steamInitEx()` returned status 0 with App ID 480. *"It runs."*

## Phase 0.5 — Walking skeleton  ·  ~1–1.5 weeks  ← IN PROGRESS
**Two-step ladder — never debug Godot MP concepts and Steam plumbing at the same time.**
- [x] **ENet first:** menu host/join, networked player (split authority, ready-peers gating), greybox map with
      occluder walls + vision cone. Verified via Run Multiple Instances AND headless auto-host/auto-join harness.
      (Implementation note: manual host-orchestrated spawn RPCs instead of MultiplayerSpawner — fits the
      join-order slot assignment and lobby-locked future.)
- [x] **The Steam swap (code):** `SteamLobby` autoload — `steamInitEx(480, embed_callbacks=true)`,
      `createLobby(FRIENDS_ONLY)` → `allowP2PPacketRelay(true)` → `host_with_lobby()`; client `join_requested`
      → `joinLobby()` → `connect_to_lobby()`; `+connect_lobby` cmdline parsed; F1 = overlay invite dialog.
      Steam init verified live (status 0, real Steam ID).
- [ ] **The real-world test:** friend on their own PC/account joins via Steam invite. Test on **exported builds**
      (steam_api64.dll + GDExtension libs beside the exe; overlay invites are unreliable from the editor).
      Logistics: needs a second Steam account + second machine/VM — that's the real cost of this week.

**Exit / GATE:** a friend on their own PC joins via Steam friends-list "Join Game"; two sprites move in sync.
*"Co-op is proven."* If Steam misbehaves → fallback ladder (community peer forks → noray relay) decided NOW, in week 2.

## Phase 1 — Control + THE VISION CONE  ·  ~1.5–2 weeks  ← VALIDATES THE 2D PIVOT
- [ ] WASD + mouse aim, free-rotation sprite (body/weapon layers), dodge roll on cooldown. Client-owned, synced via Synchronizer.
- [ ] Aim-extend: holding aim shifts camera toward cursor.
- [ ] **Vision cone prototype — two systems from the start:**
      *Rendered*: PointLight2D cone texture + shadows, CanvasModulate near-black, LightOccluder2D walls (via TileSet occlusion layer).
      *Detection*: raycast fan (for AI perception later). Enemies/loot outside the cone are hidden.
- [ ] Budget: ≤16 lights per CanvasItem, few shadow-casters, PCF5. TileMapLayer greybox map.
- [ ] Decide in-prototype: shared vision between friends? (recommended: yes, see each other's cones)

**Exit / GATE:** sneaking around a greybox map with the cone feels *tense and readable*, solo and with a friend.
*"The cone is the game."* If it disappoints, the 2D pivot's premise needs re-examination — better in week 3 than week 13.

## Phase 2 — Combat  ·  ~2–3 weeks  ← VALIDATES THE CORE BET
- [ ] Health + **armor-tier chunking** (ZS model: blocked ≈15%, unblocked 100%; ammo-vs-armor sets block chance). Host resolves all damage.
- [ ] 1 ranged weapon: host-simulated projectile, falloff, TTK ~1.5–3s open-field (slightly long, for revive windows).
- [ ] 1 active ability (smoke OR dash) + heal consumable. Cover = occluders block sight AND shots.
- [ ] **Downed state**: interact-revive by a friend; solo = downed becomes dead.
- [ ] **HARD RULE in code: AI/damage cannot engage beyond (camera view + aim-extend).** No off-screen deaths, ever.
- [ ] Hit feedback: flashes, numbers, screenshake (cheap, Godot tween-friendly).

**Exit / GATE:** a duel against a dummy/simple bot is tense, readable, winnable when shot first. *"Combat is fun."*

## Phase 3 — Bandit AI  ·  ~2 weeks
- [ ] NavigationRegion2D **baked** navmesh + NavigationAgent2D (node API only; RVO off or cosmetic). Host-side only.
- [ ] State machine: Patrol → Investigate (heard/saw via detection cone — symmetrical vision) → Engage (uses cover) → Flee at low HP.
- [ ] 2 archetypes (scout/heavy); loot on death; **mild player-count scaling: more enemies + aggression, never HP sponges.**

**Exit:** stumbling into a patrol is a real, beatable encounter for 1–3 players. *"Enemies make fights."*

## Phase 4 — Loot & inventory  ·  ~2 weeks
- [ ] Items as **custom Resources** (definitions only); ~8 items, 3 rarities; loot tables as Resources.
- [ ] **Wire format = item IDs** (reliable RPCs, PackedByteArray/JSON) — Resources never travel or sync.
- [ ] Containers + corpse bags, search interaction; **request → grant** pickup (host adjudicates — kills dupe races).
- [ ] Control-node **slot-grid** inventory with drag-drop; carried vs **secure pocket** (survives death).

**Exit:** two friends loot a building without dupes; bags fill; pocket persists through a death. *"Loot loop exists."*

## Phase 5 — Extraction, death & persistence  ·  ~2 weeks  ← THE OTHER HALF OF THE BET
- [ ] Raid timer + late-raid danger escalation (host).
- [ ] **Hunt-grammar extraction**: individual extracts allowed; together = shared ~30s countdown; enemies pause it;
      downed friend in zone blocks it; opening inventory resets it; small extract-together bonus.
- [ ] **Death**: corpse bag on map; friends can carry your gear out and hand it back; loot-loss severity = lobby toggle.
- [ ] **Dead = spectate teammates' vision cones.**
- [ ] **Stash: per-client local JSON** — host RPCs each client an authoritative "you extracted with X" at raid end.
      Host disconnect ends raid, gear preserved.

**Exit / GATE:** deploy together → push-or-extract decision → relief or rescue-mission → stashes update correctly even
when a different friend hosts next time. *"The loop grips."*

## Phase 6 — Camp, polish & playtest  ·  ~2 weeks
- [ ] Minimal camp/lobby: stash view, loadout pick, host/join via Steam, loss-severity toggle.
- [ ] HUD: health/armor, cooldowns, raid timer, compass to extracts. Menus, pause, basic SFX (footsteps matter — ZS lesson).
- [ ] Full raids with 2–3 real friends on real networks. Fix what breaks. Balance pass.
- [ ] **Playtest with 3–5 outsiders. Watch for "one more run."**

**Exit:** a duo of strangers completes a loop unguided and goes again. *"MVP done."*

---

## Timeline & gates

```
P0    ██ Setup                        3–4 d
P0.5  █████ Walking skeleton        1–1.5 wk  ← GATE: Steam co-op works
P1    ██████ Control + vision cone  1.5–2 wk  ← GATE: the cone is the game
P2    ███████████ Combat              2–3 wk  ← GATE: combat is fun
P3    ███████ Bandit AI                 2 wk
P4    ███████ Loot/inventory            2 wk
P5    ███████ Extraction/death          2 wk  ← GATE: the loop grips
P6    ███████ Camp/polish/playtest      2 wk
                                   ≈ 14–20 wk part-time
```
**Vertical-slice checkpoint at ~week 6–8:** one full raid loop, 2 players over Steam, win/lose gear end-to-end —
even if ugly. If that doesn't exist by week 8, cut scope again (drop ability, drop archetype #2), not quality of the loop.

## After the MVP — the PvP gate (only if the MVP earns it)
- Competitive PvEvP = adopt **netfox** rollback (active, June 2026): swaps the sync layer, transport survives.
  Affordable *because* golden rule 8 kept simulation tick-shaped. Re-evaluate vs Godot's own netcode state at that time.
- Or scope **PvP-lite** (host-auth, friends-only wagers) and skip rollback entirely.
- The real PvP costs are operational (anti-cheat, moderation, hosting) — commit only after co-op has proven the game.

## Reference shelf
- GodotSteam docs: godotsteam.com (source on Codeberg) · Skillet example game (GodotSteam org)
- "Keeper to Keepers" talk — GodotFest 2025 (Dome Keeper MP postmortem)
- netfox: foxssake.github.io/netfox (PvP gate) · noray (relay fallback)
- Genre studies: Zero Sievert (cone/loop), Duckov (death-as-objective, accessibility), Hunt (extraction grammar), Arc Raiders (downed/carry-out)
