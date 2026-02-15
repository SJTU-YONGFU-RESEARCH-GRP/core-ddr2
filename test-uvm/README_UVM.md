## DDR2 Controller UVM Testbench (Verilator + UVM-2017)

This directory contains a UVM-based SystemVerilog testbench for the `ddr2_controller`
block, aligned with the project `REQUIREMENTS_MATRIX.md` and `VERIFICATION_PLAN.md`.

- **Top-level**: `tb_ddr2_controller_uvm.sv`
  - Instantiates `ddr2_controller` from `dut/`.
  - Instantiates `ddr2_host_if` bundling the host FIFO interface.
  - (Placeholder) DDR2 memory model instance to be wired to the PHY pads.
  - Calls `run_test("ddr2_smoke_test")`.

- **UVM package**: `ddr2_tb_pkg.sv`
  - `ddr2_txn`: host-level transaction (CMD/SZ/ADDR, write seed) with requirement tags, transaction ID, and constraints for valid traffic and block alignment.
  - Helper `num_words_for_sz(sz)` and delay constants (`DELAY_*_NS`) for consistent timing.
  - `ddr2_base_seq`, `ddr2_init_only_seq`, `ddr2_scalar_rw_seq`, `ddr2_block_rw_all_sizes_seq`, `ddr2_addr_edges_seq`, `ddr2_random_stress_seq`.
  - `ddr2_driver`: drives the host FIFO interface (reset, INITDDR, scalar/block writes using shared helpers).
  - `ddr2_monitor`: observes command enqueues and functional coverage.
  - `ddr2_scoreboard`: reference memory model; for block writes stores all burst words (pattern_for_addr) for correct read checking.
  - `ddr2_env`: connects driver, monitor, and scoreboard.
  - Tests: `ddr2_smoke_test`, T1–T4, T10.

- **Interface**: `ddr2_host_if.sv`
  - Bundles host signals and provides `drv` / `mon` modports for UVM components.

To use the IEEE UVM-2017 reference implementation under `tools/uvm-2017` with Verilator,
compile `uvm_pkg.sv` and point the include path to `uvm_macros.svh`, then compile
`tb_ddr2_controller_uvm.sv` and all RTL/DUT files. A basic Verilator invocation
could look like:

```bash
verilator -Wall --cc --exe --build \
  -sv -Itools/uvm-2017/1800.2-2017-1.0/src \
  tools/uvm-2017/1800.2-2017-1.0/src/uvm_pkg.sv \
  dut/ddr2_controller.v dut/ddr2_init_engine.v dut/ddr2_protocol_engine.v \
  dut/ddr2_ring_buffer8.v dut/ddr2_phy.v dut/fifo.v \
  test-uvm/tb_ddr2_controller_uvm.sv
```

## Implemented Tests

The following tests from `VERIFICATION_PLAN.md` are now implemented:

- **T1 - `ddr2_init_powerup_basic_test`**: Verifies power-up initialization sequence
- **T2 - `ddr2_scalar_rw_basic_test`**: Basic scalar read/write operations
- **T3 - `ddr2_block_rw_all_sizes_test`**: Block read/write for all SZ values (8/16/24/32 words)
- **T4 - `ddr2_address_mapping_edges_test`**: Address mapping edge cases (row/bank boundaries)
- **T10 - `ddr2_random_full_system_stress_test`**: Constrained-random stress test

## Running Tests

Use the `+UVM_TESTNAME=<test_name>` plusarg to select a test without recompiling:

```bash
./obj_dir/Vtb_ddr2_controller_uvm +UVM_TESTNAME=ddr2_smoke_test
./obj_dir/Vtb_ddr2_controller_uvm +UVM_TESTNAME=ddr2_init_powerup_basic_test   # T1
./obj_dir/Vtb_ddr2_controller_uvm +UVM_TESTNAME=ddr2_scalar_rw_basic_test      # T2
./obj_dir/Vtb_ddr2_controller_uvm +UVM_TESTNAME=ddr2_block_rw_all_sizes_test   # T3
./obj_dir/Vtb_ddr2_controller_uvm +UVM_TESTNAME=ddr2_address_mapping_edges_test  # T4
./obj_dir/Vtb_ddr2_controller_uvm +UVM_TESTNAME=ddr2_random_full_system_stress_test # T10
```

If `+UVM_TESTNAME` is not provided, the default test is `ddr2_smoke_test`. The C++ harness returns exit code 1 on simulation timeout and 0 on normal completion.

## Enhanced Features

- **Memory Model Integration**: `ddr2_simple_mem` is now wired into the UVM testbench
- **Protocol Checkers**: All protocol/timing checkers from `test/` are instantiated:
  - `ddr2_fifo_monitor`: FIFO flow-control checking
  - `ddr2_refresh_monitor`: Refresh interval monitoring
  - `ddr2_timing_checker`: JEDEC timing constraints (tRCD, tRP, tRAS, tRFC)
  - `ddr2_turnaround_checker`: Write-to-read and read-to-write timing
  - `ddr2_bank_checker`: Bank/row conflict detection
  - `ddr2_dqs_monitor`: DQS activity monitoring
- **Enhanced Scoreboard**: Now checks read data (`DOUT`/`RADDR`) against reference model
- **Block Write Support**: Driver properly handles multi-beat block write data
- **Functional Coverage**: Covergroups track command types, sizes, and address ranges

## Recent UVM Improvements

- **Transaction and constraints**: `ddr2_txn` has a unique `id`, `c_valid_traffic` (no NOP in random traffic), and `c_block_alignment` for block commands. Helper `num_words()` on transaction.
- **Shared helpers**: `num_words_for_sz(sz)` and delay constants (`DELAY_SCALAR_WR_NS`, etc.) used in driver, scoreboard, and sequences to avoid magic numbers and duplication.
- **Scoreboard block writes**: Reference model now stores every word of a block write (using `pattern_for_addr(addr+i)`), so block read checking matches the driver’s data pattern.
- **Test selection**: `+UVM_TESTNAME=<name>` selects the test at runtime; default is `ddr2_smoke_test`. Script supports `UVM_TESTNAME=... ./run_tb.sh`.
- **Exit code**: C++ harness returns 1 on simulation timeout, 0 on normal finish.

## Remaining Work

Additional tests from the verification plan can be added:
- T5-T6: Refresh interaction tests
- T7-T8: FIFO flow-control stress tests
- T9: DQS ring buffer alignment tests
- T11: Protocol timing minimum spacing tests
- T12: Host misuse/negative tests

