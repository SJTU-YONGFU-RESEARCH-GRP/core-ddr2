`timescale 1ns/1ps

`include "uvm_macros.svh"
import uvm_pkg::*;

`include "ddr2_host_if.sv"

// -----------------------------------------------------------------------------
// Command encodings (matching DUT and legacy testbench)
// -----------------------------------------------------------------------------
localparam CMD_NOP  = 3'b000;
localparam CMD_SCR  = 3'b001;
localparam CMD_SCW  = 3'b010;
localparam CMD_BLR  = 3'b011;
localparam CMD_BLW  = 3'b100;

// -----------------------------------------------------------------------------
// Helper function: deterministic data pattern as a function of address
// -----------------------------------------------------------------------------
function automatic bit [15:0] pattern_for_addr(bit [24:0] addr);
    pattern_for_addr = {addr[7:0], addr[15:8]} ^ 16'hA5A5;
endfunction

// -----------------------------------------------------------------------------
// Helper function: number of words for block operations from SZ encoding
// -----------------------------------------------------------------------------
function automatic int unsigned num_words_for_sz(bit [1:0] sz);
    case (sz)
      2'b00: num_words_for_sz = 8;
      2'b01: num_words_for_sz = 16;
      2'b10: num_words_for_sz = 24;
      2'b11: num_words_for_sz = 32;
      default: num_words_for_sz = 8;
    endcase
endfunction

// -----------------------------------------------------------------------------
// Delay constants (ns) for sequence timing; tune to DUT latency if needed
// -----------------------------------------------------------------------------
localparam int unsigned DELAY_SCALAR_WR_NS  = 2000;
localparam int unsigned DELAY_SCALAR_RD_NS  = 1000;
localparam int unsigned DELAY_BLOCK_WR_NS   = 6000;
localparam int unsigned DELAY_BLOCK_RD_NS   = 2000;
localparam int unsigned DELAY_INIT_WAIT_NS  = 500000;
localparam int unsigned DELAY_STRESS_MIN_NS = 100;
localparam int unsigned DELAY_STRESS_MAX_NS = 1000;

// -----------------------------------------------------------------------------
// DDR2 transaction: host-level command + payload metadata
// -----------------------------------------------------------------------------

class ddr2_txn extends uvm_sequence_item;

  // Host-visible command encoding (SCR/SCW/BLR/BLW, etc.)
  rand bit [2:0]  cmd;
  rand bit [1:0]  sz;
  rand bit [24:0] addr;

  // For writes, this is the starting data word; tests may derive actual
  // payload patterns from address to keep scoreboard simple.
  rand bit [15:0] data_seed;

  // Transaction ID for ordering and debug traceability
  static int unsigned _id_count = 0;
  int unsigned id;

  // Requirement tags for traceability (see REQUIREMENTS_MATRIX.md)
  string req_tags[$];

  // Valid traffic: exclude NOP when generating random commands
  constraint c_valid_traffic {
    cmd inside {CMD_SCR, CMD_SCW, CMD_BLR, CMD_BLW};
  }

  // Block ops must be aligned to 8-word (burst) boundary
  constraint c_block_alignment {
    (cmd == CMD_BLR || cmd == CMD_BLW) -> (addr[2:0] == 3'b0);
  }

  `uvm_object_utils_begin(ddr2_txn)
    `uvm_field_int(cmd,       UVM_ALL_ON)
    `uvm_field_int(sz,        UVM_ALL_ON)
    `uvm_field_int(addr,      UVM_ALL_ON)
    `uvm_field_int(data_seed, UVM_ALL_ON)
    `uvm_field_int(id,        UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "ddr2_txn");
    super.new(name);
    id = _id_count++;
  endfunction

  function string convert2string();
    return $sformatf("id=%0d cmd=%0b sz=%0b addr=0x%0h data_seed=0x%0h",
                     id, cmd, sz, addr, data_seed);
  endfunction

  // Return number of words for this transaction (1 for scalar, 8/16/24/32 for block)
  function int unsigned num_words();
    if (cmd == CMD_SCR || cmd == CMD_SCW) return 1;
    return num_words_for_sz(sz);
  endfunction

endclass

// -----------------------------------------------------------------------------
// DDR2 base sequence
// -----------------------------------------------------------------------------

class ddr2_base_seq extends uvm_sequence #(ddr2_txn);

  rand int unsigned num_txn;

  `uvm_object_utils(ddr2_base_seq)

  function new(string name = "ddr2_base_seq");
    super.new(name);
    num_txn = 8;
  endfunction

  task body();
    ddr2_txn tr;
    `uvm_info(get_type_name(),
              $sformatf("Starting ddr2_base_seq with %0d transactions", num_txn),
              UVM_MEDIUM)
    repeat (num_txn) begin
      tr = ddr2_txn::type_id::create("tr");
      assert(tr.randomize());
      start_item(tr);
      finish_item(tr);
    end
    `uvm_info(get_type_name(), "Completed ddr2_base_seq", UVM_MEDIUM)
  endtask

