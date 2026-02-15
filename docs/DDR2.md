# DDR2 Controller Architecture

This document describes the architecture of the DDR2 controller design-under-test (DUT) in the `dut/` directory. The design targets JEDEC-style DDR2 SDRAM (e.g. Micron `mt47h32m16_37e`, 512 Mb, x16, 4 banks) and exposes a FIFO-like host interface.

---

## 1. Overview

- **Target device**: 512 Mb, x16, 4 banks (e.g. Micron mt47h32m16_37e). Timing and behavior are tuned for this reference device and the simulation environment; the design is not guaranteed fully JEDEC-compliant for all speed grades or parts.
- **Nominal clock**: Controller typically runs at 500 MHz (2 ns period); timing parameters in init and protocol engines are in controller clock cycles.
- **Top modules**:
  - **`ddr2_controller`**: Base controller with host FIFO interface, init, protocol engine, ring buffer, and PHY.
  - **`ddr2_server_controller`**: Server-grade wrapper adding ECC (SECDED), scrubbing, and RAS registers over four 16-bit slices in lockstep.
- **Host interface**: Synchronous, FIFO-style; commands (NOP, SCR, SCW, BLR, BLW), block size (SZ), address, write data, and flow control (READY, NOTFULL, FILLCOUNT, FETCHING, VALIDOUT, DOUT, RADDR).

---

## 2. Block Diagram (Core Controller)

```
                    ┌─────────────────────────────────────────────────────────┐
                    │                    ddr2_controller                       │
  Host              │                                                         │
  ────              │  ┌──────────────────┐     ┌─────────────────────────┐  │
  CMD,SZ,ADDR       │  │ ddr2_cmd_crc_    │     │ fifo (command)          │  │
  cmd_put           ───▶│ frontend          │────▶│ WIDTH=ADDR+8, DEPTH=64 │  │
  DIN,put_dataFIFO  │  │ (pass-through)   │     └───────────┬─────────────┘  │
  FETCHING         │  └──────────────────┘                 │                │
                    │         │                              ▼                │
                    │         │                 ┌─────────────────────────┐  │
                    │         │                 │ fifo (write data)       │  │
                    │         │                 │ WIDTH=16, DEPTH=64     │  │
                    │         │                 └───────────┬─────────────┘  │
                    │         │                              │                │
                    │         │     ┌────────────────────────┼────────────────┼───┐
                    │         │     │  ddr2_protocol_engine   │                │   │
                    │         └────▶│  (ACT/READ/WRITE/      │◀───────────────┘   │
                    │               │   REFRESH, timing,     │                    │
                    │               │   ring/return FIFO)    │                    │
                    │               └────────────┬────────────┘                    │
                    │                            │ cmd/addr/data                  │
                    │  ┌─────────────────────────┼─────────────────────────────┐  │
                    │  │ ddr2_init_engine        │      ddr2_phy               │  │
                    │  │ (power-up, MRS/EMRS,    │  (mux init vs protocol,   │  │
                    │  │  DLL, refresh, READY)   │   CK/CKE/CS#/RAS#/CAS#/WE#  │  │
                    │  └────────────┬───────────┘   BA/A/DM/ODT/DQ/DQS)       │  │
                    │               │                      │                  │  │
                    │               └──────────────────────┼──────────────────┘  │
                    │                                        │                    │
                    │  ┌────────────────────────────────────┴────────────────┐  │
                    │  │ ddr2_ring_buffer8 (read capture: listen → 8 samples)  │  │
                    │  └────────────────────────────────────┬────────────────┘  │
                    │                                        │                    │
                    │  ┌─────────────────────────────────────┴────────────────┐  │
                    │  │ fifo (return) WIDTH=ADDR+16, DEPTH=128                │  │
                    │  └─────────────────────────────────────┬────────────────┘  │
                    │                                        │                    │
  DOUT,RADDR       │                                        ▼                    │
  VALIDOUT         ◀─────────────────────────────────────────────────────────────┘
  READY,NOTFULL,FILLCOUNT
                    │
                    └─────────────────────────────────────────────────────────┘
                                         │
                                         ▼
                              DDR2 pads (CK, CKE, CS#, RAS#, CAS#, WE#, BA, A, DQ, DQS, DM, ODT)
```

---

## 3. Module Descriptions

### 3.1 Top level: `ddr2_controller.v`

