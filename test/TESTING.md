# DDR2 Controller Testing

This document describes the verification and simulation flow for the DDR2 controller DUT. The testbench and monitors live in the `test/` directory and are run with Icarus Verilog via `run_tb.sh`.

---

## 1. Overview

- **Simulator**: Icarus Verilog (`iverilog`, `vvp`).
- **Top-level testbenches**:
  - **`tb_ddr2_controller.v`**: Exercises the core controller (`ddr2_controller`).
  - **`tb_ddr2_server_controller.v`**: Exercises the server controller (`ddr2_server_controller`) with the same scenarios plus ECC, scrubbing, and RAS tests.
- **Memory model**: `ddr2_simple_mem.v` — behavioral DDR2-like model (ACT/WRITE/READ, 8-word bursts) for closed-loop validation.
- **Build/run**: `./test/run_tb.sh`; results go to `test/result.txt` and per-config logs under `test/logs/`.

---

## 2. Build Modes and Defines

### 2.1 Run script: `run_tb.sh`

- **Default defines**: `-DSIM_SHORT_INIT`, `-DSTRICT_JEDEC`; optional `-DNEGATIVE_TESTS`, `-DCSV_TRACE`.
- **TOP**: `core` (ddr2_controller) or `server` (ddr2_server_controller). Default: sweep both.
- **FULL_BUS**:
  - **0 (fast)**: `-DSIM_DIRECT_READ`; host read data comes from internal tracker, bypassing full DDR2 return path. Quick functional checks.
  - **1 (full)**: No `SIM_DIRECT_READ`; all reads/writes go over the bus and `ddr2_simple_mem`; pin-level monitors enforce protocol and timing.
- **Memory model overrides** (build-time): `MEM_DEPTH_OVERRIDE`, `READ_LAT_OVERRIDE`, `RANK_BITS_OVERRIDE`. Default sweep: MEM_DEPTH 1024/4096, READ_LAT 24 (and 32 in fast), RANK_BITS 0/1/2.

**Examples:**

```bash
./test/run_tb.sh
TOP=core FULL_BUS=1 ./test/run_tb.sh
TOP=server FULL_BUS=0 ./test/run_tb.sh
NEGATIVE_TESTS=1 ./test/run_tb.sh
CSV_TRACE=1 ./test/run_tb.sh
```

### 2.2 Timing config: `ddr2_timing_config.vh`

- Centralizes JEDEC-like timing (in controller clock cycles) for monitors.
- **Bank timing**: tRCD, tRP, tRAS, tRFC (used by `ddr2_timing_checker`).
- **Turnaround**: tWTR, tRTW, tWR, tRTP (used by `ddr2_turnaround_checker`).
- **Refresh**: tREFI min/max. With `STRICT_JEDEC`: tight window (~3900 cycles); without: relaxed (e.g. max 100k) for short-init sims.

---

## 3. Testbench Structure (Core: `tb_ddr2_controller.v`)

### 3.1 Clock and DUT

- **CLK**: 500 MHz (period 2 ns).
- **DUT**: `ddr2_controller` with optional `SIM_DIRECT_READ` ports (`sim_mem_rd_valid`, `sim_mem_rd_data`) when fast mode.
- **Memory model**: `ddr2_simple_mem` on DDR2 pads; debug outputs `MEM_WR_VALID/ADDR/DATA`, `MEM_RD_VALID/ADDR/DATA` for closed-loop checks.

### 3.2 Scoreboard and Patterns

- **`pattern_for_addr(addr)`**: Deterministic pattern `{addr[7:0], addr[15:8]} ^ 16'hA5A5` for write/read comparison.
- **Scoreboard**: Parallel arrays `sb_addr[]`, `sb_data[]`; tasks `sb_reset`, `sb_write(addr, data)`, `sb_check(addr, data)` (read-back must match or fatal).

### 3.3 Host Rules (Checker)

- **Illegal CMD**: On `cmd_put`, CMD must be NOP/SCR/SCW/BLR/BLW; else `$fatal` (or expected in NEGATIVE_TESTS).
- **Overrun**: If `cmd_put` when NOTFULL=0 and FILLCOUNT > 33, log error (boundary case tolerated for last-beat enqueue).

### 3.4 Watchdog

