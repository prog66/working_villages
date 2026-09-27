# Complete-village runtime acceptance harness

This is a two-run, headless acceptance test. It creates terrain resources but
never provisions a villager inventory. Run phase 1 until the server requests a
clean shutdown, then restart the same disposable world for phase 2.

The strengthened P0 evidence is deliberately event-based:

- `VILLAGE_RUNTIME_HARVEST_REPLANT_DEPOSIT_OK` requires a real mature-crop dig,
  records its position and actual inventory gains, then observes an immature
  crop at the same position and the harvested product leaving that farmer's
  inventory for a real shared chest.
- `VILLAGE_RUNTIME_PHYSICAL_DELIVERY_OK` accepts only a production
  `resource_delivery` task whose target is the requesting villager. The task
  must finish as `completed`, its result and supplier summary must equal the
  request, requester/supplier deltas must be exact, and the village-wide item
  total must be conserved. An observation starts only when the supplier already
  owns the whole cargo, so crafting during arrival cannot masquerade as a
  conserved transfer.
- `VILLAGE_RUNTIME_RESTART_IDENTITIES_OK`,
  `VILLAGE_RUNTIME_RESTART_INVENTORIES_OK`,
  `VILLAGE_RUNTIME_RESTART_JOB_STATES_OK`, and
  `VILLAGE_RUNTIME_RESTART_LEDGER_OK` compare the five identity tuples, every
  inventory slot by identity, stable long-running profession fields, and the
  exact construction marker index/ledger. Coroutine objects are intentionally
  excluded because they cannot persist across a process restart.
- `VILLAGE_RUNTIME_FATIGUE_REST_OK` proves low-energy recovery first.
  `VILLAGE_RUNTIME_NIGHT_SLEEP_OK` then requires the distinct `dort` state at
  the assigned bed during the engine's night window. Only after an artificial
  dawn and a non-sleep profession action does
  `VILLAGE_RUNTIME_DAWN_JOB_RESUME_OK` pass.
- `VILLAGE_RUNTIME_COOK_FURNACE_SEQUENCE_OK` and
  `VILLAGE_RUNTIME_FORGE_FURNACE_SEQUENCE_OK` require observable source, fuel
  (stack or active burn metadata), destination, withdrawal, and shared-chest
  deposit. At least one polled source-consumption/destination-production edge
  must have the exact registered cooking ratio before
  `VILLAGE_RUNTIME_FURNACE_ANTI_DUPLICATION_OK` can pass.

The furnace proof is intentionally strict. If the game performs both sides of
a slot transition entirely between two 0.5-second polls, the harness times out
instead of inferring or simulating that transition. Crop timers are accelerated
only to exercise the native node callbacks; this does not validate normal game
pacing or replace the requested 30-to-60-minute graphical playtests.