- **Parameters**: `ADDR_WIDTH` (default 25), `RANK_BITS` (default 1).
- **Roles**:
  - Host command/data/return flow: command CRC front-end → command FIFO; write-data FIFO; return FIFO (or `SIM_DIRECT_READ` bypass). NOTFULL reflects command FIFO headroom only (data FIFO has extra margin; FILLCOUNT is observability only).
  - Arbitration between **init engine** and **protocol engine** via PHY (init until READY, then protocol).
  - Read path: PHY DQ/DQS → ring buffer (8 words) → return FIFO → DOUT/RADDR/VALIDOUT (or in `SIM_DIRECT_READ`, direct host-visible read from internal tracker). Return FIFO depth 128 avoids fill under backpressure for scalar reads (8 words pushed, 1 popped).
  - Multi-rank: single internal CS# fanned out to `C0_CSBAR_PAD[2**RANK_BITS-1:0]` using `prot_rank_sel`; during init CS# is broadcast to all ranks; after READY only the selected rank gets CS#.
- **Optional host controls**: SELFREF_REQ/EXIT, PWRDOWN_REQ/EXIT, DLL_REQ/DLL_MODE; status: SELFREF_ACTIVE, PWRDOWN_ACTIVE, DLL_BUSY.

### 3.2 Command / CRC front-end: `ddr2_cmd_crc_frontend.v`

- Sits between host and controller command inputs.
- **Current behavior**: Pass-through (no CRC/retry). Reserved for future CRC over {CMD, SZ, ADDR} and retry/feedback.

### 3.3 FIFOs: `fifo.v`

- **Synchronous single-clock FIFO**; used for:
  - **Command FIFO**: width = ADDR_WIDTH + 8, depth 2^6 (64); stores {ADDR, CMD, SZ}.
  - **Write-data FIFO**: width 16, depth 2^6 (64).
  - **Return FIFO**: width ADDR_WIDTH + 16, depth 2^7 (128); stores {RADDR, DOUT}.
- Registered read (one-cycle latency); flow control via full/empty and `full_bar`/`empty_bar`.

### 3.4 Init engine: `ddr2_init_engine.v`

- **JEDEC-style power-up**: wait (e.g. 200 µs or shortened for sim), CKE up, PREALL, MRS/EMRS1/EMRS2/EMRS3 (parameterized; EMRS2/EMRS3 typically 0), DLL reset, optional DLL-on/DLL-off, optional OCD/ZQ waits, AUTO REFRESH, then READY.
- **Parameters**: BL, BT, CL, AL; MRS_DLL_RST/ON/OFF; EMRS1_INIT/FINAL; **DLL_INIT_MODE** (0 = final MRS DLL-on, 1 = DLL-off); OCD_CALIB_EN, ZQ_CALIB_EN and wait cycles; timing (TXSR, TRP, TMRD, TRFC, TMRD_DLL, FINAL).
- **`SIM_SHORT_INIT`**: Shortens power-up wait for faster simulation.

### 3.5 Protocol engine: `ddr2_protocol_engine.v`

- **Command decode and sequencing**: ACTIVATE, READ, WRITE, PRECHARGE, AUTO REFRESH; respects bank/row and timing.
- **Address mapping**: Logical `ADDR` → {row, bank, column}. Default 25-bit layout: row = ADDR[24:12], bank = ADDR[4:3], column = {ADDR[11:5], ADDR[2:0]} (low 3 bits = intra-burst column; ROW_ADDR_WIDTH=13, COL_ADDR_WIDTH=10, BANK_ADDR_WIDTH=2). Read latency is parameterized (e.g. READ_LAT_OVERRIDE in simulation; default 24 controller cycles).
- **Timing parameters**: AL, CL, CWL; tRCD, tRP, tRAS, tRFC; ACT_GAP_MIN; REF_CNT_INIT/REF_THRESH; SELFREF_TXSR, PDOWN_TXP, AUTO_SREF_IDLE.
- **Features**: Refresh scheduler; self-refresh and power-down entry/exit; runtime DLL mode (DLL_REQ/DLL_MODE, MRS + tDLLK window); rank select for multi-rank CS#.
- **Data path**: Consumes command/data FIFOs; drives ring buffer listen/readPtr; pushes {addr, data} to return FIFO from ring output (or equivalent).

### 3.6 Ring buffer: `ddr2_ring_buffer8.v`

- **8-word read capture**: On `listen`, captures 8 consecutive controller-clock samples of DQ into r0..r7; `readPtr` selects which word is output.
- Aligns DDR read bursts to the controller’s single-clock domain for return FIFO fill.

### 3.7 PHY: `ddr2_phy.v`

