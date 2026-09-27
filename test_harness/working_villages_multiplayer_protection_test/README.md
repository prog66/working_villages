# Multiplayer protection runtime test

This harness waits for two real connected Luanti clients named
`wv_owner_alpha` and `wv_owner_beta`. It creates separate village registry
records and claims, then verifies with their real `PlayerRef` objects that:

- each owner can manage only their own villager;
- each owner may dig inside their own village claim;
- the other owner is refused by the real `minetest.node_dig` protection path;
- both claims and registry records remain distinct.

Success is reported only by the terminal
`WORKING_VILLAGES_MULTIPLAYER_PROTECTION_OK` marker.
