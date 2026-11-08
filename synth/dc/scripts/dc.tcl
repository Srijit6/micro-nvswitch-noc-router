# ==============================================================================
# Project Micro-NVSwitch: Rubin-Class High-Radix NoC Router for AI Fabrics
# File: dc.tcl
# Description: Synopsys Design Compiler (DC Topographical) Synthesis Script
# ==============================================================================

set target_library [list "asap7sc7p5t_AO_RVT_TT_08302018.db" "asap7sc7p5t_SEQ_RVT_TT_08302018.db"]
set link_library [concat "*" $target_library]

set search_path [list "." "../../rtl/include" "../../rtl/blocks" "../../rtl/top" "../../constraints"]

define_design_lib WORK -path ./WORK

# Analyze & Elaborate
analyze -format verilog [list "router_pkg.v" "vc_buffer.v" "islip_arbiter.v" "crossbar_8x8.v" "sharp_alu.v" "router_top.v"]
elaborate router_top

current_design router_top
link
check_design

# Read Constraints
read_sdc "../../constraints/router.sdc"

# Retiming for Crossbar & Arbiter
set_optimize_registers true -designs [list "crossbar_8x8" "islip_arbiter"]

# Compile Ultra with boundary optimization
compile_ultra -retime -gate_clock

# Reports
file mkdir ../reports
file mkdir ../mapped

report_timing -delay max > ../reports/timing_dc.rpt
report_area -hierarchy   > ../reports/area_dc.rpt
report_power             > ../reports/power_dc.rpt

write -format verilog -hierarchy -output ../mapped/router_top_dc.v
write_sdc ../mapped/router_top_dc.sdc

exit
