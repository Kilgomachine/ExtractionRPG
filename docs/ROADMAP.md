# EXTRACT — Roadmap v2 (agreed 2026-06-12)

> v1 (the MVP phase plan) served its purpose and was outgrown by reality: the feature-discovery
> firehose of June 10–12 built most of Phases 1–4 out of order and found the fun. v2 flips the mode:
> **we dev toward GATES, pulling from [BACKLOG.md](BACKLOG.md), and every session ends shippable.**

## Where we actually are (June 12, 2026)

Built & verified: Steam co-op (friend-tested) · vision-cone stealth w/ personal LoS · 7 enemy types
incl. 2 bosses (Mother, Waller) · 4 guns w/ recoil + ammo/reload · grenades (frag/smoke/flash) ·
shields · stamina/sprint/hearing/trails · friendly fire · permadeath w/ lootable player corpses ·
two-step looting (lockers + corpses) · extraction points · XP/levels/skill points (placeholder tree) ·
scoreboard · names · dev console · 4400×3200 map · procedural SFX · GitHub release pipeline.

## The Law (process standard — non-negotiable)

1. **Every session ends shippable**: headless gauntlet green → commit → push. No exceptions.
2. **RPC-touching code gets an adversarial review BEFORE push** — not "someday."
3. **Sessions start by reading BACKLOG.md and end by updating it.** It is the single source of truth.
4. **Roles**: Firas = creative director (plays daily, feel notes, design calls, taste).
   Claude = builder (implement, review, release, keep docs honest — including calling out skipped standards).

## Golden rules (carried from v1, still law)

- Project lives at `C:\GameDev\ExtractionRPG\` — never OneDrive. Builds/zips never in git.
- Godot 4.6.3 .NET pinned (skip 4.7.0). Typed GDScript, untyped = error.
- Split authority: client owns its avatar; host owns the world; loot is request → grant.
- Saves = JSON only (Resource/ConfigFile player-saves = code execution, godot#80562).
- Steam/lobby/peer code is GDScript forever. Networked from day one, always.
- No off-screen engagement, ever. Every attack telegraphs. Every threat has an out.
- Vision is PERSONAL (no shared team sight) — decided in playtest, keep it.

---

## GATE 1 — The Debt Review  ·  ~1 session  ·  NEXT UP
One full adversarial review pass over the un-reviewed batches (loadout/shields/corpses,
content patch, extraction/permadeath, Waller). Fix criticals same-session.
**Exit:** review findings triaged to zero criticals; gauntlet green.

## GATE 2 — RAID ZERO: the complete loop  ·  ~2–3 weeks part-time
Camp → loadout from persistent stash → deploy → raid → extract (loot banks) OR die (loot lost) → camp.
- [ ] Per-client stash persistence (JSON; host RPCs authoritative extract payloads)
- [ ] Camp/loadout screen (pick gear from stash before deploying)
- [ ] Downed/revive state (the co-op soul: interact-revive window before death)
- [ ] Raid timer + late-raid escalation
- [ ] REMOVE the testing respawn button
**Exit:** the loop runs start-to-finish with 2 players over Steam, stashes correct across host rotation.

## GATE 3 — The Stranger Playtest  ·  1 evening + fixes
Five people who aren't friends. A build link. Silent observation.
**Exit verdict:** do they say "one more run"? → YES: tune & extend. NO: diagnose before building more.

## GATE 4 — The Art Spike  ·  ~1 week
One room, one enemy, one player sprite in a committed style. Learn what the game looks like
and what art costs. **Exit:** a style decision we'd put on a Steam page.

## Beyond (unordered, backlog-driven)
Real skill tree effects · armor chunking · navmesh pathing · more raid content · Steam page + demo ·
netfox/PvP question (the original thesis!) · everything in BACKLOG.md.
