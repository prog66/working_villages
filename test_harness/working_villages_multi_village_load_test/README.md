# Multi-village load acceptance

This harness keeps four independent villages and twenty real villager entities
active for 60 seconds in a playerless server. It verifies stable identities,
owner isolation and village-registry isolation while collecting real server
step durations.

The public-server budget is intentionally explicit: the 95th percentile must
remain at or below 0.20 seconds and the worst observed step at or below 1.0
second after setup. A result is only accepted with all twenty entities still
loaded and assigned to their original owner and profession.

Terminal evidence is:

`WORKING_VILLAGES_MULTI_VILLAGE_LOAD_OK:...`

