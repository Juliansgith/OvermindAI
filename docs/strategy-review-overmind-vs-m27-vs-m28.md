# Strategy Review: OvermindAI vs M27 vs M28

## Scope

This report compares the strategic design of the local versions of:

- `OvermindAI`
- `M27AI`
- `M28AI`

The goal is not just to say which AI is stronger. The goal is to identify:

- what strategic model each AI is actually using
- where Overmind is already strong
- where Overmind is structurally behind M27 and M28
- what changes would produce the highest payoff for Overmind

This review is based on code inspection of the current local mod copies under:

- `C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\mods\OvermindAI`
- `C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\mods\M27AI`
- `C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\mods\M28AI`

It is a strategy and architecture review, not a replay-based performance benchmark. Where behavior is inferred from code, that is stated as such.

## Executive Summary

Overmind is a good modern skeleton with several practical strengths:

- a clean scheduler and modular runtime
- an explicit strategic goal layer
- good anti-collapse recovery tooling
- solid factory anti-idle behavior
- respectable ACU safety logic
- some useful memory and risk tracking

However, its current strategic model is still much shallower than M27 and M28. The biggest reason is not "missing heuristics". The biggest reason is that Overmind does not yet have a strong enough world model.

M27 wins by being extremely stateful and exception-rich. It has heavyweight grand strategy logic, dense map/pathing knowledge, persistent platoon behavior, broad special-case counters, and a large number of tactical and operational overrides. It is powerful, but also very large and harder to evolve cleanly.

M28 appears to be the more mature architectural answer. It carries forward much of M27's strategic depth, but organizes it around:

- stronger zone and map abstractions
- explicit team and subteam coordination
- specialist modules for land, air, engineer, economy, ACU, and factory
- more distributed strategic reasoning instead of one giant central policy file

If the goal is to improve Overmind efficiently, it should borrow M28's structure more than M27's coding style. From M27 it should borrow selected concepts:

- temporary strategic modes
- richer helper and escort logic
- explicit "kill / protect / turtle / eco / air dominance" style overrides

The highest value conclusion is this:

**Do not try to make Overmind competitive by only adding more thresholds to the current modules. First upgrade the spatial model and force organization model.**

Until Overmind has better zones, route safety, front ownership, persistent combat groups, and better intel freshness tracking, any additional heuristics will have a limited ceiling.

## The Core Strategic Identity of Each AI

## Overmind

Overmind's current identity is:

- modular orchestrator
- lightweight strategic utility selection
- practical macro/tactical safeguards
- direct control over idle assets

Important modules:

- `lua/AI/Overmind/Scheduler.lua`
- `lua/AI/Overmind/GoalSelector.lua`
- `lua/AI/Overmind/ZoneModel.lua`
- `lua/AI/Overmind/OpponentModel.lua`
- `lua/AI/Overmind/Economy.lua`
- `lua/AI/Overmind/EconomyOptimizer.lua`
- `lua/AI/Overmind/T1Director.lua`
- `lua/AI/Overmind/FactoryController.lua`
- `lua/AI/Overmind/Combat.lua`
- `lua/AI/Overmind/EngineerDirector.lua`
- `lua/AI/Overmind/ScoutManager.lua`
- `lua/AI/Overmind/Watchdog.lua`
- `lua/AI/Overmind/Memory.lua`

This is a clean and sensible architecture. The scheduler runs modules at different cadences, the goal selector produces a coarse strategic mode, the director/controller layers translate that into production and movement, and watchdog/recovery code prevents obvious self-destruction.

The problem is not organization. The problem is that the modules mostly operate on shallow inputs:

- straight-line distances
- crude map control proxies
- current threat snapshots
- local deficit counts
- local idle-unit control

That makes Overmind coherent, but not deeply strategic.

## M27

M27's core identity is:

- heavyweight strategic overseer
- explicit grand strategies
- persistent platoon and helper systems
- dense map/pathing decomposition
- large override catalog

Important modules include:

- `lua/AI/M27Brain.lua`
- `lua/AI/M27Overseer.lua`
- `lua/AI/M27MapInfo.lua`
- `lua/AI/M27PlatoonUtilities.lua`
- `lua/AI/M27EngineerOverseer.lua`
- `lua/AI/M27FactoryOverseer.lua`
- `lua/AI/M27EconomyOverseer.lua`
- `lua/AI/M27AirOverseer.lua`

