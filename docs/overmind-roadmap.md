# Overmind Roadmap

## Purpose

This roadmap defines the path from the current Overmind state to a stronger, cleaner, and more competitive AI.

The target is not just "more features." The target is:

- a cleaner architecture than M27 and M28
- a stronger battlefield model than current Overmind
- a more adaptive strategic system than M28
- a codebase that can keep improving without collapsing under its own heuristic weight

This roadmap is written as phased workstreams rather than release names.

## Strategic Goal

Overmind should aim to beat M28 by being stronger in four areas at the same time:

- better map-state understanding
- better uncertainty handling
- better force and task organization
- better cross-domain planning across land, air, navy, economy, ACU, and scouting

It should not try to win by simply copying M28's coverage file-by-file. M28 is already extremely broad. The advantage Overmind can build is a cleaner base architecture with higher-quality shared models.

## Guiding Principles

- Prefer structural improvements over piling on isolated heuristics.
- Give each subsystem owned state and explicit outputs.
- Avoid ad hoc writes to shared runtime fields whenever possible.
- Build task and force persistence before adding large amounts of new tactical logic.
- Make scouting and opponent modeling confidence-aware, not just threat-aware.
- Treat production as a response to strategic demand, not just local deficits.
- Add telemetry and benchmark support early enough that tuning is evidence-based.

## Current Position

Overmind already has several strong ingredients:

- centralized orchestration through the scheduler
- explicit runtime bootstrapping and feature flags
- a zone graph and graph-backed intel flow
- an intermediate force role layer
- economy policy, recovery logic, and anti-collapse safeguards
- good ACU safety and practical control modules

The main gaps are still:

- soft state boundaries instead of hard subsystem interfaces
- force bucketing rather than persistent task groups
- production logic that is still transitional and tech-scoped
- limited explicit uncertainty/confidence reasoning
- no unified strategic planner across combat, economy, scouting, and tech transition
- limited competitive validation and benchmarking discipline

## Workstreams

The roadmap is easier to execute if it is treated as parallel workstreams with a clear dependency order.

### Workstream A: Architecture and State Ownership

Goal:
Turn Overmind from a modular prototype with shared mutable state into a system with stable subsystem contracts.

Deliverables:

- standardize module interface shape across all subsystems
- define subsystem-owned runtime slices
- define explicit published outputs for each subsystem
- remove scheduler shims needed only because module exports are inconsistent
- reduce top-level runtime field sprawl
- document contracts in one place

Target shape:

- `Bootstrap`
  - feature flags
  - startup defaults
  - optional compatibility switches
- `Scheduler`
  - cadence only
  - ordered dependency execution only
  - no subsystem-specific policy
- subsystem modules
  - own their state
  - read declared inputs
  - publish declared outputs

Owned state examples:

- `runtime.EcoState`
- `runtime.ZoneGraph`
- `runtime.IntelModel`
- `runtime.OpponentModel`
- `runtime.ForceDirector`
- `runtime.ProductionDirector`
- `runtime.ACUState`
- `runtime.EngineerState`
- `runtime.AirState`
- `runtime.NavyState`

Published output examples:

- `IntelModel.FrontLinePos`
- `IntelModel.StaleZones`
- `ForceDirector.Tasks`
- `ProductionDirector.DesiredMix`
- `OpponentModel.ConfirmedEnemyAir`
- `OpponentModel.ProbableEnemyTechState`

Exit criteria:

- every scheduler-managed module exports the same interface
- shared runtime writes are reduced to declared state slices
- contract initialization is centralized
- a new contributor can tell who owns each field without reading the entire codebase

### Workstream B: World Model and Uncertainty

Goal:
Turn the zone graph and intel layer into a true operational world model.

Deliverables:

- keep confirmed-visit freshness as the baseline rule
- add confidence values separate from freshness
- distinguish observed, inferred, and stale enemy presence
- track scouting debt by zone
- track last confirmed enemy composition by zone
- track likely enemy transit between zones
- improve front, rear, contested, enemy-side classification over time

