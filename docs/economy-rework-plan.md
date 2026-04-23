# Economy Rework Plan

## Purpose

This plan defines the next economy architecture target for Overmind.

The goal is not to make the AI greedier by adding more thresholds. The goal is to make economy decisions evidence-based, coordinated, and durable across factory production, engineer tasks, mex upgrades, reclaim, map control, and strategic posture.

The current economy architecture has a good foundation:

- `FactoryController` is the primary live factory queue owner.
- `ProductionDirector` publishes role, capacity, and tech policy.
- `UpgradeDirector` owns mex upgrade execution.
- `EngineerDirector` is moving toward modular task ownership.
- `StrategicPlanner` and `MacroController` already understand outer retention, contest tempo, and production-first pressure.
- `EconomyOptimizer` publishes structural economy policy.

The remaining problem is that several systems still reason from partial views of the economy. Production knows factory demand, engineers know build tasks, upgrades know mex concurrency, and strategy knows map pressure, but there is no single economy velocity and spend picture that all of them consume.

## Design Principle

Overmind should not choose between "eco" and "production" as a binary mode.

The target rule is:

- production should remain active unless branch supremacy or hard economic failure says otherwise
- engineers should remain productive unless no safe useful task exists
- economy should keep improving in the background unless a short, explicit crisis blocks it
- reclaim should be treated as economy growth, not optional cleanup
- pressure should reduce eco concurrency, not erase eco intent
- failed approaches should be detected and changed, not repeated indefinitely

In practical terms:

- stable economy means "safe to grow"
- pressure means "reduce concurrency and localize risk"
- crisis means "temporarily preserve survival"
- repeated failure means "pivot"

## Current Diagnosis

### What Is Working

- Factory queue ownership is much cleaner than earlier versions.
- Mex upgrades are plan-driven instead of builder-priority-driven.
- Production policy understands strength gaps instead of raw unit counts.
- Structural contest-map signals exist.
- Outer retention and reclaim-first concepts exist.
- Recovery and heartbeat systems provide practical anti-deadlock support.

### What Is Still Weak

- Economy signals are duplicated between modules.
- `MacroController`, `StrategicPlanner`, and `EconomyOptimizer` can disagree about contest tempo or T1 spam pressure.
- `StrategicPlanner` can read stale economy policy depending on scheduler order.
- Engineer spending is not visible enough to the economy brain.
- Factory spend is not summarized into a shared ledger.
- Mex upgrade demand and blocked reasons are not part of a unified spend view.
- Reclaim-field behavior is still too conditional and can become late.
- "Stable" can still be interpreted too passively.
- There is limited detection that a chosen approach has failed over time.

## Target Architecture

The target is a shared economy signal pipeline.

```text
FactoryController
EngineerDirector
UpgradeDirector
Economy
Zone / Intel / Strategy inputs
        |
        v
EconomyLedger
        |
        v
EconomyOptimizer
        |
        v
EcoPolicy + EcoVelocity + EcoPressure
        |
        v
StrategicPlanner
MacroController
ProductionDirector
UpgradeDirector
EngineerDirector
FactoryController
```

The important change is that economy policy should be based on actual spend and task activity, not just storage ratios, income snapshots, or isolated pressure flags.

## New Runtime Slices

### `runtime.EconomyLedger`

Owner:

- new shared economy ledger module, or `EconomyOptimizer` if kept simple

Purpose:

- collect current economic activity from all major spenders
- expose what the AI is trying to spend on
- expose what is blocked
- expose where idle buildpower or idle factories exist

Suggested fields:

- `UpdatedAt`
- `FactorySpend`
- `EngineerSpend`
- `UpgradeSpend`
- `ReclaimSpend`
- `TotalRequestedMass`
- `TotalRequestedEnergy`
- `TotalActiveMassSpend`
- `TotalActiveEnergySpend`
- `BlockedMassSpend`
- `BlockedEnergySpend`
- `IdleFactoryCount`
- `IdleEngineerCount`
- `FactoryBusyRatio`
- `EngineerBusyRatio`
- `FactoryStarvedRatio`
- `EngineerStarvedRatio`
- `UpgradeBlockedReason`
- `ReclaimBlockedReason`