M27 thinks like a very seasoned heuristic bot. It tracks a huge amount of persistent state and then uses many specific decision rules to decide:

- when to push land
- when to turtle
- when to pursue eco
- when to go air dominance
- when to protect the ACU
- when to attempt ACU kills
- when to react to experimentals, artillery, nukes, firebases, and map-specific situations

M27 is strategically deep because it encodes a lot of game knowledge directly. It is strong because it has learned many ugly real-game cases. Its downside is size and complexity.

## M28

M28's core identity is:

- distributed specialist controllers
- strong zone and team abstractions
- subteam-based coordination
- rich local logic with cleaner overall structure

Important modules include:

- `lua/AI/M28Overseer.lua`
- `lua/AI/M28Map.lua`
- `lua/AI/M28Team.lua`
- `lua/AI/M28Land.lua`
- `lua/AI/M28Air.lua`
- `lua/AI/M28Engineer.lua`
- `lua/AI/M28Factory.lua`
- `lua/AI/M28Economy.lua`
- `lua/AI/M28ACU.lua`

M28 appears to be a more scalable design than M27:

- the map model is more formalized
- team-wide data is explicit
- land and air subteams exist as first class systems
- zones request support, MAA, scouts, and rally behavior
- factories and engineers are more clearly downstream of spatial and team needs

M28 looks like the best reference for where Overmind should go structurally.

## Deep Comparison by Strategic Area

## 1. Architecture and Scheduling

### Overmind

Strengths:

- clear module boundaries
- scheduler cadence is easy to reason about
- budget-aware loop is a good idea
- runtime state is compact enough to inspect and debug

Weaknesses:

- modules are still mostly polling current state rather than operating on richer persistent plans
- many behaviors emerge from repeated re-issuance rather than durable task ownership
- strategic state is thin relative to the number of decisions being made

Implication:

Overmind is easy to extend, but currently lacks the depth of stored intent that M27 and M28 rely on.

### M27

Strengths:

- dense strategic state
- wide override coverage
- long-lived platoon and helper concepts
- deeply integrated tactical and strategic loops

Weaknesses:

- large and difficult to audit
- high coupling
- behavior likely depends on many cross-file assumptions

Implication:

M27 can do many strong things because it stores and reasons over more game-specific detail than Overmind.

### M28

Strengths:

- cleaner distribution of responsibility than M27
- strong separation by battlefield domain
- explicit team and subteam organization
- more scalable architecture for future features

Weaknesses:

- still very large
- still very heuristic-heavy
- requires strong discipline to keep cross-module contracts clean

Implication:

M28 is the best model for "organized complexity". Overmind should imitate this direction.

## 2. World Model and Spatial Reasoning

This is the single most important comparison point.

### Overmind

`ZoneModel.lua` is lightweight. It picks:

- best expansion position
- best raid position
- home threat
- expansion threat
- crude map control

It scores markers largely using:

- distance
- nearby enemy mexes
- nearby allied mexes
- local threat
- remembered risk

This is useful, but it is not a true spatial model. Important things it does not really model:

- land zones vs water zones
- plateaus and cliffs
- island isolation
- rally corridors
- front lines
- safe rear areas
- contested zones
- path risk by route segment
- adjacency and reinforcement depth
- firebase influence footprints

`MapControl` is also crude, because it is derived from allied mex count versus total mass markers. That is not enough to represent real board control.

### M27

`M27MapInfo.lua` and related systems provide much richer structure:

- pathing groups
- mex clusters by path group
- reclaim segmentation
- chokepoints
- rally points
- plateau concepts
- nearest enemy pathing relationships

This allows M27 to reason in operational terms:

- defend this route
- hold this choke
- eco this safely
- pressure this path group
- support this landmass

### M28

`M28Map.lua` and `M28Team.lua` are even more structurally valuable:

- land zones
- water zones
- plateaus
- islands
- ponds
- zone adjacencies
- zone pathing
- zone rally points
- support requests per zone
- zone-level intel coverage
- zone-level firebase threat relationships
- team-level tracking of which zones need support or MAA

`M28Land.lua` then uses this data for:

- zone threat refresh
- safe path checks
- rally/run logic
- raider target selection
- scout priority by zone
- support requests and assignments

### Strategic Verdict

Overmind is behind here by a large margin. This gap cascades into almost every other subsystem:

- production quality
- expansion quality
- scout quality
- land army cohesion
- ACU movement quality
- reaction speed to danger

If Overmind only fixes one strategic foundation, it should be this one.

## 3. Strategic Goal Selection

### Overmind

`GoalSelector.lua` selects between:

- `hold`
- `expand`
- `raid`
- `tech`
- `all_in`

The selector uses:

- eco state
- map control
- raid and expansion scores
- opponent posture
- relative power
- momentum
- time

This is good and worth keeping. It is explicit, readable, and testable. It also includes hysteresis, which is important.

But its inputs are coarse, so the output is necessarily coarse. "Expand" means much less when the AI does not have a strong concept of safe expansion lanes, supporting fronts, fallback positions, or zone ownership.

### M27

M27 is much richer here. It has explicit strategic modes such as:

- land main
- air dominance
- protect ACU
- ACU kill
- eco and tech
- turtle
- land rush

These decisions are influenced by:

- map/pathing conditions
- firebase coverage
- enemy composition
- air/bomber effectiveness
- chokepoint posture
- current pressure
- ACU conditions
- late-game threats

M27's selector is more game-aware and more scenario-aware.

### M28

M28 seems less dependent on one big symbolic grand strategy enum. Instead, behavior emerges from:

- team-level flags
- subteam conditions
- map strategy flags
- domain-specific specialist decisions

That makes it look less dramatic, but often more grounded. The system can adapt locally without needing the entire AI to commit to a single headline plan.

### Strategic Verdict

Overmind's explicit goal selector is conceptually good. It should be preserved, but demoted to one layer among several. It should not be the main source of strategic sophistication. It needs stronger downstream systems.

## 4. Economy and Teching

### Overmind

`Economy.lua` and `EconomyOptimizer.lua` do useful work:

- detect stall states
- produce aggression and spend pressure
- gate eco decisions by trends and storage
- adjust mex upgrades, factory expansion, power, and mass fab policy

This is better than vanilla-style static builder logic. It is responsive and understandable.

However, it is still threshold-centric rather than planning-centric. It does not deeply integrate:

- zone safety
- reclaim opportunities by area
- teching relative to front stability
- team composition needs
- multi-front pressure

There is also a concrete implementation issue:

- `Economy.lua` populates `MassStored`, `EnergyStored`, `MassTrend`, `EnergyTrend`, `StallingMass`, `StallingEnergy`, `UnitCount`, `UnitCap`, and `UnitLoad`
- several other modules read `MassStorageRatio`, `EnergyStorageRatio`, and income-like fields that are not populated there

Affected readers include:

- `EconomyOptimizer.lua`
- `FactoryController.lua`
- `EngineerDirector.lua`
- `MexDefense.lua`
- `RadarFallback.lua`
- `Watchdog.lua`
- `T1Director.lua`

That means part of Overmind's policy layer is currently running on nil-defaulted values. This is not a small detail. It weakens the AI's decision quality in multiple places.

### M27

M27 has a much more interventionist economy system:

- pause and unpause logic
- strategy-dependent upgrade pacing
- reclaim and structure replacement logic
- HQ upgrade decisions
- mex upgrade forcing in eco strategies
- resource-aware production restrictions

It behaves more like an economy operations manager than a threshold adapter.

### M28

M28's economy system appears more integrated still:

- team economy is tracked explicitly
- focus-on-T1-spam mode exists as a team-level posture
- mex and HQ upgrades are coordinated across team state
- air/navy contingencies affect upgrade willingness
- resource flow influences broader strategic posture

This is a more operational economy model.

### Strategic Verdict

Overmind's economy layer is a good start, but it needs:

- a correct runtime contract
- stronger coupling to map and force demands
- less dependence on static thresholds

## 5. Factory Production and Composition

### Overmind

Overmind has two important production layers:

- `T1Director.lua`
- `FactoryController.lua`

`T1Director.lua` is really the strategic composition module. It decides modes like:

- stabilize
- defend
- land_pressure
- air_control
- naval_contest
- expand

And from those modes it derives desired counts for:

- factory types
- land mix
- air mix
- sea mix
- base radar and static defense

`FactoryController.lua` then turns deficits into queue top-offs and enforces queue invariants.

This is one of Overmind's best current systems. It likely gives the AI consistent macro throughput and reduces factory idling a lot.

The weakness is structural:

- composition is mostly deficit-filling
- there is little notion of persistent force packages
- production is not deeply tied to specific fronts or zones
- the director is still very T1-centered in concept and naming

### M27

M27 factory logic is more context-heavy:

- strategy-aware
- threat-aware
- escort-aware
- low-mass aware
- map/path aware
- ACU-state aware

It is closer to a counter-system and support-system than a simple desired-count system.

### M28

M28 seems to place factory logic under broader team and zone needs:

- subteams matter
- support shortages matter
- land and air demand are tied to zone state
- blacklists and preferences are updated dynamically by subteam

This is a stronger structure than a single global deficit list.

### Strategic Verdict

Keep Overmind's queue maintenance logic. Replace or generalize the strategic director above it.

Specifically:

- `T1Director.lua` should become `ForceDirector.lua`
- desired production should be expressed per force role, per tech phase, and eventually per front/subteam
- factories should build into named demand buckets, not only raw unit-count deficits

## 6. Engineer and Expansion Strategy

### Overmind

`EngineerDirector.lua` is practical and useful. It already does some good things:

- recalls endangered engineers
- preserves base engineer floor
- dispatches idle engineers to mex expansions
- reclaims enemy mexes opportunistically
- respects some threat and memory constraints

This is a better foundation than many lightweight AIs have.

But its expansion model is still basic:

- single engineer dispatch
- marker-by-marker logic
- simple safety tests
- limited route planning
- little staged forward infrastructure logic
- no real fortification plan per zone

### M27

M27 engineer logic is one of its strongest areas. It supports:

- structured action catalogs
- firebase building
- plateau expansion
- shielding and TMD/TML behavior
- civilians and special map interactions
- game-ender templates
- deep build assignment state

### M28

M28 engineer logic looks even more zone-aware:

- land/water zone movement
- reclaim and expansion by zone
- experimental/game-ender management
- special shield defense
- support for teammates
- richer spatial planning

### Strategic Verdict

Overmind is not terrible here, but it is still one layer too simple. Engineers need to become part of a zone planner, not just a safe-marker dispatcher.

## 7. Scouting and Intel

### Overmind

`ScoutManager.lua` is functional but simple:

- enemy main
- raid lane
- expansion lane
- midline

This is enough to avoid complete blindness, but not enough to drive high-end strategy.

Overmind also has some memory systems:

- combat momentum
- economic momentum
- risk hotspots
- route blackspots
- engineer loss hotspots

That is a useful scaffold. The problem is that the intel layer is not rich enough to feed those systems consistently.

### M27

M27's air logic and scouting logic are much deeper:

- segmented scouting
- bomber effectiveness models
- escort logic
- scout assignment by need
- dedicated responses to intel gaps

### M28

M28 is especially strong here because intel is zone-based:

- zone radar coverage matters
- units can flag for priority scouts
- subteams coordinate scouts
- important units can request dedicated air or land scouting
- zones can request support based on visibility and threat

### Strategic Verdict

Overmind should move from "send scouts to a few points" to:

- intel freshness by zone
- scout budget by zone value and danger
- dedicated scout support for ACU, experimentals, raiders, and major pushes
- radar and omni coverage planning per zone

## 8. Land Combat and Force Management

### Overmind

`Combat.lua` is one of the best Overmind modules. It already includes:

- land pressure cycles
- staging/regrouping
- target selection
- escort checks for indirect units
- some attacker/defender splitting
- stuck-force repathing
- commander safety enforcement

This is good work. It means Overmind is not just randomly A-moving.

The gap is that it is still mostly operating over idle or loosely pooled units. It lacks a true persistent force manager with long-lived role identity.

What is missing:

- durable platoon ownership
- force-level mission state
- stable reinforcement lanes
- front assignment memory
- role-specific retreat/fallback logic
- deeper composition-aware assault behavior

### M27

M27 is very strong here because `M27PlatoonUtilities.lua` provides a broad custom platoon action model:

- attack
- run
- continue path
- repath
- assist
- reclaim
- coordinated attack
- ACU kill behavior
- helper attachments

This makes units behave as organized groups, not just opportunistically moved assets.

### M28

M28's land logic appears to be the more structured evolution of this concept:

- zone support requests
- safe path checks
- raider zone targeting
- priority scouting for specific land units
- rally points
- subteam-level production priorities
- threat-by-zone and range-aware reasoning