Desired model additions:

- `LastObserved`
- `LastConfirmedEnemyLand`
- `LastConfirmedEnemyAir`
- `LastConfirmedStructures`
- `Confidence`
- `ScoutingDebt`
- `TransitRisk`
- `OwnershipTrend`

Important behavior:

- a zone can be fresh but still low-confidence if only weak intel touched it
- a zone can be stale but high-risk because enemy transit into it is likely
- strategic decisions should discount weak-confidence conclusions

Exit criteria:

- intel consumers can distinguish fresh from confident
- scouting priorities are driven by uncertainty and consequence
- the AI stops treating absence of recent vision as equivalent to absence of threat

### Workstream C: Force and Task System

Goal:
Replace role buckets with persistent force and mission ownership.

Why this matters:

Current `ForceManager` is a useful intermediate step, but it still rebuilds functional groups from pools. A stronger architecture needs real tasks with continuity.

Deliverables:

- replace or evolve `ForceManager` into a force director
- define persistent task objects
- assign units or platoons to tasks
- maintain task anchors, targets, objectives, and expiry rules
- support reassignment based on changing strategic priority

Core task types:

- base guard
- front hold
- front push
- raid
- ACU escort
- artillery support
- anti-air screen
- scout screen
- bomber strike escort
- expansion escort
- navy lane control

Task fields:

- `TaskId`
- `Role`
- `Priority`
- `AnchorPos`
- `TargetPos`
- `AssignedUnits`
- `DesiredStrength`
- `CurrentStrength`
- `Timeout`
- `CreatedAt`
- `LastActiveAt`
- `Status`

Behavioral goals:

- land groups should persist across short tactical changes
- escort groups should follow ACU or expansion tasks without full regroup churn
- raid groups should remember their mission until success, failure, or invalidation
- front tasks should absorb reinforcements rather than forcing complete rebucketing

Exit criteria:

- combat movement is task-driven rather than idle-pool-driven
- production can request units for tasks rather than categories in isolation
- the AI spends less time re-forming and more time executing

### Workstream D: Production and Tech Planning

Goal:
Replace transitional production logic with a unified production director.

Why this matters:

The current T1-focused director is useful now, but it will become a bottleneck if left in place while higher-tech and multi-domain logic grow around it.

Deliverables:

- create a tech-agnostic production director
- fold current T1 logic into broader demand reasoning
- define production in terms of roles, counters, and strategic tasks
- separate factory management from production policy

Production inputs:

- economy policy
- force task demand
- opponent composition
- intel confidence
- map control
- current tech state
- factory capacity by domain

Production outputs:

- desired role mix
- desired domain mix
- tech pressure
- expansion pressure
- emergency overrides
- factory queue priorities

Important policies:

- produce to reinforce tasks, not just to fill numerical deficits
- use confidence-aware counterproduction
- factor travel time and theater value into production weighting
- allow temporary emergency posture without permanently distorting macro policy

Exit criteria:

- no strategic dependency on a T1-only production brain
- role demand flows cleanly into factory decisions
- tech transitions are planned instead of incidental

### Workstream E: Combat Decomposition

Goal:
Split combat control into clearer operational layers.

Recommended layers:

- strategic target selection
- task assignment and route choice
- tactical movement and engagement control
- ACU-specific behavior
- special weapon and bomber strike logic

Desired result:

- `Combat` becomes thinner and more focused
- tactical code stops carrying strategic selection logic that belongs elsewhere
- front push, hold, raid, regroup, and retreat become task behaviors rather than global branching modes

Specific improvements:

- route selection should prefer graph paths by task and threat budget
- attack staging should be tied to task readiness
- regroup logic should be local to a task, not a global fallback
- split pushes should be intentional and task-derived
- bombardment/artillery logic should support front tasks explicitly

Exit criteria:

- combat code is no longer the main dumping ground for cross-system decisions
- task state explains why units are moving where they are moving