- **Mux**: When `ready=0`, drives DDR2 pins from init engine; when `ready=1`, from protocol engine.
- **Clock**: Internal CK/CK# generation (toggle per controller clock).
- **DQ/DQS**: Drive when `ts_i` (write), else high-Z; read path `dq_i`/`dqs_i` from pads to ring buffer.
- **DM, ODT**: Driven from init (during init) or protocol engine (at runtime); DM[1:0] for x16 byte masking on writes; ODT asserted as required (e.g. during writes).
- **Power management**: Optional CKE override (`pm_use_cke_override`, `pm_cke_value`) for self-refresh and power-down.

---

## 4. Server controller: `ddr2_server_controller.v`

- **Wider host path**: 64-bit DIN/DOUT (four 16-bit DDR2 slices in lockstep). Slice 0 drives the external DDR2 pads and is the reference for READY, NOTFULL, VALIDOUT, FILLCOUNT; slices 1–3 when **SINGLE_PHY_MEMORY=1** have DQ tied to slice 0 so one physical memory drives all four lanes and 64-bit DOUT = four copies of slice 0 read data (for ECC/single-memory testbenches).
- **Host-to-core mapping**: Core address = lower ADDR_WIDTH bits of host address; upper RANK_BITS (when > 0) are reserved for future rank index; today RANK_BITS=0 so mapping is pass-through. Rank-select hint to core (e.g. host address MSB) is for observability only and does not yet drive multi-CS at pads.
- **Sub-blocks**:
  - **`ecc_core`** (wrapping **`ecc_secded`**): SECDED(72,64) encode on write, decode on read; single/double error flags. ECC shadow storage (per-address ECC bits and valid flags) ensures never-written locations do not spuriously report errors; ECC status is gated by address validity and VALIDOUT. In full bus-level mode ECC can be disabled internally to avoid interpreting unmodelled bus/X as errors; in SIM_DIRECT_READ the host ECC_ENABLE is honored.
  - **`ddr2_scrubber`**: Background read-verify-correct; issues BLR/BLW at low priority; receives **ECC-corrected** data from the server block for write-back so repaired locations store the corrected value. **Disabled in SIM_DIRECT_READ** (fast mode) to avoid timing violations; SCRUB_ENABLE still toggles for register coverage.
  - **`ddr2_ras_registers`**: Error counters, thresholds, scrub progress, IRQ (correctable/uncorrectable), rank degraded/fatal, and **rank_offline** bitmap; see §4.3 for register map.
- **Command arbitration**: **Host has priority over scrubber**. When RAS marks a rank offline (**rank_offline**), new host commands targeting that rank are blocked (no new traffic to bad ranks); scrubber and host commands are muxed into a single command stream to the core.
- **Parameters**: HOST_ADDR_WIDTH, ADDR_WIDTH, RANK_BITS, SINGLE_PHY_MEMORY (single physical memory / replicated DOUT).
- **Outputs**: ECC_SINGLE_ERR, ECC_DOUBLE_ERR, SCRUB_ACTIVE, RAS_IRQ_CORR/UNCORR, RAS_RANK_DEGRADED, RAS_FATAL_ERROR, RAS_REG_ADDR/DATA (read-only register data).

### 4.1 ECC: `ecc_core.v`, `ecc_secded.v`

- **ecc_core**: Wrapper; ECC_MODE=0 uses SECDED(72,64); ECC_MODE≠0 is stub (pass-through).
- **ecc_secded**: 64-bit data + 8-bit ECC (7 Hamming parity + 1 overall parity → SECDED(72,64)); single-bit correct, double-bit detect. Tuned for DATA_WIDTH=64, PARITY_BITS=7; other combinations are not validated in this design.

### 4.2 Scrubbing: `ddr2_scrubber.v`

- **Parameters**: ADDR_WIDTH, SCRUB_BURST_SIZE (words per scrub op, default 8). Address range: scrub_start_addr to scrub_end_addr (default full space). Waits IDLE_THRESHOLD (e.g. 100) controller cycles of idle (NOTFULL and READY) before issuing scrub commands.
- State machine: IDLE → WAIT_IDLE → ISSUE_READ → WAIT_DATA → CHECK_ECC → (optional) ISSUE_WRITE → WAIT_WRITE; uses controller command/data/return interface; write-back uses ECC-corrected data from parent.

### 4.3 RAS: `ddr2_ras_registers.v`