### Strategic Verdict

Overmind has a decent local combat controller, but it lacks an operational layer above it. This is why it will struggle to match M27/M28 on multi-front maps, cliff maps, islands, and prolonged midgame maneuver wars.

## 9. Air Strategy

### Overmind

Overmind has some air behavior through:

- `ScoutManager.lua`
- `BomberHarass.lua`
- composition requests from `T1Director.lua`

This is enough for light functionality, but not enough for mature air play.

What is missing:

- proper air-control state
- fighter escort policy
- bomber viability estimation
- torpedo/anti-navy air planning
- air staging logic
- protected strike routing
- target value and AA-overlap evaluation

### M27

M27 has a dedicated air overseer with:

- segmented air scouting
- bomber target shortlists
- anti-air assessment
- air-to-ground threat tracking
- torp bomber logic
- engineer and mex hunting

### M28

M28 air logic appears similarly deep and more team-integrated:

- air subteams
- support points and rally points
- bomber/gunship/air-AA threat tracking
- priority air scouts for valuable units
- torpedo target handling
- enemy hiding ACU checks

### Strategic Verdict

Overmind is far behind in air strategy. If improved, this will generate major Elo gain because air mistakes in FA are very expensive.

## 10. Navy and Water Awareness

### Overmind

Overmind has only moderate naval awareness:

- `ZoneModel.lua` counts nav markers
- `T1Director.lua` has `naval_contest`
- some sonar/naval defense production exists

This is functional but shallow.

### M27

M27 includes stronger navy loops and broader strategic handling of naval maps.

### M28

M28 explicitly models:

- ponds
- water zones
- torpedo needs
- water start situations
- support requirements tied to water areas

### Strategic Verdict

Overmind's naval logic is currently nowhere near M28's structural sophistication. This matters on maps where water is not optional.

## 11. ACU Strategy

### Overmind

Overmind's ACU behavior is actually one of its better systems.

`ACURole.lua` and `Combat.lua` give it:

- role states like retreat, anchor, assist, push
- leash logic
- safety recall
- escort sensitivity
- time-sensitive aggression

This is good. It is much better than "ACU randomly fights until it dies".

Still, it remains simpler than the reference AIs:

- fewer upgrade-path decisions
- less zone-aware aggression
- less cooperative multi-ACU logic
- weaker snipe/cancel-upgrade opportunities

### M27

M27 ACU logic is very detailed:

- health/run thresholds
- air snipe risk
- flank detection
- escort/scout/MAA helpers
- underwater and torpedo edge cases
- upgrade safety logic

### M28

M28 ACU logic is even broader:

- upgrade path planning
- safe-to-upgrade checks
- underwater starts and torpedo upgrades
- support-friendly-ACU-attack behaviors
- ACU snipe logic
- danger modes for ACUs
- retreat-to-shield and retreat-to-template logic

### Strategic Verdict

Overmind's ACU is a relative strength compared with the rest of Overmind, but still clearly behind M27 and M28 in strategic richness.

## 12. Defensive Play and Response to Big Threats

### Overmind

Overmind has some recovery and defense logic:

- `Watchdog.lua`
- `RaidDefense.lua`
- `MexDefense.lua`
- `RadarFallback.lua`

This is useful for resilience. It helps the AI recover from:

- missing factories
- lack of scouts
- air harassment
- insufficient engineers
- lack of basic static coverage

What it lacks is a robust late-game response model for:

- artillery races
- nuke/SMD timing
- experimental threats
- firebase creep
- teleport threats
- dedicated anti-snipe posture

### M27

M27 tracks these categories much more explicitly:

- enemy experimentals
- artillery
- nuke launchers
- SMD
- TML

### M28

M28 also appears to track large threat classes at team and zone level, with better support routing and template-driven defense.

### Strategic Verdict

Overmind has better recovery than late-game strategy. That is good for a young AI, but it is also a sign that it still spends more effort avoiding collapse than winning complex games.

## 13. Team Games and Coordination

### Overmind

Overmind currently appears mostly single-brain in strategic design. It may coexist in team games, but it does not appear to have a rich team-coordination layer.

### M27

M27 has some team-level handling, but M28 is the stronger reference here.

### M28

`M28Team.lua` is a major strategic advantage. It tracks:

- team data
- active brains
- land subteams
- air subteams
- support requests by zone
- rally zones
- MAA needs
- team economy
- team factories by type and tech
- team-level T1-spam mode
- teammate gifting and transfer behavior

This is a large difference in sophistication.

### Strategic Verdict

If Overmind ever needs to be strong in team environments, it will need a dedicated team layer. This is a major feature gap.

## 14. Robustness and Recovery

### Overmind

This is one of Overmind's best categories.

Strong points:

- `Watchdog.lua` recovery flags
- `FactoryController.lua` queue repair / anti-idle behavior
- engineer floor maintenance
- radar fallback logic
- ACU safety leash

Overmind is more "self-healing" than many early strategic bots. This is valuable and should be preserved.

### M27 and M28

The reference AIs also have recovery, but they more often prevent bad states via richer planning rather than primarily reacting after degradation.

### Strategic Verdict

Overmind should keep this strength. It just needs better planning so recovery becomes the backup, not the main stabilizer.

## Overmind's Current Strengths

These are the parts of Overmind that are already worth building around:

1. **Modular architecture**
   Clean scheduling and explicit modules make it realistic to improve.

2. **Goal layer**
   `GoalSelector.lua` gives a reasonable place to express strategic posture.

3. **Factory throughput discipline**
   `FactoryController.lua` likely eliminates a lot of dead factory time.

4. **Recovery discipline**
   `Watchdog.lua` and related modules keep the AI from imploding too easily.

5. **ACU safety**
   This is already one of Overmind's better strategic behaviors.

6. **Memory scaffolding**
   The risk hotspot and momentum tracking in `Memory.lua` is a strong seed for a better future intel system.

## Overmind's Largest Strategic Weaknesses

These are the highest-impact weaknesses, ordered by strategic importance rather than coding convenience.

## 1. No strong spatial model

This is the root issue.

Because Overmind lacks zone graph depth, it also lacks:

- good front definition
- safe route reasoning
- good support routing
- good multi-front production demands
- good raiding logic
- good terrain-aware expansion planning

## 2. No persistent force model

Units are often treated as available pools rather than assigned formations with durable missions.

Result:

- less stable pressure
- weaker reinforcement patterns
- more order churn
- weaker multi-front coherence

## 3. Production is deficit-driven, not objective-driven

Current production is good at maintaining queues. It is weaker at producing the right packages for the current battlefield geometry.

## 4. Intel is too coarse

Scouting is not sufficiently tied to:

- zone importance
- intel freshness
- force needs
- target-specific support

## 5. Engineer planning is too lightweight

Engineers need zone-level planning, fortification logic, and reclaim-expansion coupling.

## 6. Late-game threat response is too thin

This affects survival and conversion against stronger AIs.

## 7. Team logic is mostly absent

This will cap team-game performance badly.

## 8. Runtime data contract issues exist

The `Economy.lua` contract mismatch is a real bug, not just a missing optimization. Some of Overmind's strategic policy is currently running on incomplete econ data.

## What Overmind Should Borrow From M27

Borrow concepts, not structure.

The best ideas to copy from M27 are:

1. **Temporary strategic override modes**
   Examples:
   - protect ACU
   - kill ACU
   - turtle
   - air dominance
   - land rush

2. **Persistent helpers and escorts**
   Examples:
   - scout helpers
   - MAA helpers
   - escort-aware platoons

3. **Special-case high-threat response**
   Examples:
   - artillery response
   - nuke/SMD response
   - experimental response
   - firebase handling

4. **More explicit operational state**
   Overmind needs more than "goal + current deficits".

What not to copy from M27:

- the monolithic scale
- the degree of cross-file sprawl
- an architecture that becomes difficult to refactor later

## What Overmind Should Borrow From M28

This should be the main architectural reference.

1. **Zone-centered world model**
   Land zones, water zones, plateaus, islands, adjacency, pathing, rally points.

2. **Team and subteam abstractions**
   Land subteams and air subteams are powerful because they give production and support requests a spatial owner.

3. **Zone-driven support demand**
   Zones should be able to say:
   - I need scouts
   - I need MAA
   - I need mobile support
   - I need engineer support

4. **Intel as a first class layer**
   Radar coverage, scout priority, intel freshness, target-specific scouts.

5. **Distributed specialist logic**
   Let land, air, engineer, ACU, and factory systems make rich local decisions using a common shared world model.

## Recommended Improvement Strategy for Overmind

