# ==============================================================================
# Stage 2: Global placement, design repair, detailed placement
# ==============================================================================
source /work/pnr/openroad/scripts/common.tcl
load_stage $ODB/1_floorplan.odb $ODB/1_floorplan.sdc

global_placement -density $::env(PLACE_DENSITY) -pad_left 1 -pad_right 1 \
    -timing_driven -routability_driven

estimate_parasitics -placement
repair_design
repair_tie_fanout -separation 2 TIEHIx1_ASAP7_75t_R/H
repair_tie_fanout -separation 2 TIELOx1_ASAP7_75t_R/L

detailed_placement
optimize_mirroring
check_placement -verbose

estimate_parasitics -placement
timing_summary 2_place
save_stage 2_place
puts "STAGE place complete"