### `runtime.EcoVelocity`

Owner:

- `EconomyOptimizer`

Purpose:

- convert raw economy and ledger data into trend-aware economic momentum

Suggested fields:

- `MassIncomeNow`
- `MassIncomeTrendShort`
- `MassIncomeTrendMedium`
- `EnergyIncomeNow`
- `EnergyIncomeTrendShort`
- `EnergyIncomeTrendMedium`
- `ReclaimRateShort`
- `ReclaimRateMedium`
- `MapMassHeld`
- `MapMassHeldTrend`
- `MexCountTrend`
- `MexUpgradeThroughput`
- `FactoryThroughput`
- `EngineerProductivity`
- `SpendSaturation`
- `EcoGrowthRate`
- `EcoStagnationTime`
- `ProductionStagnationTime`
- `ReclaimStagnationTime`

### `runtime.EcoPressure`

Owner:

- `EconomyOptimizer`

Purpose:

- provide normalized pressure values instead of binary mode flags

Suggested fields:

- `LandPressure`
- `AirPressure`
- `NavalPressure`
- `HomePressure`
- `OuterPressure`
- `ReclaimOpportunity`
- `MapContestPressure`
- `ProductionPressure`
- `UpgradePressure`
- `EnergyPressure`
- `MassPressure`
- `SurvivalCrisis`
- `ACUCrisis`
- `ApproachFailurePressure`

### `runtime.EcoPolicy`

Owner:

- `EconomyOptimizer`

Purpose:

- publish final economy policy decisions for consumers

Suggested fields:

- `AlwaysEco`
- `ProductionFirst`
- `ReclaimFirst`
- `OuterRetentionActive`
- `FocusOnT1Spam`
- `AllowMexUpgrades`
- `MexUpgradeConcurrency`
- `MexUpgradeLocalOnly`
- `AllowPgens`
- `AllowStorage`
- `AllowFactoryGrowth`
- `AllowFactoryAssist`
- `EngineerExpansionQuota`
- `EngineerReclaimQuota`
- `EngineerBaseQuota`
- `FactoryGrowthBias`
- `BranchInvestmentBias`
- `PolicyReason`

## Publisher Contracts

### Factory Controller Publisher

`FactoryController` should publish:

- number of owned factories by domain
- number of active factories by domain
- number of idle factories by domain
- number of factories starved by economy
- current queue lengths
- average queue age
- branch spend estimate
- role demand being served
- blocked reason for each domain

Key question answered:

- "Is production actually consuming the economy, or only requesting it?"

### Engineer Director Publisher

`EngineerDirector` should publish:

- engineer count by task type
- idle engineer count
- constructing engineer count
- reclaiming engineer count
- assisting engineer count
- expanding engineer count
- base-maintenance engineer count
- estimated buildpower by task type
- task demand not filled
- reclaim task blocked reason
- expansion task blocked reason

Key question answered:

- "Are engineers turning available economy into growth, map control, or reclaim?"

### Upgrade Director Publisher

`UpgradeDirector` should publish:

- active mex upgrades
- pending mex upgrade desire
- blocked mex upgrades
- blocked reason
- upgrade concurrency cap used
- local-only status
- upgrade mass spend estimate
- upgrade energy spend estimate
- upgrade completion trend

Key question answered:

- "Is mex teching intentionally throttled, or accidentally stalled?"

### Economy Publisher

`Economy` should publish:

- current income
- current storage
- short trend
- medium trend
- unit cap pressure
- income-to-spend ratio
- stall duration
- overflow duration

Key question answered:

- "Can the current plan be funded?"

### Strategy And Map Publishers

`StrategicPlanner`, `ZoneModel`, `IntelModel`, and related map systems should publish:

- map mass held
- contestable mass
- safe forward mass
- reclaim field candidates
- route risk to reclaim and expansion
- home threat
- outer threat
- branch-specific pressure by label or zone
- whether the current strategic approach is working

Key question answered:

- "Where should economic growth happen, and how risky is it?"

## Consumer Contracts

### Strategic Planner Consumer

`StrategicPlanner` should consume:

- `EcoVelocity`
- `EcoPressure`
- `EcoPolicy`
- map and opponent state

It should decide:

- whether to keep contesting outer map
- whether to force production-first
- whether to pivot from failed T1 spam
- whether to force a tech/economy recovery
- whether to pursue economic reduction against enemy mexes instead of direct confrontation

### Macro Controller Consumer

`MacroController` should consume the same structural economy signals as `StrategicPlanner`.

It should not recompute a separate contest-map policy.

It should decide:

- macro phase
- global production pressure
- consolidation posture
- whether the AI is in short-term crisis or long-term stagnation

### Production Director Consumer

`ProductionDirector` should consume:

- `EcoPolicy`
- `EcoPressure`
- `EcoVelocity`
- force role demand
- branch supremacy

It should decide:

- factory growth
- domain budget
- role budget
- air/land/naval investment
- whether branch production can be reduced because supremacy exists
- whether air should be vetoed under severe land or ACU crisis

### Upgrade Director Consumer

`UpgradeDirector` should consume:

- `EcoPolicy.AllowMexUpgrades`
- `EcoPolicy.MexUpgradeConcurrency`
- `EcoPolicy.MexUpgradeLocalOnly`
- `EcoPressure.SurvivalCrisis`
- `EcoVelocity.EcoGrowthRate`

It should decide:

- which mexes to upgrade
- how many upgrades can run
- whether upgrades must stay local
- whether upgrades are blocked by survival or by resource failure

### Engineer Director Consumer

`EngineerDirector` should consume:

- `EcoPolicy.EngineerExpansionQuota`
- `EcoPolicy.EngineerReclaimQuota`
- `EcoPolicy.EngineerBaseQuota`
- `EcoPolicy.ReclaimFirst`
- `EcoPolicy.OuterRetentionActive`
- `EcoPressure.ReclaimOpportunity`
- route risk and support state

It should decide:

- how many engineers are reserved for reclaim
- how many are allowed to expand
- how many must stay home
- when a reclaim engineer should be escorted
- when a task can be cancelled or reassigned

### Factory Controller Consumer

`FactoryController` should consume:

- `ProductionDirector.RolePlan`
- `ProductionDirector.CapacityPlan`
- `EcoPolicy.AllowFactoryGrowth`
- `EcoVelocity.SpendSaturation`

It should decide:

- which unit to build next
- whether to keep queue depth high
- whether to top off emergency units
- whether to reduce branch output due to branch supremacy or severe eco stall

## Workstream 1: Single Economy Signal Owner

Goal:

- remove duplicated economy and contest-map conclusions

Tasks:

- Move structural contest-map detection into one shared module or make `EconomyOptimizer` the single source of truth.
- Remove duplicate `ComputeContestMapStructure` logic from `MacroController`.
- Ensure `StrategicPlanner`, `MacroController`, and `ProductionDirector` consume the same fields.
- Split economy signal generation from economy policy if scheduler ordering requires it.
- Run economy signal generation before strategy and macro decisions.
- Run final policy generation after strategy if it needs strategy outputs.

Target scheduler shape:

```text
EconomyState
EconomySignals
StrategicPlanner
MacroController
ProductionDirector
UpgradeDirector
EngineerDirector
FactoryController
EconomyTelemetry
```

Exit criteria:

- one field owns `FocusOnT1Spam`
- one field owns `ContestMapMode`
- one field owns `ReclaimFirst`
- one field owns `OuterRetentionActive`
- logs no longer show macro and strategy disagreeing on the same economy posture

## Workstream 2: Economy Ledger

Goal:

- make all major economic consumption visible

Tasks:

- Add `EconomyLedger` initialization to runtime contracts.
- Add lightweight publisher functions.
- Publish factory activity from `FactoryController`.
- Publish engineer activity from `EngineerDirector`.
- Publish upgrade activity from `UpgradeDirector`.
- Publish reclaim activity separately from generic engineer activity.
- Publish blocked reasons for spenders.
- Add telemetry for ledger fields.

Suggested API:

```lua
Ledger.PublishFactoryActivity(aiBrain, runtime, data)
Ledger.PublishEngineerActivity(aiBrain, runtime, data)
Ledger.PublishUpgradeActivity(aiBrain, runtime, data)
Ledger.PublishReclaimActivity(aiBrain, runtime, data)
Ledger.GetSnapshot(runtime)
```