## Guiding Principle

Do not grow Overmind by making every current module 30 percent smarter.

Instead:

1. fix broken runtime contracts
2. improve shared state quality
3. create a stronger spatial model
4. create a stronger force model
5. then upgrade specialized controllers

If you reverse that order, you will create a large body of heuristics on weak foundations.

## Priority 0: Fix Current Data Contract Problems

Immediate tasks:

1. Audit `Economy.lua` against all readers.
2. Populate at least:
   - `MassStorageRatio`
   - `EnergyStorageRatio`
   - `MassIncome`
   - `EnergyIncome`
   - any other fields currently assumed elsewhere
3. Add a runtime validation helper that logs missing expected fields once per game rather than silently defaulting to zero.
4. Audit all `OvermindRuntime` producers and consumers for contract mismatches.

Why this matters:

- it improves current behavior immediately
- it prevents "phantom weakness" where policy appears bad but the inputs are wrong

## Priority 1: Replace `ZoneModel.lua` With a Real Zone Graph

Recommended new module:

- `lua/AI/Overmind/ZoneGraph.lua`

Desired responsibilities:

- partition map into land zones and water zones
- identify plateaus / islands / chokelike transitions
- precompute adjacencies and path lengths
- track per-zone:
  - friendly threat
  - enemy threat
  - structure threat
  - intel freshness
  - rally value
  - expansion value
  - reclaim value
  - firebase danger
  - reinforcement depth
- classify zones as:
  - core
  - rear
  - front
  - contested
  - enemy-side

This should become the data source for:

- goal selection
- scouting
- engineer expansion
- ACU movement
- factory demand
- combat force assignment

## Priority 2: Introduce Persistent Force Roles

Recommended new module:

- `lua/AI/Overmind/ForceManager.lua`

Suggested force roles:

- `mainline`
- `reserve`
- `raider`
- `base_guard`
- `acu_escort`
- `arty_screen`
- `maa_screen`
- `naval_contest`
- `air_superiority`
- `strike_air`

Desired behavior:

- units are attached to forces
- forces are attached to fronts, zones, or missions
- reassignment is allowed but not constant
- reinforcement fills force deficits instead of only global deficits

This is the bridge between "what to build" and "where to use it".

## Priority 3: Replace `T1Director.lua` With a Tech-Agnostic `ForceDirector.lua`

Current issue:

- `T1Director.lua` is doing too much and is conceptually locked to early-game framing

Replacement idea:

- `ForceDirector.lua` computes desired force budgets by role and theater
- factory demand is produced from force deficits, not just global unit deficits

Inputs:

- zone graph
- force manager
- opponent model
- goal selector
- eco policy

Outputs:

- desired land role budgets
- desired air role budgets
- desired navy role budgets
- static support requirements by zone

## Priority 4: Build a Real Intel Layer

Recommended new module:

- `lua/AI/Overmind/IntelModel.lua`

Track:

- intel freshness by zone
- radar coverage by zone
- recent enemy composition by zone
- last seen ACU position and confidence
- likely enemy tech trajectory
- bomber viability / AA overlap estimates

Upgrade `ScoutManager.lua` to:

- allocate scouts by zone priority
- support specific units and forces
- trigger emergency re-scout when assumptions are stale

## Priority 5: Upgrade Engineer Strategy Into a Zone Planner

Recommended new module:

- `lua/AI/Overmind/ExpansionPlanner.lua`

Responsibilities:

- choose expansion packages, not just single mex jobs
- decide when to escort engineers
- decide when to add point defense / AA / radar to expansion clusters
- exploit reclaim near expansions
- reserve build locations before dispatch
- avoid blacklisted routes using memory plus zone graph

Keep from current `EngineerDirector.lua`:

- recall logic
- engineer floor logic
- recovery logic

Extend it with stronger planning and reservation.

## Priority 6: Add Big-Threat Response Management

Recommended new module:

- `lua/AI/Overmind/ResponseManager.lua`

Track explicitly:

- enemy artillery
- nuke launchers
- SMD status
- experimentals
- firebase creep
- teleport risk
- bomber snipe risk
- torpedo threats

This module should be allowed to temporarily override normal goals.

## Priority 7: Add Team Coordination

Recommended new module:

- `lua/AI/Overmind/TeamCoordinator.lua`

Even a minimal version would help:

- shared front ownership
- allied zone support requests
- air-defense support
- role specialization by ally position

If team-game strength matters, this eventually becomes mandatory.

## Priority 8: Use Telemetry and Autotune for the Right Things

Overmind already has:

- `Telemetry.lua`
- `AutoTune.lua`

That is useful, but it should not be used as a substitute for missing structure.

Use autotune for:

- threshold refinement
- hysteresis tuning
- risk weighting

Do not use autotune to solve:

- weak zone modeling
- poor force persistence
- weak intel structure

## Concrete Near-Term Backlog

If the goal is practical progress, this is the order I would use.

## Phase 1: Fast wins

1. Fix `Economy.lua` runtime fields.
2. Add runtime contract validation for `OvermindRuntime`.
3. Expand `ZoneModel.lua` enough to include:
   - zone IDs
   - adjacencies
   - front/rear classification
   - intel freshness
4. Rename `T1Director.lua` to reflect its true role, even before major refactor.
5. Improve `ScoutManager.lua` to use intel freshness and front priority.

Expected impact:

- immediate policy correctness improvement
- better scouting
- less misleading data across the system

## Phase 2: Structural uplift

1. Introduce `ZoneGraph.lua`.
2. Introduce `ForceManager.lua`.
3. Refactor `Combat.lua` to operate on forces instead of mostly idle pools.
4. Refactor `FactoryController.lua` to fill force deficits.
5. Refactor `EngineerDirector.lua` into `EngineerDirector + ExpansionPlanner`.

Expected impact:

- major increase in strategic cohesion
- better multi-front control
- better terrain handling

## Phase 3: Higher-order strategy

1. Add `ResponseManager.lua`.
2. Expand `OpponentModel.lua` to track trends, not just snapshots.
3. Extend `GoalSelector.lua` with temporary override modes inspired by M27.
4. Add air-specific viability evaluation.
5. Add team coordination layer if desired.

Expected impact:

- better adaptation
- stronger late-game survival
- fewer catastrophic strategic blind spots

## Specific Module Recommendations

## Keep and build on

- `Scheduler.lua`
- `GoalSelector.lua`
- `FactoryController.lua`
- `Watchdog.lua`
- `Memory.lua`
- ACU safety parts of `Combat.lua` and `ACURole.lua`

## Generalize or replace

- `ZoneModel.lua`
- `T1Director.lua`
- `ScoutManager.lua`
- `EngineerDirector.lua`
- large parts of the land-control side of `Combat.lua`

## New modules worth adding

- `ZoneGraph.lua`
- `IntelModel.lua`
- `ForceManager.lua`
- `ForceDirector.lua`
- `ExpansionPlanner.lua`
- `ResponseManager.lua`
- `TeamCoordinator.lua`

## Practical Design Advice for Overmind

These are the main design rules I would use while evolving the AI:

1. **A better map model beats more heuristics.**
   Every high-end AI in this comparison gets stronger because it knows where things are and how places connect.

2. **Persistent unit assignment beats repeated idle-unit sweeping.**
   Temporary order spam can work, but it caps out earlier.

3. **Production should serve fronts and roles, not only category deficits.**
   "Need more tanks" is weaker than "front A lacks screen and push mass, front B lacks raiders".

4. **Intel needs freshness and confidence, not just sightings.**
   Overmind should know what it knows, what it only suspects, and what is stale.

5. **Recovery is valuable, but should become second line behavior.**
   The AI should first avoid entering unstable states.

6. **Prefer M28's structure and M27's exceptions.**
   This is the right synthesis.

## Final Assessment

Overmind is currently best described as a promising strategic framework with some strong practical controllers, but not yet a fully mature competitive strategy AI.

Its current strengths are real:

- it is organized
- it has a usable goal layer
- it manages factories and recovery reasonably well
- it does not appear architecturally stuck

Its main weakness is also clear:

- the AI is still operating on too-thin a representation of the battlefield

M27 demonstrates what deep heuristic coverage can achieve.
M28 demonstrates what a cleaner, more scalable version of that depth can look like.

The best path for Overmind is:

1. fix current runtime contract issues
2. upgrade the shared spatial and intel model
3. introduce persistent force roles
4. move production and combat onto those stronger abstractions
5. then add more strategic overrides and specialized responses

If Overmind follows that path, it can keep its current clarity while closing the most important gap with M27 and M28.
