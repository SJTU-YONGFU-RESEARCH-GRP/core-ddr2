`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// UVM-based testbench for `ddr2_controller`
// -----------------------------------------------------------------------------
//
// This top-level testbench:
// - Instantiates the DDR2 controller DUT from `dut/ddr2_controller.v`
// - Instantiates a host interface `ddr2_host_if`
// - (Placeholder) Instantiates the DDR2 memory model / PHY connections
// - Puts the virtual host interfaces into the UVM config DB
// - Calls run_test("ddr2_smoke_test") defined in `ddr2_tb_pkg.sv`
//

`include "uvm_macros.svh"
import uvm_pkg::*;

// Import the UVM components and host interface
`include "ddr2_host_if.sv"
`include "ddr2_tb_pkg.sv"

module tb_ddr2_controller_uvm;

  // Clock
  logic CLK;

  // Instantiate host interface; clock is driven from this testbench
  ddr2_host_if host_if (CLK);

  // DDR2 device pins (connect to PHY + memory model as needed)
  wire [1:0]   C0_CSBAR_PAD;  // 2 bits for RANK_BITS=1
  wire         C0_RASBAR_PAD;
  wire         C0_CASBAR_PAD;
  wire         C0_WEBAR_PAD;
  wire [1:0]   C0_BA_PAD;
  wire [12:0]  C0_A_PAD;
  wire [1:0]   C0_DM_PAD;
  wire         C0_ODT_PAD;
  wire         C0_CK_PAD;
  wire         C0_CKBAR_PAD;
  wire         C0_CKE_PAD;
  wire [15:0]  C0_DQ_PAD;
  wire [1:0]   C0_DQS_PAD;
  wire [1:0]   C0_DQSBAR_PAD;

  // Optional power/DLL status (DUT outputs; unused in this TB)
  wire         SELFREF_ACTIVE;
  wire         PWRDOWN_ACTIVE;
  wire         DLL_BUSY;

  // DUT instance
  ddr2_controller dut (
    .CLK          (CLK),
    .RESET        (host_if.RESET),
    .INITDDR      (host_if.INITDDR),
    .SELFREF_REQ  (1'b0),
    .SELFREF_EXIT (1'b0),
    .PWRDOWN_REQ  (1'b0),
    .PWRDOWN_EXIT (1'b0),
    .CMD          (host_if.CMD),
    .SZ           (host_if.SZ),
    .ADDR         (host_if.ADDR),
    .RANK_SEL     (1'b0),  // Single-rank configuration
    .cmd_put      (host_if.cmd_put),
    .DIN          (host_if.DIN),
    .put_dataFIFO (host_if.put_dataFIFO),
    .FETCHING     (host_if.FETCHING),
    .DLL_REQ      (1'b0),
    .DLL_MODE     (1'b0),
    .DOUT         (host_if.DOUT),
    .RADDR        (host_if.RADDR),
    .FILLCOUNT    (host_if.FILLCOUNT),
    .READY        (host_if.READY),
    .VALIDOUT     (host_if.VALIDOUT),
    .NOTFULL      (host_if.NOTFULL),
    .SELFREF_ACTIVE(SELFREF_ACTIVE),
    .PWRDOWN_ACTIVE(PWRDOWN_ACTIVE),
    .DLL_BUSY     (DLL_BUSY),
    .C0_CSBAR_PAD (C0_CSBAR_PAD),
    .C0_RASBAR_PAD(C0_RASBAR_PAD),
    .C0_CASBAR_PAD(C0_CASBAR_PAD),
    .C0_WEBAR_PAD (C0_WEBAR_PAD),
    .C0_BA_PAD    (C0_BA_PAD),
    .C0_A_PAD     (C0_A_PAD),
    .C0_DM_PAD    (C0_DM_PAD),
    .C0_ODT_PAD   (C0_ODT_PAD),
    .C0_CK_PAD    (C0_CK_PAD),
    .C0_CKBAR_PAD (C0_CKBAR_PAD),
    .C0_CKE_PAD   (C0_CKE_PAD),
    .C0_DQ_PAD    (C0_DQ_PAD),
    .C0_DQS_PAD   (C0_DQS_PAD),
    .C0_DQSBAR_PAD(C0_DQSBAR_PAD)
  );

  // DDR2 memory model: simple behavioral model for closed-loop validation
  wire        MEM_WR_VALID;
  wire [31:0] MEM_WR_ADDR;
  wire [15:0] MEM_WR_DATA;
  wire        MEM_RD_VALID;
  wire [31:0] MEM_RD_ADDR;
  wire [15:0] MEM_RD_DATA;

  ddr2_simple_mem #(
    .MEM_DEPTH(1024),
    .READ_LAT(24),
    .RANK_BITS(1)
  ) u_mem (
    .clk(CLK),
    .cke_pad(C0_CKE_PAD),
    .csbar_pad_vec(C0_CSBAR_PAD),
    .rasbar_pad(C0_RASBAR_PAD),
    .casbar_pad(C0_CASBAR_PAD),
    .webar_pad(C0_WEBAR_PAD),
    .ba_pad(C0_BA_PAD),
    .a_pad(C0_A_PAD),
    .dq_pad(C0_DQ_PAD),
    .dqs_pad(C0_DQS_PAD),
    .dqsbar_pad(C0_DQSBAR_PAD),
    .dbg_wr_valid(MEM_WR_VALID),
    .dbg_wr_addr(MEM_WR_ADDR),
    .dbg_wr_data(MEM_WR_DATA),
    .dbg_rd_valid(MEM_RD_VALID),
    .dbg_rd_addr(MEM_RD_ADDR),
    .dbg_rd_data(MEM_RD_DATA)
  );

  // Protocol and timing checkers
  ddr2_fifo_monitor u_fifo_mon (
    .clk(CLK),
    .reset(host_if.RESET),
    .fillcount(host_if.FILLCOUNT),
    .notfull(host_if.NOTFULL)
  );

  ddr2_refresh_monitor u_ref_mon (
    .clk(CLK),
    .reset(host_if.RESET),
    .ready_i(host_if.READY),
    .cke_pad(C0_CKE_PAD),
    .csbar_pad(&C0_CSBAR_PAD),  // AND-reduction for any-rank CS#
    .rasbar_pad(C0_RASBAR_PAD),
    .casbar_pad(C0_CASBAR_PAD),
    .webar_pad(C0_WEBAR_PAD)
  );

  ddr2_timing_checker u_timing_chk (
    .clk(CLK),
    .reset(host_if.RESET),
    .cke_pad(C0_CKE_PAD),
    .csbar_pad(&C0_CSBAR_PAD),
    .rasbar_pad(C0_RASBAR_PAD),
    .casbar_pad(C0_CASBAR_PAD),
    .webar_pad(C0_WEBAR_PAD),
    .ba_pad(C0_BA_PAD)
  );

  ddr2_turnaround_checker u_turnaround_chk (
    .clk(CLK),
    .reset(host_if.RESET),
    .cke_pad(C0_CKE_PAD),
    .csbar_pad_any(&C0_CSBAR_PAD),
    .rasbar_pad(C0_RASBAR_PAD),
    .casbar_pad(C0_CASBAR_PAD),
    .webar_pad(C0_WEBAR_PAD),
    .ba_pad(C0_BA_PAD)
  );

  ddr2_bank_checker u_bank_chk (
    .clk(CLK),
    .reset(host_if.RESET),
    .cke_pad(C0_CKE_PAD),
    .csbar_pad(&C0_CSBAR_PAD),
    .rasbar_pad(C0_RASBAR_PAD),
    .casbar_pad(C0_CASBAR_PAD),
    .webar_pad(C0_WEBAR_PAD),
    .ba_pad(C0_BA_PAD),
    .a_pad(C0_A_PAD)
  );

  ddr2_dqs_monitor u_dqs_mon (
    .clk(CLK),
    .reset(host_if.RESET),
    .cke_pad(C0_CKE_PAD),
    .csbar_pad(&C0_CSBAR_PAD),
    .rasbar_pad(C0_RASBAR_PAD),
    .casbar_pad(C0_CASBAR_PAD),
    .webar_pad(C0_WEBAR_PAD),
    .dqs_pad(C0_DQS_PAD)
  );

  // Clock generation: single controller clock; PHY handles DDR-level CK.
  initial begin
    CLK = 1'b0;
    forever #1 CLK = ~CLK; // 500 MHz nominal (2 ns period)
  end

  // UVM run: use +UVM_TESTNAME=<test_name> to select test; default is ddr2_smoke_test
  initial begin
    // Put virtual host interfaces into config DB
    uvm_config_db#(virtual ddr2_host_if.drv)::set(
      null, "uvm_test_top.env.drv", "vif_host_drv", host_if
    );
    uvm_config_db#(virtual ddr2_host_if.mon)::set(
      null, "uvm_test_top.env.mon", "vif_host_mon", host_if
    );

    if ($test$plusargs("UVM_TESTNAME"))
      run_test();
    else
      run_test("ddr2_smoke_test");
  end

endmodule

