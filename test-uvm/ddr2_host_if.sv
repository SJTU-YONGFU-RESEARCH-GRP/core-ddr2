`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// DDR2 host interface for UVM testbench
// -----------------------------------------------------------------------------
//
// This interface bundles the host-visible signals of `ddr2_controller` so that
// a UVM driver and monitor can connect via virtual interfaces.
//
// It is intentionally limited to the host side; the DDR2 device-level pins
// are connected directly in the top-level testbench.
//

interface ddr2_host_if (input logic CLK);

  // Host-side control and status
  logic        RESET;
  logic        INITDDR;
  logic [2:0]  CMD;
  logic [1:0]  SZ;
  logic [24:0] ADDR;
  logic        cmd_put;
  logic [15:0] DIN;
  logic        put_dataFIFO;
  logic        FETCHING;

  logic [15:0] DOUT;
  logic [24:0] RADDR;
  logic [6:0]  FILLCOUNT;
  logic        READY;
  logic        VALIDOUT;
  logic        NOTFULL;

  // Modport for the active driver (host agent)
  modport drv (
    input  CLK,
    output RESET,
    output INITDDR,
    output CMD,
    output SZ,
    output ADDR,
    output cmd_put,
    output DIN,
    output put_dataFIFO,
    output FETCHING,
    input  DOUT,
    input  RADDR,
    input  FILLCOUNT,
    input  READY,
    input  VALIDOUT,
    input  NOTFULL
  );

  // Modport for passive monitor / scoreboard
  modport mon (
    input CLK,
    input RESET,
    input INITDDR,
    input CMD,
    input SZ,
    input ADDR,
    input cmd_put,
    input DIN,
    input put_dataFIFO,
    input FETCHING,
    input DOUT,
    input RADDR,
    input FILLCOUNT,
    input READY,
    input VALIDOUT,
    input NOTFULL
  );

endinterface

