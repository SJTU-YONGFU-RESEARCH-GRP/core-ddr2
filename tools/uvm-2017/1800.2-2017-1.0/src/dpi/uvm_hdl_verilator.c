//----------------------------------------------------------------------
// Minimal UVM HDL backdoor stub for Verilator
//
// The IEEE UVM-2017 reference implementation expects a vendor-specific
// HDL access backend (VCS/Questa/Xcelium) to be selected in `uvm_hdl.c`.
// Verilator does not provide a compatible VPI/FLI/VHPI backend for these
// implementations, so attempting to compile them will fail.
//
// This file provides a stub implementation of the UVM HDL access API that
// simply reports failure for all operations. This is sufficient for
// environments that do not rely on UVM backdoor access and allows the
// rest of UVM to compile and run under Verilator.
//
// If a test attempts backdoor operations, they will return 0 and UVM
// should fall back to front-door accesses where supported.
//----------------------------------------------------------------------

#include "uvm_dpi.h"

// All functions intentionally implemented as no-ops that report failure.
// They satisfy the linker requirements without tying into any simulator
// specific HDL access layer.

int uvm_hdl_check_path(char *path)
{
  (void)path;
  return 0;
}

int uvm_hdl_read(char *path, p_vpi_vecval value)
{
  (void)path;
  (void)value;
  return 0;
}

int uvm_hdl_deposit(char *path, p_vpi_vecval value)
{
  (void)path;
  (void)value;
  return 0;
}

int uvm_hdl_force(char *path, p_vpi_vecval value)
{
  (void)path;
  (void)value;
  return 0;
}

int uvm_hdl_release_and_read(char *path, p_vpi_vecval value)
{
  (void)path;
  (void)value;
  return 0;
}

int uvm_hdl_release(char *path)
{
  (void)path;
  return 0;
}