- **Parameters**: ADDR_WIDTH, NUM_RANKS. Per-rank correctable and uncorrectable error counters; configurable thresholds (default corr 1000, uncorr 1); scrub_count, scrub_interval; last error context (addr, rank, syndrome, type). Correctable count ≥ threshold → IRQ_CORR and rank_degraded; uncorrectable → IRQ_UNCORR and fatal_error; uncorrectable count per rank ≥ threshold → that rank marked **rank_offline** (no new host traffic to that rank).
- **Register map** (RAS_REG_ADDR → RAS_REG_DATA): 0x00 total_corr_errors, 0x04 total_uncorr_errors, 0x08 last_err (type/rank/syndrome), 0x0C last_err_addr, 0x10 corr_err_threshold, 0x14 uncorr_err_threshold, 0x18 scrub_count, 0x1C scrub_progress, 0x20 status (fatal/rank_degraded/irq_uncorr/irq_corr), 0x24 rank_offline bitmap; 0x40+ per-rank correctable counters (4 bytes per rank); 0x80+ per-rank uncorrectable counters (4 bytes per rank).

---

## 5. Host Interface Summary (Core)

| Direction | Signal       | Description |
|----------|--------------|-------------|
| In       | CLK          | Controller clock (e.g. 500 MHz). |
| In       | RESET        | Synchronous reset. |
| In       | INITDDR      | Assert to start init; deassert after one cycle. |
| In       | CMD[2:0]     | NOP=000, SCR=001, SCW=010, BLR=011, BLW=100. |
| In       | SZ[1:0]      | Block size: 1/2/3/4 bursts of 8 words (for BLR/BLW). |
| In       | ADDR         | Logical word address (ADDR_WIDTH bits). |
| In       | cmd_put      | Assert one cycle to enqueue command (when NOTFULL). |
| In       | DIN          | Write data (16-bit core; 64-bit server). |
| In       | put_dataFIFO | Assert to push one word into write-data FIFO. |
| In       | FETCHING     | Assert to pop one entry from return path (DOUT/RADDR next cycle). |
| Out      | READY        | High when init has completed. |
| Out      | NOTFULL      | Command FIFO has room (host must not enqueue when low). |
| Out      | FILLCOUNT    | Write-data FIFO occupancy (observability). |
| Out      | DOUT, RADDR  | Read data and address tag. |
| Out      | VALIDOUT     | DOUT/RADDR valid (e.g. one cycle after FETCHING pop). |

**Optional (core)**: RANK_SEL (rank index when RANK_BITS > 0); SELFREF_REQ/EXIT, PWRDOWN_REQ/EXIT (power-management); DLL_REQ/DLL_MODE (runtime DLL); SELFREF_ACTIVE, PWRDOWN_ACTIVE, DLL_BUSY (status). **Server** adds: ECC_ENABLE, SCRUB_ENABLE, RAS_REG_ADDR; RAS_REG_DATA; ECC_SINGLE_ERR, ECC_DOUBLE_ERR, SCRUB_ACTIVE, RAS_IRQ_CORR/UNCORR, RAS_RANK_DEGRADED, RAS_FATAL_ERROR.

---

## 6. Simulation-Only Behavior

- **`SIM_DIRECT_READ`**: Bypasses full DDR2 read path; host read data is generated from an internal tracker keyed by accepted SCR/BLR commands so that DOUT/RADDR/VALIDOUT match the testbench pattern without relying on ring buffer and memory model timing.
- **`SIM_SHORT_INIT`**: Shortens init power-up wait so regression runs finish in reasonable time.

---

## 7. File List (dut/)

| File                      | Purpose |
|---------------------------|--------|
| `ddr2_controller.v`       | Core top: host FIFOs, init, protocol, ring, PHY, CS# fan-out. |
| `ddr2_server_controller.v` | Server top: 4× slices, ECC, scrubber, RAS. |
| `ddr2_cmd_crc_frontend.v`| Command front-end (pass-through). |
| `ddr2_init_engine.v`     | Power-up and MRS/EMRS/DLL/refresh, READY. |
| `ddr2_protocol_engine.v` | Transaction FSM, timing, refresh, power/DLL, rank. |
| `ddr2_ring_buffer8.v`    | 8-word read capture from DQ. |
| `ddr2_phy.v`             | Init/protocol mux, CK, CKE, DQ/DQS, ODT. |
| `fifo.v`                 | Synchronous FIFO for command, data, return. |
| `ecc_core.v`             | ECC wrapper (SECDED or stub). |
| `ecc_secded.v`           | SECDED(72,64) encode/decode. |
| `ddr2_scrubber.v`        | Background scrub FSM. |
| `ddr2_ras_registers.v`   | RAS CSRs and interrupts. |

This architecture is aligned with the JEDEC DDR2 flow (init, ACT/RD/WR/PRE, refresh, power modes) and is parameterized for address width, ranks, and timing; the server extension adds ECC, scrubbing, and RAS for reliability and observability. For compliance and usage disclaimer, see the repository README.
