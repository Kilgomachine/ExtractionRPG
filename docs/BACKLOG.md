# EXTRACT — Living Backlog

We build FROM this list, ON this list, and TO this list. Items move to DONE
with the commit that shipped them. Add freely; nothing here is forgotten.

## Up next (agreed, not yet built)
- [ ] **Pre-raid loadout menu**: pick equipment before deploying (pairs with camp/stash — Phase 5/6 work)
- [ ] **The Chamber** enemy: raises a wall ring around you + him, bursts the arena into flame except a safe
      cone behind him (FireZone already supports `safe_cone` — half the work is done)
- [ ] **Charm as an expanding wave**: visible radial AOE from the Siren that charms on touch
      (currently charm applies instantly at song end)
- [ ] **Per-player aggro tables**: aggro VALUES per player (damage adds, decay over time, highest wins)
      — current version is last-attacker-wins + sound investigation
- [ ] **Glimpse suspicion**: a split-second sighting makes enemies investigate rather than nothing
- [ ] **Adversarial review pass** over the last three feature batches (loadout, content patch, this one)
      — they shipped on smoke tests only
- [ ] **Spectate teammates when dead** (vision-cone spectating per the design doc)
- [ ] **Stash & persistence**: extracted items land in a per-client stash (JSON), camp screen
- [ ] **Downed/revive state** before death (Arc-Raiders-style rescue window)
- [ ] **CI release workflow**: auto-build + GitHub release on tag (currently manual headless export)
- [ ] **Purge large blobs from git history** (old buildv binaries) — needs a history rewrite + force push
- [ ] Teammates can't see each other's cast bars; host rejection of heal/reload is silent (ack rpc)
- [ ] Armor-tier chunking (ZS damage model) · damage numbers · screenshake
- [ ] Real navmesh pathing (NavigationRegion2D) — enemies currently slide along walls

## Done (most recent first)
- [x] Player names (Steam default, manual fallback) · UI clicks don't fire · equipped section in bag ·
      PERMADEATH (death = lootable corpse with your actual items, no respawn) · extraction points
      (loud!) · F2 dev console · teammates hidden outside LoS · XP/levels/skill points + placeholder tree
- [x] Weapon-slot inventory, shields, enemy corpses, charm v2, hit-aggro, gunshot alerts, GitHub release
- [x] Siren · Igniter cone + tracking · Exploder · patrolling Shooters · Hugger · Mother Hugger · 4x map ·
      grenades · stamina/sprint/trails/hearing · friendly fire · scoreboard · SFX