### Workstream F: ACU, Escort, and Survival Logic

Goal:
Keep the current strong ACU safety base, but integrate it into the task system and strategic planner.

Deliverables:

- ACU roles should become task-backed
- escort allocation should be task-owned
- ACU aggression should depend on confidence, support, and local reinforcement depth
- add clearer distinction between anchor, push, overcharge pressure, emergency retreat, and reclaim-support roles

Important improvements:

- tie ACU aggression to explicit confidence, not just visible local advantage
- let escort demand feed production and task reinforcement
- distinguish temporary panic locks from strategic ACU posture

Exit criteria:

- ACU behavior is less isolated from the rest of the army plan
- escort decisions are persistent and explainable

### Workstream G: Engineer, Expansion, and Reclaim Economy

Goal:
Make map economy behavior more strategic and less reactive.

Deliverables:

- expansion tasks driven by zone ownership, escort demand, and confidence
- reclaim routing tied to safety bands and opportunity value
- build clearer distinction between safe expansion, contested expansion, and denial expansion
- improve enemy mex denial logic
- improve second-base logic so it is graph-aware, not just threshold-gated

Important principles:

- engineers should move as part of strategic tasks where possible
- reclaim and expansion should compete for engineer time explicitly
- front instability should automatically harden expansion standards

Exit criteria:

- expansion is paced by actual theater conditions
- engineers are less likely to oscillate between disconnected priorities

### Workstream H: Air and Bomber System

Goal:
Make air planning more persistent, counter-aware, and theater-aware.

Deliverables:

- split air into interception, strike, scout, escort, and air control tasks
- distinguish local air defense from map-wide air posture
- improve fighter concentration logic
- improve bomber target selection using confidence and survival probability
- support synchronized strikes with scouting and escort coverage

Competitive goals:

- stronger response to bomber openings
- better fighter massing at decisive fronts
- less wasteful bomber attrition into stale or over-defended targets

Exit criteria:

- air control is no longer a side effect of generic production and threat checks
- bomber logic behaves like a mission system, not a periodic harassment pulse

### Workstream I: Navy and Water Maps

Goal:
Treat navy as a first-class domain instead of an optional extension.

Deliverables:

- build water-specific tasks and production demand
- add naval lane control, escort, denial, and shore-pressure tasks
- separate amphibious pressure from pure land pressure
- improve sonar, naval intel, and coastal defense reasoning

Important requirement:

The zone graph already has water nodes. The next step is to let that data actually drive navy behavior instead of only informing map summaries.

Exit criteria:

- water maps no longer rely on land-centric reasoning with naval exceptions
- production and tasking can choose serious naval investment when justified

### Workstream J: Opponent Modeling

Goal:
Move from mostly current-state enemy estimation to a richer enemy model.

Deliverables:

- track confirmed and inferred enemy composition separately
- track enemy tech trajectory
- track enemy posture by domain
- estimate likelihood of bomber play, land flood, ACU walk, tech rush, navy pivot, or eco greed
- keep short history so decisions are based on trends, not just snapshots

Useful outputs:

- `RelativePowerByDomain`
- `EnemyPosture`
- `EnemyTechPressure`
- `EnemyAirRisk`
- `EnemyRaidLikelihood`
- `EnemyExpansionPattern`

Exit criteria:

- production and strategic goals can respond to enemy tendencies, not just unit counts

### Workstream K: Strategic Planning Layer

Goal:
Add a genuine cross-domain strategic planner above the local specialist modules.

Why this matters:

This is the biggest long-term differentiator versus M28. M28 is very strong, but much of its behavior is still a large heuristic web. Overmind can win long-term by having a cleaner planner that arbitrates tradeoffs across domains.

Planner responsibilities:

- choose broad strategic posture
- allocate pressure between land, air, navy, eco, and scouting
- decide when to accept local loss for global gain
- decide when to stabilize versus punish
- coordinate temporary strategic overrides

Planner inputs:

- confidence-aware intel
- force task status
- production capacity
- economy health
- opponent trends
- map control

Planner outputs:

- strategic posture
- domain allocation weights
- override modes with expiry
- risk tolerance
- scouting priority shifts

Do not do this too early.

This layer should come after the world model, force system, and production director are stable. Otherwise it will become another heuristic shell sitting on weak foundations.

Exit criteria:

- strategic decisions explain cross-domain tradeoffs
- temporary overrides are structured, not ad hoc

### Workstream L: Telemetry, Benchmarking, and Tuning

Goal:
Make performance improvement measurable and repeatable.

Deliverables:

- expand telemetry capture for tasks, planner outputs, and confidence metrics
- record failure signatures such as idle factories, scout starvation, task churn, and overreaction
- create benchmark scenarios by map class and enemy archetype
- compare outcomes against prior baselines and against M28
- add replay review tags or log markers for key strategic transitions

Benchmark categories:

- small aggressive land maps
- medium mixed maps
- large air-sensitive maps
- reclaim-heavy maps
- water maps
- teamgame maps

Metrics:

- time to first map-control gain
- expansion survival rate
- scout coverage quality
- task churn
- factory idle time
- ACU overextension incidents
- bomber efficiency
- land attrition efficiency
- comeback rate after early pressure

Exit criteria:

- tuning decisions are based on repeatable evidence
- regressions are visible quickly

## Execution Order

The roadmap should not be attacked in random order.

Recommended sequence:

1. finish small correctness fixes and runtime hygiene
2. standardize architecture and state ownership
3. replace force bucketing with persistent tasking
4. replace transitional production logic with a unified production director
5. split combat into clearer operational layers
6. improve air, engineer, and navy systems on top of the task model
7. deepen opponent modeling and uncertainty reasoning
8. add the strategic planner above the stabilized lower layers
9. harden telemetry, benchmark discipline, and tuning loops continuously throughout

## Immediate Priorities

These are the highest-value next actions from the current state:

- [x] fix any remaining runtime correctness issues in the new scout-confirmation path
- [x] standardize module export style across all scheduler-driven subsystems
- [x] document subsystem-owned runtime slices
- [x] redesign `ForceManager` into a persistent task-oriented force director
  Current state: `ForceDirector` now owns persistent tasks, preserves task membership across updates, and `Combat` now issues orders against those tasks directly. Further refinement now belongs to Workstream C rather than the immediate-priority list.
- [x] begin extracting production policy out of `T1Director` into a broader production director

## Near-Term Stabilization Plan

This section is the current execution plan for the next practical improvement window. It is narrower than the full roadmap and is meant to address the live replay failures that still dominate performance.

Observed failure pattern:

- factory target overshoots too fast once early eco comes online
- unfinished factory shells are not staffed hard enough once opened
- ACU safety still over-triggers and burns time in recall loops
- mainline commitment remains too soft once home/front pressure arrives
- extractor staging now exists, but must remain validated before more tech-policy changes are piled on top

Recommended rollout:

1. `v97`: stabilize factory growth and factory completion
2. `v98`: unblock local `T1 -> T2` mex consolidation and fix reclaim crash
3. `v99`: keep second-land tempo alive and loosen local `T1 -> T2` further
4. `v100`: restore `v96` factory tempo baseline while keeping reclaim and mex-tech fixes
5. `v101`: reduce ACU safety churn with stronger hysteresis
6. `v102`: tighten force commitment and mainline allocation under pressure

### v97: Factory Ramp And Completion

Status:

- implemented in `v97-factory-ramp-completion`

Goals:

- stop `2 -> 5/6 land` bursts that the economy cannot finish
- make unfinished factories complete before new shells are opened

Changes:

- split factory target from factory open permission
- allow quick `1 -> 2 -> 3` land scaling
- require stronger conditions for `3 -> 4+`
- block new factory shells while unfinished factory staffing is inadequate
- treat mid/high-fraction unfinished factories as critical build-power sinks
- keep unfinished factory targets sticky once builders are on them or progress is meaningful
- recall idle/far engineers back to factory completion before opening more shells

