#!/usr/bin/env bash
# Run Verilator + UVM-2017 simulation for ddr2_controller UVM testbench.
# Uses IEEE UVM-2017 reference implementation under tools/uvm-2017.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DUT="$PROJECT_ROOT/dut"
TEST_UVM="$PROJECT_ROOT/test-uvm"
TOOLS="$PROJECT_ROOT/tools"
BUILD="${BUILD:-$PROJECT_ROOT/build-uvm}"

mkdir -p "$BUILD"
cd "$BUILD"

echo "Compiling DUT and UVM testbench with Verilator..."

UVM_ROOT="$TOOLS/uvm-2017/1800.2-2017-1.0"
UVM_SRC="$UVM_ROOT/src"

if [ ! -d "$UVM_ROOT" ]; then
  echo "ERROR: UVM-2017 directory not found at $UVM_ROOT" >&2
  exit 1
fi

TEST_DIR="$PROJECT_ROOT/test"

# Basic Verilator compile; adjust options as needed for tracing or coverage.
# Note: --top-module specifies the top-level module name (without the 'V' prefix)
verilator -Wall --timing --error-limit 0 -Wno-fatal \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -Wno-UNDRIVEN -Wno-UNUSEDSIGNAL \
  -Wno-IMPORTSTAR -Wno-DECLFILENAME \
  -Wno-MODDUP -Wno-PINCONNECTEMPTY \
  -Wno-TIMESCALEMOD -Wno-EOFNEWLINE \
  -Wno-VARHIDDEN -Wno-UNUSEDPARAM -Wno-COVERIGN -Wno-CASEOVERLAP \
  --cc --exe --build \
  --top-module tb_ddr2_controller_uvm \
  -sv \
  -I"$UVM_SRC" \
  -I"$TEST_UVM" \
  -I"$TEST_DIR" \
  -I"$PROJECT_ROOT/test" \
  "$UVM_SRC/uvm_pkg.sv" \
  "$DUT/fifo.v" \
  "$DUT/ddr2_init_engine.v" \
  "$DUT/ddr2_ring_buffer8.v" \
  "$DUT/ddr2_phy.v" \
  "$DUT/ddr2_protocol_engine.v" \
  "$DUT/ddr2_controller.v" \
  "$TEST_DIR/ddr2_simple_mem.v" \
  "$TEST_DIR/ddr2_fifo_monitor.v" \
  "$TEST_DIR/ddr2_refresh_monitor.v" \
  "$TEST_DIR/ddr2_timing_checker.v" \
  "$TEST_DIR/ddr2_turnaround_checker.v" \
  "$TEST_DIR/ddr2_bank_checker.v" \
  "$TEST_DIR/ddr2_dqs_monitor.v" \
  "$TEST_UVM/tb_ddr2_controller_uvm.sv" \
  "$TEST_UVM/tb_ddr2_controller_uvm.cpp" \
  "$UVM_SRC/dpi/uvm_dpi.cc" || {
  echo "WARNING: Verilator returned non-zero exit code. Checking if executable was created..." >&2
}

EXECUTABLE="$BUILD/obj_dir/Vtb_ddr2_controller_uvm"
if [ ! -f "$EXECUTABLE" ]; then
  echo "ERROR: Executable not found at $EXECUTABLE" >&2
  echo "Build may have failed. Check the Verilator output above for errors." >&2
  exit 1
fi

if [ ! -x "$EXECUTABLE" ]; then
  echo "WARNING: Executable exists but is not executable. Fixing permissions..." >&2
  chmod +x "$EXECUTABLE"
fi

echo ""
echo "Verilator build completed."
echo ""

# Run the simulation unless BUILD_ONLY=1 (e.g. BUILD_ONLY=1 ./run_tb.sh to only build)
# Optional: pass test name via UVM_TESTNAME, e.g.:
#   UVM_TESTNAME=ddr2_scalar_rw_basic_test ./run_tb.sh
if [ "${BUILD_ONLY:-0}" = "1" ]; then
  echo "Build only (BUILD_ONLY=1). To run the simulation:"
  echo "  cd $BUILD"
  echo "  ./obj_dir/Vtb_ddr2_controller_uvm [ +UVM_TESTNAME=<test_name> ]"
  echo "  Examples: +UVM_TESTNAME=ddr2_smoke_test  +UVM_TESTNAME=ddr2_scalar_rw_basic_test"
else
  echo "Running simulation..."
  RUN_ARGS=()
  [ -n "${UVM_TESTNAME:-}" ] && RUN_ARGS+=( "+UVM_TESTNAME=$UVM_TESTNAME" )
  ( cd "$BUILD" && ./obj_dir/Vtb_ddr2_controller_uvm "${RUN_ARGS[@]}" ) || {
    echo "WARNING: Simulation exited with non-zero status." >&2
    exit 1
  }
fi

echo ""
echo "Note: Verilator has limited support for UVM. The UVM-2017 reference"
echo "implementation may not work fully with Verilator due to dynamic class"
echo "features. For full UVM support, consider using commercial simulators like"
echo "VCS, Questa, or Xcelium."

