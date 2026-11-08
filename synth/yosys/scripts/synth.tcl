# ==============================================================================
# Project Micro-NVSwitch: Rubin-Class High-Radix NoC Router for AI Fabrics
# File: synth.tcl
# Description: Tcl launcher for Yosys Synthesis
# ==============================================================================

file mkdir ../yosys/mapped
file mkdir ../yosys/reports

# Execute Yosys script
yosys read_verilog -I../../rtl/include ../../rtl/include/router_pkg.v
yosys read_verilog -I../../rtl/include ../../rtl/blocks/vc_buffer.v
yosys read_verilog -I../../rtl/include ../../rtl/blocks/islip_arbiter.v
yosys read_verilog -I../../rtl/include ../../rtl/blocks/crossbar_8x8.v
yosys read_verilog -I../../rtl/include ../../rtl/blocks/sharp_alu.v
yosys read_verilog -I../../rtl/include ../../rtl/top/router_top.v

yosys hierarchy -check -top router_top
yosys synth -top router_top
yosys tee -o ../yosys/reports/synth_stat.rpt stat
yosys tee -o ../yosys/reports/synth_check.rpt check
yosys write_verilog -noattr ../yosys/mapped/router_top_synth.v
yosys write_json ../yosys/mapped/router_top_synth.json
