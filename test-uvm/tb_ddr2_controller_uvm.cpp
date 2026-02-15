// C++ wrapper for Verilator + UVM testbench
// This file provides the main() function that initializes Verilator and runs UVM
//
// IMPORTANT NOTE: Verilator has LIMITED support for UVM. The UVM-2017 reference
// implementation uses dynamic SystemVerilog classes and features that Verilator
// may not fully support. For production UVM verification, use commercial simulators
// like VCS, Questa, or Xcelium.

#include <verilated.h>
#if VM_TRACE
#include <verilated_vcd_c.h>
#endif
#include "Vtb_ddr2_controller_uvm.h"

vluint64_t main_time = 0;  // Current simulation time

double sc_time_stamp() {
    return main_time;  // Convert to double, units are in picoseconds
}

int main(int argc, char** argv) {
    // Initialize Verilator
    Verilated::commandArgs(argc, argv);
    Verilated::debug(0);
    
    // Create instance of the top module
    Vtb_ddr2_controller_uvm* top = new Vtb_ddr2_controller_uvm;
    
#if VM_TRACE
    // If tracing is enabled, create trace file
    VerilatedVcdC* tfp = new VerilatedVcdC;
    Verilated::traceEverOn(true);
    top->trace(tfp, 99);
    tfp->open("tb_ddr2_controller_uvm.vcd");
#endif
    
    // Initialize simulation
    top->eval();
    
    // The SystemVerilog code in tb_ddr2_controller_uvm.sv calls run_test()
    // in an initial block. This should execute during the first eval().
    // UVM requires a simulation loop to advance time and execute phases.
    
    // Run simulation until $finish is called or timeout.
    // Pass +UVM_TESTNAME=<name> on command line to select test (e.g. ddr2_scalar_rw_basic_test).
    const vluint64_t max_time = 1000000000;  // 1e9 ns = 1 s timeout; increase for long stress tests
    
    while (!Verilated::gotFinish() && main_time < max_time) {
        // Evaluate model
        top->eval();
        
#if VM_TRACE
        if (tfp) tfp->dump(main_time);
#endif
        
        // Advance time (1ns per step, matching timescale 1ns/1ps)
        main_time += 1;
    }
    
    int exit_code = 0;
    if (main_time >= max_time) {
        VL_PRINTF("ERROR: Simulation timeout reached at %" VL_PRI64 "u ns\n", (vluint64_t)main_time);
        exit_code = 1;
    }
    
    // Final model evaluation
    top->final();
    
#if VM_TRACE
    if (tfp) {
        tfp->close();
        delete tfp;
    }
#endif
    
    // Cleanup
    delete top;
    
    return exit_code;
}