Success criteria:

- by `6-8` minutes, the AI has `2-3` ready land factories instead of `1`, but is not sitting at `5/6` total with only `2` ready
- unfinished factory tasks show assigned builders instead of repeated `asn=0/2`

### v98: Local Tech2 Consolidation

Status:

- implemented in `v98-local-tech2-consolidation`

Goals:

- stop deadlocking on `T1` mexes when expansion is exhausted or unsafe
- keep `T2 -> T3` hard-gated while allowing safe core `T1 -> T2`
- remove the late reclaim runtime error seen in the record `v96` run

Changes:

- fix `EngineerDirector` reclaim issuance so it does not pass a raw Lua table into `IssueReclaim`
- add a local/core mex consolidation override inspired by M28's safe-zone upgrade behavior
- allow one local `T1 -> T2` upgrade under scouting debt when:
  - local/core mex candidates exist
  - the local zone is secure
  - the base has radar, power, and at least two ready land factories
  - remote expansion or remote upgrade options are poor, or scouting debt is blocking the general tech plan
- keep `T2 -> T3` on the stricter durable-surplus gate

Success criteria:

- no late reclaim runtime error in `EngineerDirector`
- local/core `T1 -> T2` mex upgrades occur even when `ExtractorUpgradeReason=scouting_debt`
- no premature `T2 -> T3` upgrades under pressure or weak economy

### v99: Factory Tempo And Local Tech2 Floor

Status:

- implemented in `v99-factory-tempo-local-tech2`

Goals:

- stop regressing back to one effective land factory after the second shell starts
- make `T1 -> T2` local mex upgrades viable with one ready land factory when expansion is stalled

Changes:

- reduce `starterPhase` stickiness once a second land shell exists and early eco floors are met
- keep land target at least `2` while a second land shell exists or is being built
- raise builder commitment to unfinished land factories at low and mid fractions
- allow local/core `T1 -> T2` consolidation with one ready land factory instead of waiting for two

Success criteria:

- by `5-8` minutes, the AI does not keep falling back to `1/0/0` after starting the second land factory
- unfinished second land factories keep assigned builders and finish faster
- local/core `T1 -> T2` mex upgrades can occur before the AI reaches a large multi-factory state

### v100: Restore v96 Tempo Baseline

Status:

- implemented in `v100-v96-tempo-baseline`

Goals:

- recover the sustained factory throughput that made `v96` the best run so far
- remove the `v97-v99` factory-ramp and factory-recovery changes that regressed tempo
- keep only the good fixes from `v98`

Changes:

- revert `ProductionDirector` factory-ramp policy to the `v96` baseline
- revert `EngineerDirector` factory-task recovery logic to the `v96` baseline
- keep the `EngineerDirector` reclaim crash fix from `v98`
- keep extractor staging and safe local `T1 -> T2` consolidation from `v98`

Success criteria:

- the AI holds onto factory throughput more like `v96`
- it stops collapsing from a recovered `3`-factory state back into `1` effective factory as often
- `T2 -> T3` remains blocked under stress while local/core `T1 -> T2` still works

### v103: Aggressive Second-Land And Surplus Power

Status:

- implemented in `v103-aggressive-secondland-power`

Goals:

- remove the remaining helper-runtime contamination from the local extractor consolidation path
- unlock the second land factory earlier once the first stable eco floor is online
- stop treating early power as a hard floor and keep scaling it when spare mass exists

Changes:

- forward-declare and bind the remaining zone-control helper used by local `T1 -> T2` consolidation
- lower the mex and engineer thresholds for second-land readiness
- allow the starter-phase target to hold `2` land once second-land conditions are met
- add surplus-driven power scaling so spare mass continues converting into pgens while energy storage/trend are still modest

Success criteria:

- no early helper runtime errors from the local mex-consolidation path
- by `3-6` minutes the AI escapes `1/0/0` more reliably
- when mass is floating and energy buffer is still modest, power continues to grow past the initial floor

### v104: Factory Completion And Engineer Conversion

Status:

- implemented in `v104`

Goals:

- keep `v103` aggression but convert it into finished production instead of stalled shells
- use spare engineers on factory completion, mex upgrades, repairs, and core eco work
- allow local `T1 -> T2` mex upgrades to act as default consolidation when expansion is stalled
- unlock the first `T2` factory earlier once a stable `4`-factory midgame exists

Changes:

- hard-gate new land factory shells behind staffed existing shells
- treat stalled unfinished land factories as top-priority engineer work and allow multiple engineers to assist them
- make free engineers prefer, in order:
  - unfinished factory shells
  - active mex upgrades
  - damaged core structure repairs
  - critical core structures
  - safe local `T1 -> T2` mex upgrades
  - only then expansion / secondary defense / reclaim
- relax local/core `T1 -> T2` mex upgrades further under expansion stall while keeping `T2 -> T3` strict
- unlock the first `T2` factory earlier when:
  - `3-4` factories are online
  - eco is stable
  - no critical recovery is active
  - pressure justifies stronger units
- add explicit repair priority for damaged factories, mexes, radar, and core defenses
- implementation notes:
  - free engineers now directly assist unfinished factory shells, active upgrades, and damaged core assets before low-value reclaim
  - production growth now distinguishes staffed unfinished shells from abandoned ones
  - first land HQ upgrade is now allowed once a stable `4`-factory midgame exists
  - local `T1 -> T2` consolidation thresholds were relaxed further while `T2 -> T3` stayed strict

Implementation order:

1. factory completion lock and staffed-shell growth accounting
2. engineer spend priority and multi-engineer assists
3. local `T1 -> T2` consolidation / assist behavior
4. earlier `T2` factory tech unlock
5. repair priority

Success criteria:

- no long-lived unfinished factory with `asn=0/2` or `asn=0/3`
- multiple engineers can be seen assisting the same factory shell or mex upgrade when appropriate
- at least one safe local `T1 -> T2` mex occurs when expansion is stalled
- one factory starts upgrading to `T2` once a stable `4`-factory midgame exists
- engineers repair damaged core assets instead of drifting into low-value work
- no return to one-factory limp mode after the early transition

### v105: ACU Safety Hysteresis And Tech Conversion

Status:

- implemented in `v105`

Goals:

- stop repeated recall spam when the ACU is already near home and escorted
- allow one safe local `T1 -> T2` mex in tempo mode when map growth is stalled
- unlock the first land HQ upgrade earlier once stable factory tempo exists

Changes:

- add per-reason cooldowns to recall triggers
- require stronger worsening threat before repeating the same recall
- separate `hold position` from `hard recall`
- reduce sensitivity when the ACU is inside defended space with escorts nearby
- treat `tempo_mode` as a valid local consolidation window for one safe `T1 -> T2` mex
- relax first land HQ upgrade thresholds so stable `4-6` factory midgames can start teching

Success criteria:

- substantially fewer `panic_leash_recall`, `opening_recall`, `raid_cover_recall`, and `enemy_contact_recall` loops in the `4-10` minute window
- ACU remains responsive to real danger, but stops wasting time on repeated soft retreats
- at least one safe local `T1 -> T2` mex can start during tempo mode
- one land factory can begin upgrading before the game is already decided

### v106: ACU Leash Reset

Status:

- implemented in `v106`

Goals:

- stop treating escorted near-home ACU posture as panic overextension
- reserve `panic_leash_recall` for genuinely severe leash failures
- keep `v105` factory tempo intact while reducing commander self-churn

Changes:

- widened ACU role distance bands for `anchor`, `assist`, and `push`
- relaxed strict leash clamping when the ACU is heavily escorted
- increased catastrophic-overextend thresholds for stable escorted forward posture
- suppress moderate escorted leash drift from escalating into repeated recalls
- lengthened `panic_leash_recall` cooldown so the same leash failure does not retrigger immediately