endclass

// -----------------------------------------------------------------------------
// DDR2 init-only sequence: waits for initialization, no traffic
// -----------------------------------------------------------------------------
class ddr2_init_only_seq extends uvm_sequence #(ddr2_txn);

  `uvm_object_utils(ddr2_init_only_seq)

  function new(string name = "ddr2_init_only_seq");
    super.new(name);
  endfunction

  task body();
    `uvm_info(get_type_name(), "Init-only sequence: driver handles reset/INITDDR, this sequence completes immediately", UVM_MEDIUM)
    // Driver already handles reset and INITDDR; this sequence just waits
    // for the test to complete initialization checks.
  endtask

endclass

// -----------------------------------------------------------------------------
// DDR2 scalar read/write sequence: basic SCR/SCW operations
// -----------------------------------------------------------------------------
class ddr2_scalar_rw_seq extends uvm_sequence #(ddr2_txn);

  `uvm_object_utils(ddr2_scalar_rw_seq)

  rand bit [24:0] addresses[$];
  int unsigned num_ops;

  function new(string name = "ddr2_scalar_rw_seq");
    super.new(name);
    num_ops = 4;  // Default: 4 scalar RW pairs
  endfunction

  task body();
    ddr2_txn tr_wr, tr_rd;
    bit [24:0] addr;
    bit [15:0] data;

    `uvm_info(get_type_name(),
              $sformatf("Starting scalar RW sequence with %0d operations", num_ops),
              UVM_MEDIUM)

    // Use provided addresses or default set
    if (addresses.size() == 0) begin
      addresses.push_back(25'd0);
      addresses.push_back(25'd1);
      addresses.push_back(25'd128);
      addresses.push_back(25'd512);
    end

    foreach (addresses[i]) begin
      if (i >= num_ops) break;
      addr = addresses[i];
      data = pattern_for_addr(addr);

      // Scalar write
      tr_wr = ddr2_txn::type_id::create("tr_wr");
      tr_wr.cmd = CMD_SCW;
      tr_wr.sz = 2'b00;
      tr_wr.addr = addr;
      tr_wr.data_seed = data;
      start_item(tr_wr);
      finish_item(tr_wr);

      // Wait for write to complete (simple delay - driver handles actual timing)
      #(DELAY_SCALAR_WR_NS);

      // Scalar read
      tr_rd = ddr2_txn::type_id::create("tr_rd");
      tr_rd.cmd = CMD_SCR;
      tr_rd.sz = 2'b00;
      tr_rd.addr = addr;
      tr_rd.data_seed = 16'h0;  // Not used for reads
      start_item(tr_rd);
      finish_item(tr_rd);

      // Allow time for read to return
      #(DELAY_SCALAR_RD_NS);
    end

    `uvm_info(get_type_name(), "Completed scalar RW sequence", UVM_MEDIUM)
  endtask

endclass

// -----------------------------------------------------------------------------
// DDR2 block read/write sequence: all SZ values
// -----------------------------------------------------------------------------
class ddr2_block_rw_all_sizes_seq extends uvm_sequence #(ddr2_txn);

  `uvm_object_utils(ddr2_block_rw_all_sizes_seq)

  function new(string name = "ddr2_block_rw_all_sizes_seq");
    super.new(name);
  endfunction

  task body();
    ddr2_txn tr_wr, tr_rd;
    bit [24:0] base_addrs[4];
    bit [1:0] sz_vals[4];
    int unsigned num_words[4];

    base_addrs[0] = 25'd32;
    base_addrs[1] = 25'd256;
    base_addrs[2] = 25'd384;
    base_addrs[3] = 25'd512;

    sz_vals[0] = 2'b00; num_words[0] = 8;
    sz_vals[1] = 2'b01; num_words[1] = 16;
    sz_vals[2] = 2'b10; num_words[2] = 24;
    sz_vals[3] = 2'b11; num_words[3] = 32;

    `uvm_info(get_type_name(), "Starting block RW sequence for all SZ values", UVM_MEDIUM)

    for (int i = 0; i < 4; i++) begin
      // Block write
      tr_wr = ddr2_txn::type_id::create("tr_wr");
      tr_wr.cmd = CMD_BLW;
      tr_wr.sz = sz_vals[i];
      tr_wr.addr = base_addrs[i];
      tr_wr.data_seed = pattern_for_addr(base_addrs[i]);
      start_item(tr_wr);
      finish_item(tr_wr);

      // Wait for block write to complete
      #(DELAY_BLOCK_WR_NS);

      // Block read
      tr_rd = ddr2_txn::type_id::create("tr_rd");
      tr_rd.cmd = CMD_BLR;
      tr_rd.sz = sz_vals[i];
      tr_rd.addr = base_addrs[i];
      tr_rd.data_seed = 16'h0;
      start_item(tr_rd);
      finish_item(tr_rd);

      // Allow time for block read to return
      #(DELAY_BLOCK_RD_NS);
    end

    `uvm_info(get_type_name(), "Completed block RW sequence", UVM_MEDIUM)
  endtask

endclass

// -----------------------------------------------------------------------------
// DDR2 address mapping edges sequence: test row/bank boundaries
// -----------------------------------------------------------------------------
class ddr2_addr_edges_seq extends uvm_sequence #(ddr2_txn);

  `uvm_object_utils(ddr2_addr_edges_seq)

  function new(string name = "ddr2_addr_edges_seq");
    super.new(name);
  endfunction

  task body();
    ddr2_txn tr;
    bit [24:0] edge_addrs[$];

    `uvm_info(get_type_name(), "Starting address mapping edges sequence", UVM_MEDIUM)

    // Test addresses near row/bank boundaries
    // These are example addresses; adjust based on actual DDR2 geometry
    edge_addrs.push_back(25'd0);        // Start of address space
    edge_addrs.push_back(25'd1023);     // Near end of small window
    edge_addrs.push_back(25'd2047);     // Mid-range
    edge_addrs.push_back(25'd4095);     // Higher range
    edge_addrs.push_back(25'd8191);     // Near max for 13-bit row

    foreach (edge_addrs[i]) begin
      // Write
      tr = ddr2_txn::type_id::create("tr_wr");
      tr.cmd = CMD_SCW;
      tr.sz = 2'b00;
      tr.addr = edge_addrs[i];
      tr.data_seed = pattern_for_addr(edge_addrs[i]);
      start_item(tr);
      finish_item(tr);

      #(DELAY_SCALAR_WR_NS);

      // Read
      tr = ddr2_txn::type_id::create("tr_rd");
      tr.cmd = CMD_SCR;
      tr.sz = 2'b00;
      tr.addr = edge_addrs[i];
      tr.data_seed = 16'h0;
      start_item(tr);
      finish_item(tr);

      #(DELAY_SCALAR_RD_NS);
    end

    `uvm_info(get_type_name(), "Completed address mapping edges sequence", UVM_MEDIUM)
  endtask

endclass

// -----------------------------------------------------------------------------
// DDR2 random stress sequence: constrained-random traffic
// -----------------------------------------------------------------------------
class ddr2_random_stress_seq extends uvm_sequence #(ddr2_txn);

  `uvm_object_utils(ddr2_random_stress_seq)

  rand int unsigned num_txn;
  rand bit [24:0] addr_min;
  rand bit [24:0] addr_max;

  constraint c_num_txn {
    num_txn inside {[64:256]};
  }

  constraint c_addr_range {
    addr_min < addr_max;
    addr_max < 25'h1FFFFFF;
  }

  function new(string name = "ddr2_random_stress_seq");
    super.new(name);
    num_txn = 128;
    addr_min = 25'd0;
    addr_max = 25'd1023;
  endfunction

  task body();
    ddr2_txn tr;
    bit [24:0] addr;
    bit [1:0] cmd_choice;
    bit [1:0] sz_val;

    `uvm_info(get_type_name(),
              $sformatf("Starting random stress sequence: %0d transactions, addr range [0x%0h:0x%0h]",
                        num_txn, addr_min, addr_max),
              UVM_MEDIUM)

    for (int i = 0; i < num_txn; i++) begin
      tr = ddr2_txn::type_id::create("tr");
      assert(tr.randomize() with {
        addr >= addr_min;
        addr <= addr_max;
      });

      start_item(tr);
      finish_item(tr);

      // Random delay between transactions
      #($urandom_range(DELAY_STRESS_MIN_NS, DELAY_STRESS_MAX_NS));
    end

    `uvm_info(get_type_name(), "Completed random stress sequence", UVM_MEDIUM)
  endtask

endclass

// -----------------------------------------------------------------------------
// DDR2 driver: drives host interface of ddr2_controller
// -----------------------------------------------------------------------------

class ddr2_driver extends uvm_driver #(ddr2_txn);

  `uvm_component_utils(ddr2_driver)

  virtual ddr2_host_if.drv vif;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    ddr2_txn tr;

    if (vif == null) begin
      `uvm_fatal(get_type_name(), "vif is null; did you set it via config DB?")
    end

    // Initialize host interface
    vif.RESET      <= 1'b1;
    vif.INITDDR    <= 1'b0;
    vif.CMD        <= '0;
    vif.SZ         <= '0;
    vif.ADDR       <= '0;
    vif.cmd_put    <= 1'b0;
    vif.DIN        <= '0;
    vif.put_dataFIFO <= 1'b0;
    vif.FETCHING   <= 1'b0;

    // Simple reset sequence
    repeat (5) @(posedge vif.CLK);
    vif.RESET <= 1'b0;

    // Pulse INITDDR once after reset
    @(posedge vif.CLK);
    vif.INITDDR <= 1'b1;
    @(posedge vif.CLK);
    vif.INITDDR <= 1'b0;

    // Wait until DUT reports READY before driving traffic
    wait (vif.READY == 1'b1);

    forever begin
      seq_item_port.get_next_item(tr);

      // Wait for NOTFULL before issuing command
      while (!vif.NOTFULL) begin
        @(posedge vif.CLK);
      end

      // Issue command
      @(posedge vif.CLK);
      vif.CMD     <= tr.cmd;
      vif.SZ      <= tr.sz;
      vif.ADDR    <= tr.addr;
      vif.cmd_put <= 1'b1;
      
      // For writes, also drive data
      if (tr.cmd == CMD_SCW || tr.cmd == CMD_BLW) begin
        vif.DIN <= tr.data_seed;
        vif.put_dataFIFO <= 1'b1;
      end else begin
        vif.put_dataFIFO <= 1'b0;
      end

      @(posedge vif.CLK);
      vif.cmd_put <= 1'b0;

      // For block writes, push additional data beats into the data FIFO
      if (tr.cmd == CMD_BLW) begin
        int unsigned nw = num_words_for_sz(tr.sz);
        // Push remaining words (first word already sent with command)
        for (int i = 1; i < nw; i++) begin
          @(posedge vif.CLK);
          // Derive data pattern from base address + offset
          vif.DIN <= pattern_for_addr(tr.addr + i[24:0]);
          vif.put_dataFIFO <= 1'b1;
        end
        
        @(posedge vif.CLK);
        vif.put_dataFIFO <= 1'b0;
      end else begin
        // For scalar writes, data was already sent with command
        vif.put_dataFIFO <= 1'b0;
      end

      `uvm_info(get_type_name(),
                $sformatf("Issued transaction: %s", tr.convert2string()),
                UVM_MEDIUM)

      seq_item_port.item_done();
    end
  endtask

endclass

// -----------------------------------------------------------------------------
// DDR2 monitor: observes host interface
// -----------------------------------------------------------------------------

class ddr2_monitor extends uvm_component;

  `uvm_component_utils(ddr2_monitor)

  virtual ddr2_host_if.mon vif;
  uvm_analysis_port #(ddr2_txn) ap_cmd;

  // Functional coverage (Verilator does not support covergroups; lint off for clean build)
  /* verilator lint_off COVERIGN */
  covergroup cmd_cov;
    cmd_cp: coverpoint vif.CMD {
      bins cmd_nop = {CMD_NOP};
      bins cmd_scr = {CMD_SCR};
      bins cmd_scw = {CMD_SCW};
      bins cmd_blr = {CMD_BLR};
      bins cmd_blw = {CMD_BLW};
      illegal_bins illegal = default;
    }
    sz_cp: coverpoint vif.SZ {
      bins sz_00 = {2'b00};
      bins sz_01 = {2'b01};
      bins sz_10 = {2'b10};
      bins sz_11 = {2'b11};
    }
    addr_cp: coverpoint vif.ADDR {
      bins low_addr  = {[0:1023]};
      bins mid_addr  = {[1024:4095]};
      bins high_addr = {[4096:33554431]};
    }
    cmd_sz_cross: cross cmd_cp, sz_cp;
  endgroup
  /* verilator lint_on COVERIGN */

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap_cmd = new("ap_cmd", this);
    cmd_cov = new();
  endfunction

  task run_phase(uvm_phase phase);
    ddr2_txn tr;

    if (vif == null) begin
      `uvm_fatal(get_type_name(), "vif is null; did you set it via config DB?")
    end

    forever begin
      @(posedge vif.CLK);
      if (vif.cmd_put && vif.NOTFULL) begin
        tr = ddr2_txn::type_id::create("tr_mon");
        tr.cmd       = vif.CMD;
        tr.sz        = vif.SZ;
        tr.addr      = vif.ADDR;
        tr.data_seed = vif.DIN;
        ap_cmd.write(tr);
        
        // Sample coverage
        cmd_cov.sample();
      end
    end
  endtask

endclass

// -----------------------------------------------------------------------------
// DDR2 scoreboard: simple host-view memory model
// -----------------------------------------------------------------------------

class ddr2_scoreboard extends uvm_component;

  `uvm_component_utils(ddr2_scoreboard)

  uvm_analysis_imp #(ddr2_txn, ddr2_scoreboard) imp_cmd;
  virtual ddr2_host_if.mon vif;

  // Simple associative array for host-view memory, keyed by logical address.
  // For block writes, we store the seed and derive burst data from it.
  bit [15:0] mem_model [bit [24:0]];
  
  // Statistics
  int unsigned num_writes;
  int unsigned num_reads_checked;
  int unsigned num_mismatches;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    imp_cmd = new("imp_cmd", this);
    num_writes = 0;
    num_reads_checked = 0;
    num_mismatches = 0;
  endfunction

  function void write(ddr2_txn t);
    // Update reference model for write commands (SCW, BLW).
    // For SCW: store single word at addr. For BLW: store all burst words at
    // addr, addr+1, ... using the same pattern as the driver (pattern_for_addr).
    if (t.cmd == CMD_SCW) begin
      mem_model[t.addr] = t.data_seed;
      num_writes++;
      `uvm_info(get_type_name(),
                $sformatf("Scoreboard write: cmd=SCW addr=0x%0h data=0x%0h", t.addr, t.data_seed),
                UVM_MEDIUM)
    end else if (t.cmd == CMD_BLW) begin
      int unsigned nw = num_words_for_sz(t.sz);
      for (int i = 0; i < nw; i++) begin
        bit [24:0] waddr = t.addr + i;
        mem_model[waddr] = pattern_for_addr(waddr);
      end
      num_writes += nw;
      `uvm_info(get_type_name(),
                $sformatf("Scoreboard write: cmd=BLW addr=0x%0h sz=%0b words=%0d",
                          t.addr, t.sz, nw),
                UVM_MEDIUM)
    end
  endfunction

  task run_phase(uvm_phase phase);
    if (vif == null) begin
      `uvm_fatal(get_type_name(), "vif is null; did you set it via config DB?")
    end

    forever begin
      @(posedge vif.CLK);
      if (vif.VALIDOUT && !vif.RESET) begin
        check_read_data(vif.RADDR, vif.DOUT);
      end
    end
  endtask

  function void check_read_data(bit [24:0] raddr, bit [15:0] dout);
    bit [15:0] expected;
    bit found;
    
    // For scalar reads, check exact match.
    // For block reads, derive expected from base address pattern.
    // Simple heuristic: if address exists in model, use it; otherwise derive from pattern.
    if (mem_model.exists(raddr)) begin
      expected = mem_model[raddr];
      found = 1;
    end else begin
      // Derive expected from address pattern (for block reads or uninitialized)
      expected = pattern_for_addr(raddr);
      found = 0;
    end

    num_reads_checked++;
    
    if (dout !== expected) begin
      num_mismatches++;
      `uvm_error(get_type_name(),
                 $sformatf("Read mismatch: RADDR=0x%0h expected=0x%0h got=0x%0h %s",
                           raddr, expected, dout,
                           found ? "(from model)" : "(derived from pattern)"))
    end else begin
      `uvm_info(get_type_name(),
                $sformatf("Read check OK: RADDR=0x%0h data=0x%0h",
                          raddr, dout),
                UVM_HIGH)
    end
  endfunction

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info(get_type_name(),
              $sformatf("Scoreboard: writes=%0d reads_checked=%0d mismatches=%0d",
                        num_writes, num_reads_checked, num_mismatches),
              UVM_MEDIUM)
    if (num_mismatches > 0)
      `uvm_error(get_type_name(), $sformatf("Scoreboard found %0d data mismatches!", num_mismatches))
  endfunction

endclass

// -----------------------------------------------------------------------------
// DDR2 environment: connects driver, monitor, scoreboard
// -----------------------------------------------------------------------------

class ddr2_env extends uvm_env;

  `uvm_component_utils(ddr2_env)

  ddr2_driver     drv;
  ddr2_monitor    mon;
  ddr2_scoreboard sb;
  uvm_sequencer #(ddr2_txn) seqr;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    drv = ddr2_driver    ::type_id::create("drv", this);
    mon = ddr2_monitor   ::type_id::create("mon", this);
    sb  = ddr2_scoreboard::type_id::create("sb",  this);
    seqr = uvm_sequencer#(ddr2_txn)::type_id::create("seqr", this);

    if (!uvm_config_db#(virtual ddr2_host_if.drv)::get(this, "", "vif_host_drv", drv.vif)) begin
      `uvm_fatal(get_type_name(), "Failed to get vif_host_drv for driver from config DB")
    end
    if (!uvm_config_db#(virtual ddr2_host_if.mon)::get(this, "", "vif_host_mon", mon.vif)) begin
      `uvm_fatal(get_type_name(), "Failed to get vif_host_mon for monitor from config DB")
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    mon.ap_cmd.connect(sb.imp_cmd);
    drv.seq_item_port.connect(seqr.seq_item_export);
    // Connect scoreboard to monitor's vif for read checking
    sb.vif = mon.vif;
  endfunction

endclass

// -----------------------------------------------------------------------------
// DDR2 smoke test: skeleton mapping to T1/T2
// -----------------------------------------------------------------------------

class ddr2_smoke_test extends uvm_test;

  `uvm_component_utils(ddr2_smoke_test)

  ddr2_env env;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = ddr2_env::type_id::create("env", this);
  endfunction

  task run_phase(uvm_phase phase);
    ddr2_base_seq seq;

    phase.raise_objection(this, "Starting ddr2_smoke_test");

    seq = ddr2_base_seq::type_id::create("seq");
    seq.start(env.seqr);

    phase.drop_objection(this, "Completed ddr2_smoke_test");
  endtask

endclass

// -----------------------------------------------------------------------------
// T1: DDR2 init power-up basic test
// -----------------------------------------------------------------------------
class ddr2_init_powerup_basic_test extends uvm_test;

  `uvm_component_utils(ddr2_init_powerup_basic_test)

  ddr2_env env;
  ddr2_init_only_seq seq;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = ddr2_env::type_id::create("env", this);
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this, "Starting ddr2_init_powerup_basic_test");

    seq = ddr2_init_only_seq::type_id::create("seq");
    seq.start(env.seqr);

    // Wait for READY to assert (driver handles reset/INITDDR)
    #(DELAY_INIT_WAIT_NS);

    `uvm_info(get_type_name(), "Init power-up test completed", UVM_MEDIUM)
    phase.drop_objection(this, "Completed ddr2_init_powerup_basic_test");
  endtask

endclass

// -----------------------------------------------------------------------------
// T2: DDR2 scalar read/write basic test
// -----------------------------------------------------------------------------
class ddr2_scalar_rw_basic_test extends uvm_test;

  `uvm_component_utils(ddr2_scalar_rw_basic_test)

  ddr2_env env;
  ddr2_scalar_rw_seq seq;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = ddr2_env::type_id::create("env", this);
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this, "Starting ddr2_scalar_rw_basic_test");

    seq = ddr2_scalar_rw_seq::type_id::create("seq");
    seq.num_ops = 4;
    seq.start(env.seqr);

    // Allow time for all reads to complete
    #100000;

    `uvm_info(get_type_name(), "Scalar RW basic test completed", UVM_MEDIUM)
    phase.drop_objection(this, "Completed ddr2_scalar_rw_basic_test");
  endtask

endclass

// -----------------------------------------------------------------------------
// T3: DDR2 block read/write all sizes test
// -----------------------------------------------------------------------------
class ddr2_block_rw_all_sizes_test extends uvm_test;

  `uvm_component_utils(ddr2_block_rw_all_sizes_test)

  ddr2_env env;
  ddr2_block_rw_all_sizes_seq seq;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = ddr2_env::type_id::create("env", this);
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this, "Starting ddr2_block_rw_all_sizes_test");

    seq = ddr2_block_rw_all_sizes_seq::type_id::create("seq");
    seq.start(env.seqr);

    // Allow time for all block operations to complete
    #200000;

    `uvm_info(get_type_name(), "Block RW all sizes test completed", UVM_MEDIUM)
    phase.drop_objection(this, "Completed ddr2_block_rw_all_sizes_test");
  endtask

endclass

// -----------------------------------------------------------------------------
// T4: DDR2 address mapping edges test
// -----------------------------------------------------------------------------
class ddr2_address_mapping_edges_test extends uvm_test;

  `uvm_component_utils(ddr2_address_mapping_edges_test)

  ddr2_env env;
  ddr2_addr_edges_seq seq;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = ddr2_env::type_id::create("env", this);
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this, "Starting ddr2_address_mapping_edges_test");

    seq = ddr2_addr_edges_seq::type_id::create("seq");
    seq.start(env.seqr);

    // Allow time for all edge case operations to complete
    #150000;

    `uvm_info(get_type_name(), "Address mapping edges test completed", UVM_MEDIUM)
    phase.drop_objection(this, "Completed ddr2_address_mapping_edges_test");
  endtask

endclass

// -----------------------------------------------------------------------------
// T10: DDR2 random full system stress test
// -----------------------------------------------------------------------------
class ddr2_random_full_system_stress_test extends uvm_test;

  `uvm_component_utils(ddr2_random_full_system_stress_test)

  ddr2_env env;
  ddr2_random_stress_seq seq;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = ddr2_env::type_id::create("env", this);
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this, "Starting ddr2_random_full_system_stress_test");

    seq = ddr2_random_stress_seq::type_id::create("seq");
    seq.num_txn = 128;
    seq.addr_min = 25'd0;
    seq.addr_max = 25'd1023;
    seq.start(env.seqr);

    // Allow time for all random transactions to complete
    #500000;

    `uvm_info(get_type_name(), "Random full system stress test completed", UVM_MEDIUM)
    phase.drop_objection(this, "Completed ddr2_random_full_system_stress_test");
  endtask

endclass

