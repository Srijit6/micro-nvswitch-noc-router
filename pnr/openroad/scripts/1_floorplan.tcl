# ==============================================================================
# Stage 1: Floorplan, IO placement, tapcells, PDN
# ==============================================================================
source /work/pnr/openroad/scripts/common.tcl

load_libs
load_lefs
read_verilog $::env(SYNTH_NETLIST)
link_design $DESIGN
read_sdc $::env(SDC_FILE)
post_load

# Square core sized from cell area and target utilization
initialize_floorplan \
    -utilization $::env(CORE_UTILIZATION) \
    -aspect_ratio 1.0 \
    -core_space 4 \
    -site $::env(PLACE_SITE)
source $PDK/openRoad/make_tracks.tcl

# Remove buffers yosys inserted for assigns; resizer will rebuffer properly
remove_buffers

source $PDK/openRoad/tapcell.tcl

# 1395 IO bits: horizontal pins on M4, vertical on M5, spread on all sides
place_pins -hor_layers M4 -ver_layers M5 -min_distance 0.2

source $PDK/openRoad/pdn/global_connect.tcl
source $PDK/openRoad/pdn/grid_strategy-M1-M2-M5-M6.tcl
pdngen

report_design_area
save_stage 1_floorplan
puts "STAGE floorplan complete"
