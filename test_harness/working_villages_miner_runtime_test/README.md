# Miner runtime acceptance harness

This headless Luanti test loads the production `working_villages:job_miner`
entity in an isolated world. The miner starts with empty cargo. A real shared
chest contains exactly three cobbles and two sticks, and VoxeLibre receives one
real crafting-table node because its pickaxe recipe requires a 3x3 workstation.

The arena contains one reachable active-game iron-ore node and no other
mineable node in the profession's full scan volume. The test requires the
production miner to:

1. withdraw the five counted ingredients from shared storage;
2. craft and equip exactly one registered stone pickaxe;
3. pass the engine `minetest.get_dig_params` capability gate;
4. remove the one real iron-ore node in one attempt;
5. physically travel back to the real shared chest;
6. deposit exactly the one registered raw-ore drop;
7. preserve the complete ingredient, tool, source-node and ore-drop balance.

Use `miner_runtime_world.mt` and `miner_runtime_test.conf` from the parent
`test_harness` directory in a disposable world whose `worldmods` links point to
the source mod and this harness. Set `LUANTI_USER_PATH` to an isolated user
directory and launch with `--server`. VoxeLibre uses `--gameid mineclone2`;
Minetest Game uses `--gameid minetest`.

Success ends the server after these terminal markers:

- `MINER_PICK_CRAFTED_OK:<profile>`
- `MINER_GET_DIG_PARAMS_OK:<profile>`
- `MINER_ORE_EXTRACTED_OK:<profile>`
- `MINER_PHYSICAL_DEPOSIT_OK:<profile>`
- `MINER_CONSERVATION_OK:<profile>`
- `WORKING_VILLAGES_MINER_RUNTIME_OK:<profile>`

Any escaped assertion emits `WORKING_VILLAGES_MINER_RUNTIME_FAILED:<profile>`
and also requests a clean server shutdown.