- **max_sim_cycles**: 200M; simulation should finish before this to avoid hangs.
- **Init watchdog**: If READY does not assert within ~2M cycles after INITDDR, `$fatal`.

---

## 4. Test Phases (Core Testbench)

| Phase | Description |
|-------|--------------|
| **Init** | RESET, INITDDR; wait for READY; sb_reset; coverage counters cleared. |
| **Test 1** | Scalar read/write at addresses 0, 1, 128, 512 (SCR/SCW, data path). |
| **Test 2** | Block read/write at SZ=00/01/10/11 (8/16/24/32 words) at selected bases. |
| **Test 3** | FIFO stress: mixed scalar/block traffic to trigger refresh; refresh monitor observes AUTO REFRESH. |
| **Test 4** | Reset during traffic: assert RESET mid-traffic, re-INITDDR, wait READY, re-run scalar/block to confirm recovery. |
| **Test 5** | Randomized mixed traffic (addresses and SZ). |
| **Test 6** | Manual self-refresh and power-down: SELFREF_REQ/EXIT, PWRDOWN_REQ/EXIT; idle windows; sanity scalar/block after exit. |
| **Test 7** | Multi-rank: `do_scalar_rw_ranked`, `do_block_rw_ranked` for rank 0 and 1; turnarounds and multi-rank corners. |
| **Test 8** | Automatic self-refresh: long idle; expect CKE to drop (auto_sref_seen) without SELFREF_REQ. |
| **Test 9** | Runtime DLL: DLL_REQ/DLL_MODE; wait DLL_BUSY assert/deassert; scalar/block after completion. |
| **Coverage** | Per-command (SCW/SCR/BLW/BLR) and per-SZ (00..11) counts printed at end. |
| **NEGATIVE_TESTS** (optional) | Illegal CMD enqueue (expected path); optional uninitialized read (commented by default). |

### 4.1 Key Tasks

- **`do_scalar_rw(addr)`**: Write pattern at `addr` (SCW), read back (SCR), sb_check.
- **`do_block_rw(addr, sz)`**: Block write then block read at `addr` with size `sz`; check each word via sb_check.
- **`do_scalar_rw_ranked(addr, rank)`**, **`do_block_rw_ranked(addr, sz, rank)`**: Same with RANK_SEL set.
- **`run_random_traffic`**: Randomized mix of scalar/block operations.
- **`test_turnarounds`**: tWTR/tRTW stress.
- **`test_multi_rank_corners`**: Multi-rank corner cases.

---

## 5. Monitors and Checkers

All monitors are passive (observe pins / DUT signals and `$display`/`$fatal` on violations).

| Module | Purpose |
|--------|--------|
| **ddr2_fifo_monitor** | FILLCOUNT vs NOTFULL: when FILLCOUNT ≥ 33, NOTFULL must be 0; logs high-water, fatal on violation. |
| **ddr2_refresh_monitor** | Detects AUTO REFRESH on command bus; enforces min/max interval between refreshes (from `ddr2_timing_config.vh` or params). Only after READY. |
| **ddr2_timing_checker** | Coarse JEDEC bank timing: tRCD, tRP, tRAS, tRFC at pad level. |
| **ddr2_turnaround_checker** | tWTR, tRTW, tWR, tRTP (write/read to precharge and direction changes). |
| **ddr2_bank_checker** | Bank/row consistency: no illegal row conflicts in a bank. |
| **ddr2_dqs_monitor** | DQS activity around WRITE bursts. |
| **ddr2_ocd_zq_monitor** | EMRS1 OCD patterns and ZQ calibration ordering (params for enter/exit and min cycles). |
| **ddr2_dll_mrs_monitor** | Runtime DLL: each DLL_REQ/DLL_BUSY window must produce one MRS with expected DLL-on/off encoding. |
| **ddr2_power_monitor** | When CKE=0 and CS# active, command bus must be NOP only; else fatal. |
| **ddr2_odt_monitor** | ODT asserted in a window after WRITE; deasserted for READ (directional check). |

---

## 6. Memory Model: `ddr2_simple_mem.v`