Exit criteria:

- telemetry can show factory busy ratio
- telemetry can show engineer busy ratio
- telemetry can show active mex upgrade count
- telemetry can show reclaim engineer count
- telemetry can show why eco growth is blocked

## Workstream 3: Economy Velocity

Goal:

- make economy decisions trend-aware instead of snapshot-only

Tasks:

- Track rolling short and medium windows for mass income.
- Track rolling short and medium windows for energy income.
- Track reclaim rate.
- Track map mass held trend.
- Track mex upgrade completion trend.
- Track factory utilization trend.
- Track engineer productivity trend.
- Track stagnation timers.

Suggested interpretation:

- `EcoGrowthRate` should rise when income, reclaim, or map mass held improves.
- `EcoStagnationTime` should rise when eco is stable but not improving.
- `SpendSaturation` should rise when factories, engineers, and upgrades are all productively consuming economy.
- `IdleCapacity` should rise when engineers or factories are idle despite adequate resources.

Exit criteria:

- stable economy without growth is visible as stagnation
- reclaim drought is visible as a separate issue
- production idleness is visible as a separate issue
- upgrade starvation is distinguishable from intentional upgrade throttling

## Workstream 4: Always-On Eco Policy

Goal:

- replace binary eco decisions with concurrency caps

Policy shape:

- normal state: production active, reclaim active, upgrades active at moderate concurrency
- pressure state: production active, reclaim active if safe, upgrades local and capped
- crisis state: production active, reclaim only if safe and supported, upgrades paused except emergency economy recovery
- supremacy state: production can taper in the dominant branch, eco can expand more aggressively
- stagnation state: force some economy or reclaim action even if pressure exists

Tasks:

- Replace simple `AllowMexUpgrades` checks with `MexUpgradeConcurrency`.
- Add `MexUpgradeLocalOnly` as a throttle, not a total shutdown.
- Add `EngineerReclaimQuota` with a minimum under reclaim-first conditions.
- Add `EngineerExpansionQuota` based on map mass opportunity and route risk.
- Add `EngineerBaseQuota` for pgens, factory support, and recovery.
- Add `EcoGrowthPressure` for forcing eco action when the AI is stable but not growing.

Exit criteria:

- "stable" causes at least one growth lane to stay active
- T1 spam does not hard-freeze all economy growth indefinitely
- pressure reduces upgrade count instead of erasing upgrade intent
- replay telemetry shows continuing growth attempts during midgame pressure

## Workstream 5: Reclaim As First-Class Economy

Goal:

- make reclaim conversion a planned economy lane

Tasks:

- Reserve one reclaim engineer when `ReclaimFirst` or high reclaim opportunity is active.
- Do this before generic assist/build branches.
- Keep stricter safety gates for additional reclaim engineers.
- Use route risk and military support to decide whether the reclaim task needs escort.
- Publish reclaim blocked reasons.
- Track reclaim field success and failure.
- Cancel reclaim tasks that repeatedly fail to path or survive.

Policy rules:

- one reclaim engineer should be allowed under moderate pressure if route risk is acceptable
- two or more reclaim engineers require stronger safety or escort
- reclaim should not wait for all factory and structure tasks to be stable
- reclaim should pause only for true survival crisis, unreachable fields, or high route risk without escort

Exit criteria:

- contested midgame logs show nonzero reclaim-field assignment
- total reclaim share improves in replay review
- engineers do not idle at home while safe reclaim fields exist
- reclaim tasks have clear failure reasons when they do not execute

## Workstream 6: Approach Failure Detection

Goal:

- make the AI recognize when its current economic or military approach is not working

Tracked approaches:

- T1 spam
- outer retention
- reclaim-first
- tech consolidation
- navy commitment
- air answer
- turtle recovery

Signals:

- map mass held trend
- enemy mex kills
- reclaim collected
- unit loss ratio
- branch strength trend
- ACU safety trend
- factory throughput
- mex upgrade throughput
- time spent in current approach

Example rules:

- if T1 spam runs for several minutes and map mass held falls, reduce spam confidence
- if outer retention repeatedly loses assigned groups, reduce outer aggression or require escort
- if reclaim-first is active but reclaim rate stays low, increase engineer reservation or change target field
- if air answer is active but land crisis worsens, veto air until land stabilizes
- if navy commitment loses water and economy stalls, pivot to torp bomber, hover, or land containment plan

Exit criteria:

- policies have `ApproachAge`
- policies have `ApproachConfidence`
- repeated failure produces a policy pivot
- replay logs show why a pivot happened

## Workstream 7: Branch And Label Economy

Goal:

- make economy pressure spatially aware on land, navy, and island maps

Tasks:

- Treat connected land or water areas as labels.
- Track owned mexes by label.
- Track enemy pressure by label.
- Track production access by label.
- Track reclaim fields by label.
- Track route safety between base and label.
- Drive factory and engineer investment from label pressure and opportunity.

Useful fields:

- `LabelId`
- `LabelType`
- `OwnedMexCount`
- `EnemyMexCount`
- `ContestableMexCount`
- `ReclaimMass`
- `OwnProductionStrength`
- `EnemyThreat`
- `RouteRisk`
- `TransportRequired`
- `NavalLockRisk`
- `AirAccessRisk`

Behavior goals:

- land pressure on a remote island should not distort main-base land production if it cannot reach that island
- naval loss should not be measured only as global threat disadvantage
- island expansion should be treated as a separate economy investment with transport and escort cost
- air can be used as an economic bridge only when it has enough protection or payoff

Exit criteria:

- naval/island maps do not use pure global land threat to set production
- economy policy can explain which label is being invested in
- engineer expansion and reclaim tasks know which label they belong to

## Workstream 8: Production And Eco Balance

Goal:

- keep all factories productive while still growing economy

Tasks:

- Use factory busy ratio to detect underproduction.
- Use branch supremacy to taper dominant branch output.
- Use spend saturation to decide if more factories are useful.
- Avoid comparing enemy factory count directly.
- Compare branch strength, branch threat, and production throughput instead.
- Ensure factory growth does not consume all engineer bandwidth during reclaim-first mode.

Policy rules:

- if factories are idle and resources are available, production tuning is wrong
- if engineers are idle and resources are available, engineer task tuning is wrong
- if all spenders are active and resources are stable, economy can add more growth concurrency
- if one branch has supremacy, reduce that branch before reducing all production
- if a branch is losing and production is active, add capacity only if spend saturation can support it

Exit criteria:

- factories rarely stay idle for long outside true resource failure
- engineer idleness is visible and actionable
- extra factories are based on throughput and strength need, not enemy factory count
- branch tapering happens from supremacy, not arbitrary eco greed

## Workstream 9: Naval And Island Economy

Goal:

- make naval maps less brittle

Tasks:

- Add naval label pressure to economy policy.
- Track water-control loss separately from land pressure.
- Detect naval lock risk.
- Detect when navy spend has failed to regain water.
- Reserve economy for navy only while navy is still viable.
- Pivot to torp bombers, hover, transports, or land containment when navy is no longer viable.
- Use island expansion cost that includes transport and escort.

Policy rules:

- early navy should have high priority when water controls mex access
- navy should not consume unlimited economy if water is already unrecoverable
- enemy navy near economy should trigger local defensive investment, not global panic
- island mexes require transport logistics before they count as practical growth

Exit criteria:

- naval maps show explicit water-control state
- economy policy knows when naval investment is viable
- island expansion does not strand engineers
- losing water produces a pivot instead of endless underpowered navy production

## Workstream 10: Telemetry And Replay Validation

Goal:

- make tuning evidence-based

Add telemetry lines for:

- economy velocity
- factory busy ratio
- engineer busy ratio
- reclaim engineer count
- active reclaim target
- active mex upgrade count
- mex upgrade cap
- spend saturation
- eco stagnation timer
- production stagnation timer
- approach confidence
- approach pivot reason
- branch supremacy
- label economy focus

Replay checkpoints:

- 0 to 5 minutes: no long engineer idle after first factory
- 5 to 10 minutes: factory production stays active while at least one eco lane opens
- 8 to 15 minutes: reclaim fields produce visible reclaim rate if safe fields exist
- 10 to 18 minutes: T1 spam either gains map value or begins pivoting
- 12 to 22 minutes: mex upgrade throughput exists unless true crisis blocks it
- 15+ minutes: navy, air, and land investment reflect label-specific pressure