Success criteria:

- materially fewer `panic_leash_recall` events during the `6-14` minute window
- escorted ACU can hold a forward defended perimeter without constant retreat loops
- commander still hard-recalls on true low-health or catastrophic overextend cases

### v107: ACU Early Anchor Work

Status:

- implemented in `v107`

Goals:

- keep the safer `v106` leash behavior
- stop the ACU from idling in early anchor mode when the base is safe
- let the commander keep contributing to core bootstrap work in the first `2-4` minutes

Changes:

- extend starter-task execution beyond the strict starter lock into early safe anchor windows
- allow the ACU to repair or build core power, radar, and nearby mex during early anchor posture
- only do this when healthy, near home, not under harass, and before the army has fully transitioned

Success criteria:

- fewer idle-anchor periods in the first `2-4` minutes
- ACU contributes to nearby core bootstrap work instead of standing still
- no regression into early leash-spam while doing opener work

### v108: ACU Pressure Cleanup And Structure Telemetry

Status:

- implemented in `v108`

Goals:

- stop repeated ACU recall spam while the commander is already retreating successfully
- make structure-task oddities directly visible in replay logs
- keep AA/PD/Defense tasks owned longer once started

Changes:

- suppress repeat `raid_cover_recall`, `stuck_recall`, and `panic_leash_recall` when the ACU is already moving home under healthy escort
- increase sticky duration for AA/Defense/Structure tasks
- expand `ENGDIR` logging with structure task mode, nearby engineer count, and task position

Success criteria:

- fewer duplicate recall lines while the ACU is already retreating
- `ENGDIR` clearly shows build vs repair vs upgrade vs resume for structure tasks
- easier diagnosis of engineer clumps around unexpected tasks in live tests

### v110: Upgrade Director Baseline

Status:

- implemented in `v110`

Goals:

- stop spreading mex and HQ upgrade ownership across production policy, builder conditions, and generic engineer assist logic
- choose one safe upgrade target at a time and keep assists focused on it
- give Overmind a more stable base for future tech/tempo tuning

Changes:

- added `UpgradeDirector.lua` as a centralized upgrade arbiter
- choose one safe mex upgrade target and directly issue the mex upgrade from the director
- choose one safe land HQ upgrade target and make `FactoryController` honor that chosen target
- route mex builder conditions through the directed target instead of broad “upgrade allowed” heuristics
- route engineer upgrade assists through the directed mex/HQ target first

Success criteria:

- `UPGDIR` logs show one owned mex/HQ target instead of diffuse upgrade permission
- engineers assist the active directed mex/HQ upgrade instead of generic nearest upgrades
- fewer cases where tech is “allowed” but no stable upgrade target is actually owned

### v116: Surplus Spend Windows

Status:

- implemented in `v116`

Goals:

- stop treating a stable economy as a finished economy
- force spare mass/energy into one more owned spend path instead of floating
- make local mex tech, first HQ tech, and factory growth respond to sustained surplus

Changes:

- added explicit `SurplusSpendWindow` and `StrongSurplusWindow` in `ProductionDirector`
- surplus windows now lower factory-growth brakes once the base core is online
- surplus windows can keep mex upgrades enabled even when tempo mode would normally suppress them
- `UpgradeDirector` now scores safe local `T1 -> T2` and first land HQ upgrades higher during sustained surplus
- factory upgrade fallback also respects the surplus window instead of waiting for a perfect tech read

Success criteria:

- by `8-12` minutes, spare eco should convert into more local mex upgrades, a first land HQ, or more factory count
- fewer cases where mass and energy float while `mex=0` and `tech=0`

### v118: Dynamic Factory And Upgrade Scaling

Status:

- implemented in `v118`

Goals:

- remove the fixed factory ceiling
- make spare eco expand consistently instead of flattening out at a static target
- prefer core/local mex upgrades first and push the first land HQ earlier once the T1 base is established

Changes:

- replaced the fixed `6/4/3` factory target ceiling with surplus-scaled soft caps in `ProductionDirector`
- mex upgrade concurrency now scales with actual surplus instead of staying effectively pinned at `1`
- local/core mexes score above local edge mexes
- first land HQ tech is now preferred earlier once roughly five land factories are online

Success criteria:

- no hard stop at six land factories when eco can clearly support more
- more than one mex upgrade can run when surplus is real
- first HQ starts earlier in stable midgame instead of waiting for a perfect tech state

### v102: Mainline Commitment

Goals:

- stop over-parking land in guard/holding states while the front is live

Changes:

- raise minimum `main` share under confirmed home/front pressure
- lower guard cap when cluster confidence is high
- pull parked or holding land into a single response group more aggressively

Success criteria:

- `FORCE` shows a meaningful `main` group under pressure instead of mostly `guard`
- base-edge attacks pull a coherent local response instead of scattered unit trickle

### v119: Power Buffer Recovery

Goals:

- turn `power_buffer_low` into active eco recovery instead of only a tech denial reason

Changes:

- idle engineers now prefer unfinished or damaged core power structures before reclaim
- if no nearby power task exists, engineer director opens one T1 pgen build near main
- added `powerRec` to `ENGDIR` telemetry to show when spare engineers are being redirected into power recovery

Success criteria:

- when HQ tech is blocked on `power_buffer_low`, spare engineers visibly shift into pgen build/assist
- reclaim no longer wins over core power recovery in those windows
- replay logs show `powerRec>0` during those periods

### v120: Capacity Plan Scope Fix

Goals:

- restore clean `ProductionDirector` execution so factory and surplus policy are testable again

Changes:

- fixed missing local `eco` binding inside `DecideCapacityPlan`

Success criteria:

- no repeated `ProductionDirector` runtime error about missing `eco`
- `FACTCTRL` targets reflect real production policy again instead of broken fallback values

### Extractor Validation Constraint

Before further tech-policy work:

- keep validating that `T1 -> T2` upgrades happen before `T2 -> T3`
- keep validating that remote upgrades do not outrun local/core upgrades
- keep validating that `T2 -> T3` stays blocked during mass/energy stress or factory recovery

This avoids mixing tech regressions with the current factory/ACU/force stabilization work.

## Recent Progress

Recent architecture-first work completed or materially advanced the following:

- moved scheduler execution onto normalized subsystem action contracts in `SubsystemContracts.lua`
- created first-class `ProductionDirector` and `ForceDirector` modules with compatibility shims for `T1Director` and `ForceManager`
- centralized runtime slice initialization and alias ownership in `RuntimeContracts.lua`
- documented owned runtime slices and published outputs in `docs/subsystem-contracts.md`
- finished the immediate force refactor by preserving task membership and making combat consume persistent task objects directly

## What To Avoid

- do not start by writing a huge global planner on top of soft contracts
- do not add many more tactical exceptions before task persistence exists
- do not let `Combat` become the permanent home for strategic logic
- do not keep growing top-level shared runtime fields without ownership rules
- do not treat telemetry as an afterthought

## Definition of Success

Overmind is on the right path when the following become true:

- map-state decisions are driven by confidence-aware graph intelligence
- units act through persistent tasks rather than repeated pool reshuffles
- production decisions reinforce strategic intent across all tech stages
- strategic posture changes are explainable and temporary overrides are structured
- code ownership is clear enough that new systems can be added without destabilizing old ones
- benchmark progress against strong opponents is measurable, not anecdotal

## End State

The end-state Overmind should look like this:

- cleaner than M27
- more structurally coherent than M28
- less brittle than threshold-heavy heuristic systems
- better at uncertainty and theater adaptation than current competitive AIs
- able to keep scaling in strength without turning into a monolithic override maze

That is the real objective of this roadmap.
