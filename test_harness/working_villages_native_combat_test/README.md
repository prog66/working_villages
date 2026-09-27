# Native combat runtime acceptance

This headless harness is intentionally VoxeLibre-specific. It runs a real
`working_villages` guard against consecutive registered `mobs_mc` monsters for
at least 60 seconds. The test passes only when native targets have damaged the
guard, the guard has killed several waves, survived, kept the same identity and
profession, remained active, and produced no long combat stall. Job coroutines
are deliberately not compared: a normal completed job tick is recreated by the
production scheduler.

The harness provisions ordinary survival equipment so this test isolates the
combat loop. Autonomous blacksmith production and delivery are validated by
the complete-village harness instead.

Terminal evidence is:

`WORKING_VILLAGES_NATIVE_COMBAT_OK:voxelibre:...`

