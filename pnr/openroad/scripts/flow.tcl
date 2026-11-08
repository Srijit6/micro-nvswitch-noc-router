# ==============================================================================
# Project Micro-NVSwitch: Rubin-Class High-Radix NoC Router for AI Fabrics
# File: flow.tcl
# Description: OpenROAD Automated Physical Implementation Flow for ASAP7 (7nm)
# Stages:
# 1. Floorplanning & Pin Placement
# 2. Power Distribution Network (PDN) Synthesis
# 3. Global Placement (RePlAce)
# 4. Clock Tree Synthesis (TritonCTS)
# 5. Global Routing (FastRoute)
# 6. Detailed Routing (TritonRoute)
# 7. Static Timing Analysis (OpenSTA Sign-Off)
# ==============================================================================

set DESIGN_NAME "router_top"
set PDK_DIR [expr {[info exists env(PDK_ROOT)] ? $env(PDK_ROOT) : "/opt/pdk/asap7"}]

# Load Tech LEF and Cell LEF
read_lef "${PDK_DIR}/asap7sc7p5t_28/LEF/asap7_tech_4x.lef"
read_lef "${PDK_DIR}/asap7sc7p5t_28/LEF/asap7sc7p5t_28_R_4x.lef"

# Read Gate-Level Netlist from Synthesis
read_verilog "../../synth/yosys/mapped/router_top_synth.v"
link_design $DESIGN_NAME

# Read SDC Constraints
read_sdc "../../constraints/router.sdc"

# ------------------------------------------------------------------------------
# 1. Floorplan Initialization
# ------------------------------------------------------------------------------
initialize_floorplan \
    -die_area {0 0 200 200} \
    -core_area {10 10 190 190} \
    -site Site_75t

# Read Pre-routed I/O Pins & Floorplan DEF
read_def "floorplan.def"

# ------------------------------------------------------------------------------
# 2. Power Distribution Network (PDN)
# ------------------------------------------------------------------------------
pdngen -verbose

# ------------------------------------------------------------------------------
# 3. Global Placement (RePlAce) with Congestion Padding
# ------------------------------------------------------------------------------
set_wire_rc -layer M3
global_placement -density 0.65 -pad_left 2 -pad_right 2

# Estimate Parasitics & Buffer High-Fanout Nets
estimate_parasitics -placement
repair_design
repair_tie_fanout -separation 50

# Detail Placement
detailed_placement
check_placement

# ------------------------------------------------------------------------------
# 4. Clock Tree Synthesis (TritonCTS)
# ------------------------------------------------------------------------------
clock_tree_synthesis \
    -buf_list {BUFx2_ASAP7_75t_R BUFx4_ASAP7_75t_R BUFx8_ASAP7_75t_R} \
    -root_buf BUFx8_ASAP7_75t_R \
    -max_skew 30 \
    -max_slew 25

repair_clock_nets
detailed_placement

# ------------------------------------------------------------------------------
# 5. Global Routing (FastRoute)
# ------------------------------------------------------------------------------
set_global_routing_layer_adjustment M1-M3 0.5
set_global_routing_layer_adjustment M4-M8 0.1
global_route -guide_file "route.guide" -congestion_iterations 50

# ------------------------------------------------------------------------------
# 6. Detailed Routing (TritonRoute)
# ------------------------------------------------------------------------------
detailed_route -guide "route.guide" -output_drc "reports/drc.rpt"

# ------------------------------------------------------------------------------
# 7. Sign-Off STA & DRC (OpenSTA)
# ------------------------------------------------------------------------------
file mkdir reports
file mkdir outputs

estimate_parasitics -spef "outputs/${DESIGN_NAME}.spef"
report_checks -path_delay min_max -fields {input_pin slew cap delay} -digits 3 > reports/sta_timing.rpt
report_power > reports/sta_power.rpt
report_design_area > reports/area.rpt

# Export Final PnR DEF & GDS
write_def "outputs/${DESIGN_NAME}_pnr.def"
write_verilog "outputs/${DESIGN_NAME}_pnr.v"

puts "OpenROAD Physical Implementation Flow complete."
