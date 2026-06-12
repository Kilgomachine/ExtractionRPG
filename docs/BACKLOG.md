# EXTRACT — Living Backlog

We build FROM this list, ON this list, and TO this list. Items move to DONE
with the commit that shipped them. Add freely; nothing here is forgotten.

## Up next (agreed, not yet built)
- [ ] **Pre-raid loadout menu**: pick equipment before deploying (pairs with camp/stash — Phase 5/6 work)
- [ ] **REMOVE the testing respawn button** on the death panel once the loop is complete (added 2026-06 for testing)
- [ ] **Charm as an expanding wave**: visible radial AOE from the Siren that charms on touch
      (currently charm applies instantly at song end)
- [ ] **Per-player aggro tables**: aggro VALUES per player (damage adds, decay over time, highest wins)
      — current version is last-attacker-wins + sound investigation
- [ ] **Glimpse suspicion**: a split-second sighting makes enemies investigate rather than nothing
- [ ] **Spectate teammates when dead** (vision-cone spectating per the design doc)
- [ ] **Stash & persistence**: extracted items land in a per-client stash (JSON), camp screen
- [ ] **Downed/revive state** before death (Arc-Raiders-style rescue window)
- [ ] **CI release workflow**: auto-build + GitHub release on tag (currently manual headless export)
- [ ] **Purge large blobs from git history** (old buildv binaries) — needs a history rewrite + force push
- [ ] Teammates can't see each other's cast bars; host rejection of HEAL is silent (reload now nacks)
- [ ] Armor-tier chunking (ZS damage model) · damage numbers · screenshake
- [ ] Real navmesh pathing (NavigationRegion2D) — enemies currently slide along walls

## Gate 1 review minors (triaged 2026-06-12 — real, deferred; none block play)
Latent crash class:
- [ ] player.gd `_counts` seed has 11 entries but ITEM_TYPES is 12 — any pre-sync read of
      ITEM_AMMO_SMALL on a joining client is an OOB (same class as the old 3-entry COLORS bug)
Late-join gaps (cosmetic-to-mild):
- [ ] Existing players' loadout/equipped gun not re-sent to a joiner (wrong gun shown until next sync)
- [ ] Shooter mid-attack telegraph not replayed (only enemy missing it in host_full_sync_to)
- [ ] ExtractionZone `_active` pulse state not replayed to joiners
Enemy behavior edges:
- [ ] Shooter killed WHILE stunned respawns frozen (stun never decays in the dead branch)
- [ ] Exploder has no hit-aggro (only chaser that ignores being shot) and no _stunned_fx broadcast
      (flashbang freezes it invisibly)
- [ ] Igniter cone direction inherits the steering swerve from the cast-entry frame (flame can
      point 0.6rad off the actual target)
- [ ] Shooter muzzle event legal up to 368px — slightly over the 324 off-screen law line
- [ ] Charm breaks the instant the Siren leaves YOUR personal LoS (node.visible check) — decide
      if that's a feature (break by looking away?) or a bug
Fire/zones:
- [ ] Fire `_covers` grants +10px/+0.06rad beyond the drawn edge; cone fan goes stale against
      ring walls raised AFTER the fan was built
UI/feel:
- [ ] Phantom fire feedback: cooldown/recoil/camera kick apply locally before host validation —
      a rejected shot still kicks
- [ ] Dead players can't close the bag (B ignored once dead); DeathPanel occludes the ESC menu
- [ ] Stamina bar ColorRects are MOUSE_FILTER_STOP — a dead strip bottom-left blocks clicks/fire
- [ ] Own name tag shows above your own pawn (meant to be teammates-only)
- [ ] refresh_bag rebuilds every row on EVERY loadout sync, even hidden (GC churn per shot)
- [ ] _remote_running sticky across packet loss (ghost sprint trails)
State hygiene:
- [ ] ExtractionZone `_progress`/`_searching` not cleared for players who DIE inside the zone
- [ ] Concurrent corpse+locker search possible (asymmetric guard) — corrupts the one _searching dim
- [ ] _xp/_level/_skill_points survive peer disconnect (rejoiner inherits them — decide: feature?)
- [ ] Extracted client can _request_join again and re-enter the same raid with a fresh loadout
- [ ] Corpse spill cap 20 still destroys overflow (now lowest-value-first) — better: leave the
      remainder ON the corpse for a second retrieve
- [ ] Console `give` accepts negative amounts (host-only surface)
- [ ] Doc nit: player.gd header still claims slot-1 re-press cycles all guns
Trust model (accepted while friends-only):
- [ ] Laser/grenade/etc requests are not host-rate-limited the way _request_fire is

## Done (most recent first)
- [x] **GATE 1: Debt review** (d214e72) — 6-lens adversarial review, 66 findings: all 8 criticals +
      25 importants fixed same-session (applied-damage XP, ammo quantum, extraction stream/dupe
      fixes, full late-join replay, stun-cancels-slam, console input gate, reload nack, extract
      panel unlock); 33 minors triaged above. Gauntlet green incl. late-join-into-corpses.
- [x] **The Waller (Chamber)** — wall-ring trap + flame flood with the safe cone · in-game name tags ·
      per-gun recoil (camera kick + body shove) · testing respawn button
- [x] Player names (Steam default, manual fallback) · UI clicks don't fire · equipped section in bag ·
      PERMADEATH (death = lootable corpse with your actual items, no respawn) · extraction points
      (loud!) · F2 dev console · teammates hidden outside LoS · XP/levels/skill points + placeholder tree
- [x] Weapon-slot inventory, shields, enemy corpses, charm v2, hit-aggro, gunshot alerts, GitHub release
- [x] Siren · Igniter cone + tracking · Exploder · patrolling Shooters · Hugger · Mother Hugger · 4x map ·
      grenades · stamina/sprint/trails/hearing · friendly fire · scoreboard · SFX
