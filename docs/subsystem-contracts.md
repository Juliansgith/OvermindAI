# Overmind Subsystem Contracts

This document is the single ownership reference for scheduler-driven Overmind runtime state.

The scheduler action registry lives in:

- `lua/AI/Overmind/SubsystemContracts.lua`

The runtime slice initialization lives in:

- `lua/AI/Overmind/RuntimeContracts.lua`

## Scheduler Contract Shape

Every scheduler action is normalized to the same contract shape:

- `Name`
- `Label`
- `Group`
- `Method`
- `StateSlice`
- `Inputs`
- `Outputs`

The scheduler now executes normalized actions instead of directly calling mixed module export shapes.

## Owned Runtime Slices

### `runtime.EcoState`

Owner:

- `Economy`

Primary outputs:

- `MassStored`
- `EnergyStored`
- `MassStorageRatio`
- `EnergyStorageRatio`
- `MassTrend`
- `EnergyTrend`
- `MassIncome`
- `EnergyIncome`
- `MassRequested`
- `EnergyRequested`
- `UnitCount`
- `UnitCap`
- `UnitLoad`

### `runtime.EconomyLedger`

Owner:

- `EconomyLedger`

Primary outputs:

- `Factory`
- `Engineer`
- `Upgrade`
- `Reclaim`
- `Aggregate`
- `FactoryBusyRatio`
- `EngineerBusyRatio`
- `SpendSaturation`
- blocked spend reasons

### `runtime.EconomySignals`

Owner:

- `EconomySignals`

Primary outputs:

- canonical structural contest-map metrics
- `PolicySeed`
- `StructuralContestMap`
- `FocusOnT1Spam`
- `ContestMapMode`
- approach-failure suppression flags

### `runtime.EcoVelocity`

Owner:

- `EconomySignals`

Primary outputs:

- `MassIncomeTrendShort`
- `EnergyIncomeTrendShort`
- `MapMassHeldTrend`
- `ReclaimRateShort`
- `FactoryThroughput`
- `EngineerProductivity`
- `SpendSaturation`
- `EcoStagnationTime`
- `ReclaimStagnationTime`

### `runtime.EcoPressure`

Owner:

- `EconomySignals`

Primary outputs:

- `LandPressure`
- `AirPressure`
- `NavalPressure`
- `HomePressure`
- `OuterPressure`
- `ReclaimOpportunity`
- `MapContestPressure`
- `SurvivalCrisis`
- `ACUCrisis`
- `ApproachFailurePressure`

### `runtime.RuntimeContracts`

Owner:

- `RuntimeContracts`

Primary outputs:

- contract initialization bookkeeping
- missing-field diagnostics
- compatibility alias wiring

### `runtime.ReconState`

Owner:

- `ScoutManager`

Primary outputs:

- `LastVisit`
- `LastIntent`
- `PendingScoutTargets`
- `PendingByKey`

### `runtime.ZoneGraph`

Owner:

- `ZoneGraph`

Primary outputs:

- `Nodes`
- `ByKey`
- `PathToScout`
- `PathToFront`
- `GraphSource`
- `ContestedZones`

### `runtime.ZoneModel`

Owner:

- `ZoneModel`

Primary outputs:

- `OwnMainPos`
- `BestExpansionPos`
- `BestRaidPos`
- `MapControl`
- `HomeThreat`
- `ExpansionThreat`

### `runtime.IntelModel`

Owner:

- `IntelModel`

Primary outputs:

- `Zones`
- `FrontLinePos`
- `BestScoutPos`
- `BestRaidPos`
- `BestRaidZoneKey`
- `ContestedZones`
- `StaleZones`

### `runtime.OpponentModel`

Owner:

- `OpponentModel`

Primary outputs:

- `RelativePower`
- `RelativeMilitary`
- `Posture`
- `Land`
- `Air`
- `Navy`
- `OwnLand`
- `OwnAir`
- `OwnNavy`

### `runtime.ForceDirector`

Owner:

- `ForceDirector`

Primary outputs:

- `Assignments`
- `Groups`
- `TaskGroups`
- `Stats`
- `RoleDemand`
- `Tasks`
- `TaskList`
- `UnitTaskById`
- `NextTaskId`

Task execution metadata is also written onto persistent task objects, including:

- `ExecutionState`
- `LastIssuedAt`
- `LastCommand`
- `LastIssuedTarget`
- `LastStagePos`
- `LastIssuedCount`

### `runtime.ProductionDirector`

Owner:

- `ProductionDirector`

Primary outputs:

- `Mode`
- `TimeHorizon`
- `Current`
- `DomainBudget`
- `RolePlan`
- `CapacityPlan`
- `TechPlan`
- `StructurePlan`
- `EmergencyOverrides`
- `Confidence`
- `ConstraintState`
- `DemandLedger`
- `OpponentTrend`
- `NavalActive`
- `ScoutingDebt`

### `runtime.Recovery`

Owner:

- `Watchdog`
- `FactoryController`
- `EconomyOptimizer`

Primary outputs:

- recovery posture and anti-collapse controls

### `runtime.ACUState`

Owner:

- `ACURole`
- `Combat.EnforceCommanderSafety`

Primary outputs:

- ACU posture and leash state

### `runtime.EngineerState`

Owner:

- `EngineerDirector`

Primary outputs:

- engineer assignment and expansion control state

### `runtime.RaidDefense`

Owner:

- `RaidDefense`

Primary outputs:

- raid threat flags
- last raid labels and positions
- bomber / land harass counts

### `runtime.RadarState`

Owner:

- `RadarFallback`

Primary outputs:

- radar build retry state

### `runtime.BomberHarass`

Owner:

- `BomberHarass`

Primary outputs:

- bomber mission / harass state

### `runtime.MexDefense`

Owner:

- `MexDefense`

Primary outputs:

- mex defense retry / placement state

### `runtime.FactoryState`

Owner:

- `FactoryHeartbeat`

Primary outputs:

- per-factory activity heartbeat state

### `runtime.FactoryControlState`

Owner:

- `FactoryController`

Primary outputs:

- queue-control and factory arbitration state

### `runtime.Telemetry`

Owner:

- `Telemetry`

Primary outputs:

- `Samples`
- `Window`
- `Checkpoints`
- `LastTelemetry`

## Compatibility Aliases

These remain intentionally available where older callers still need a stable entry point:

- `runtime.ForceManager -> runtime.ForceDirector`

Legacy compatibility modules also exist:

- `lua/AI/Overmind/ForceManager.lua`
- `lua/AI/Overmind/T1Director.lua`

`T1Director.lua` is now only a file-level compatibility shim. Runtime state no longer aliases `runtime.T1Director`, and new policy must read `runtime.ProductionDirector` directly.