Success metrics:

- reduced engineer idle time
- reduced factory idle time
- increased reclaim share
- increased map mass held
- earlier mex upgrade completion without production collapse
- fewer minutes spent in failed T1 spam
- fewer air switches during land or ACU crisis
- clearer policy reasons in logs

## Implementation Order

### Phase 1: Fix Signal Coherence

Do first because every later policy depends on shared truth.

Tasks:

- create or designate a single structural economy signal owner
- remove duplicate contest-map decisions
- fix scheduler order so strategy reads current signals
- publish one canonical `FocusOnT1Spam`
- publish one canonical `ContestMapMode`

Validation:

- macro, strategy, production, and upgrade logs agree on spam/contest posture

### Phase 2: Make Modular Engineers Reliable

Do early because engineer behavior is the economy execution layer.

Tasks:

- fix modular runtime errors
- log fallback errors
- reduce silent fallback usage
- ensure engineer assignment modules use shared helpers consistently
- add basic engineer activity publishing

Validation:

- modular mode stays active in replay
- no immediate runtime fallback
- no long idle after first factory

### Phase 3: Add Economy Ledger

Do before major tuning.

Tasks:

- add runtime ledger slice
- publish factory activity
- publish engineer activity
- publish upgrade activity
- publish reclaim activity
- add ledger telemetry

Validation:

- logs can explain what is consuming economy
- logs can explain what is blocked

### Phase 4: Add Economy Velocity

Do before changing upgrade and production rules.

Tasks:

- compute rolling trends
- detect stagnation
- detect spend saturation
- detect reclaim drought
- detect idle productive capacity

Validation:

- logs distinguish stable growth from stable stagnation

### Phase 5: Convert Eco Policy To Concurrency

Do after velocity exists.

Tasks:

- replace binary mex upgrade gates with caps
- add local-only upgrade throttles
- reserve reclaim engineer quota
- add background growth lane
- add crisis-only hard stops

Validation:

- eco growth continues under moderate pressure
- crisis still protects survival

### Phase 6: Add Approach Failure

Do after stable telemetry exists.

Tasks:

- track approach age
- track approach payoff
- lower confidence after repeated failure
- pivot from failed spam, failed navy, failed air, or failed reclaim

Validation:

- replays show policy pivots with reason codes

### Phase 7: Add Label-Aware Economy

Do after the basic economy loop is measurable.

Tasks:

- track land and water labels
- attach mex, reclaim, pressure, and production access to labels
- make naval/island economy decisions label-aware
- add transport and escort cost for island economy

Validation:

- naval and island maps stop using pure global threat as the main production/economy driver

## Acceptance Criteria

The economy rework is successful when:

- factory idle time is rare and explainable
- engineer idle time is rare and explainable
- reclaim fields are actively converted when safe enough
- mex upgrades continue at capped concurrency under moderate pressure
- T1 spam does not permanently freeze economy growth
- strategy, macro, production, and upgrade policy agree on the same economy posture
- the AI can explain whether it is production-limited, engineer-limited, resource-limited, map-limited, or crisis-limited
- failed approaches produce pivots
- naval and island maps use label-specific economy reasoning

## Anti-Goals

Do not:

- reintroduce builder-priority economy ownership
- make economy a fixed percentage allocation system before all spenders report demand
- hard-stop eco for broad "pressure" states
- compare enemy factory counts as the main factory-growth metric
- let reclaim remain an opportunistic late branch
- let scheduler order cause stale policy reads
- allow multiple modules to independently define the same economy posture
- hide modular engineer failures behind silent fallback

## Final Target State

Overmind should treat economy as a continuous control loop:

- read income, storage, spend, idle capacity, map value, pressure, and trends
- decide how much growth can safely run
- keep production and engineers productive
- keep reclaim conversion active
- throttle upgrades and expansion by risk rather than disabling them wholesale
- detect when a chosen approach is failing
- pivot before the economy gap becomes unrecoverable

The strongest version of this design is not greedy. It is opportunistic, pressure-aware, and hard to stall.