- **Behavioral**: Watches DDR2 command/address pins; on ACTIVATE latches row per bank; on WRITE captures 8-word burst; on READ after fixed latency drives 8-word burst on DQ/DQS.
- **Parameters**: `MEM_DEPTH` (words per rank), `READ_LAT`, `WRITE_LAT`, `RANK_BITS` (2^RANK_BITS ranks).
- **Debug**: `dbg_wr_valid/addr/data`, `dbg_rd_valid/addr/data` for testbench/scoreboard correlation.
- **Not** full JEDEC timing; sufficient for controller command/burst-level validation.

---

## 7. Server Testbench: `tb_ddr2_server_controller.v`

- Same flow as core testbench but instantiates `ddr2_server_controller` (64-bit data, ECC, scrubber, RAS).
- **Additional**: ECC enable, scrub enable, RAS register read; checks for ECC_SINGLE_ERR/ECC_DOUBLE_ERR, SCRUB_ACTIVE, RAS interrupts and status.
- **Extra tests**: ECC single/double fault injection, scrubbing progress, RAS thresholds and rank-offline behavior (when applicable).
- Uses same monitors where applicable (timing, refresh, FIFO, power, ODT, DLL, etc.); server-specific logic for 64-bit scoreboard and ECC/RAS/scrub checks.

---

## 8. Outputs and Artifacts

- **VCD**: `build/tb_ddr2_controller.iverilog.vcd` or `build/tb_ddr2_server_controller.iverilog.vcd` (default dump).
- **Log**: `test/result.txt` (append); per-config logs in `test/logs/` (e.g. `TOP=core_MODE=fast_MEM_DEPTH=1024_READ_LAT=24_RANK_BITS=0.log`).
- **CSV trace** (if `CSV_TRACE=1`): `build/ddr2_trace.csv` — per-cycle trace of CMD, SZ, ADDR, FETCHING, VALIDOUT, DOUT, RADDR, MEM_WR_*, MEM_RD_*.

---

## 9. File List (test/)

| File | Purpose |
|------|--------|
| `tb_ddr2_controller.v` | Core controller testbench; init, phases 1–9, scoreboard, coverage, optional NEGATIVE_TESTS. |
| `tb_ddr2_server_controller.v` | Server controller testbench; same flow + ECC/scrub/RAS. |
| `ddr2_simple_mem.v` | Behavioral DDR2 memory model. |
| `ddr2_timing_config.vh` | Shared timing defines for monitors. |
| `ddr2_fifo_monitor.v` | FILLCOUNT/NOTFULL checker. |
| `ddr2_refresh_monitor.v` | AUTO REFRESH interval checker. |
| `ddr2_timing_checker.v` | tRCD, tRP, tRAS, tRFC. |
| `ddr2_turnaround_checker.v` | tWTR, tRTW, tWR, tRTP. |
| `ddr2_bank_checker.v` | Bank/row consistency. |
| `ddr2_dqs_monitor.v` | DQS around writes. |
| `ddr2_ocd_zq_monitor.v` | OCD/ZQ sequence. |
| `ddr2_dll_mrs_monitor.v` | Runtime DLL MRS. |
| `ddr2_power_monitor.v` | CKE low ⇒ NOP only. |
| `ddr2_odt_monitor.v` | ODT vs WRITE/READ. |
| `run_tb.sh` | Build and run regression; TOP/MODE/MEM_DEPTH/READ_LAT/RANK_BITS sweep. |

---

## 10. Quick Reference

| Goal | Command / setting |
|------|-------------------|
| Default regression (core + server, fast + full) | `./test/run_tb.sh` |
| Core only, full bus | `TOP=core FULL_BUS=1 ./test/run_tb.sh` |
| Server only, fast | `TOP=server FULL_BUS=0 ./test/run_tb.sh` |
| Single config (no sweep) | Set TOP, FULL_BUS, MEM_DEPTH, READ_LAT, RANK_BITS as needed. |
| Negative tests (illegal CMD, etc.) | `NEGATIVE_TESTS=1 ./test/run_tb.sh` |
| CSV trace | `CSV_TRACE=1 ./test/run_tb.sh` |
| Results | `test/result.txt`, `test/logs/*.log`, `build/*.vcd`, `build/ddr2_trace.csv` (if CSV_TRACE). |

This testing setup provides functional coverage of init, scalar/block R/W, refresh, reset recovery, power modes, DLL, multi-rank, and (on server) ECC/scrub/RAS, with protocol and timing enforced by the monitors and optional strict JEDEC refresh bounds via `STRICT_JEDEC`.
