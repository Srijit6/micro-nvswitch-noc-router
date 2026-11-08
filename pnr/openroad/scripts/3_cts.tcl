# ==============================================================================
# Stage 3: Clock tree synthesis + post-CTS setup/hold repair
# ==============================================================================
source /work/pnr/openroad/scripts/common.tcl
load_stage $ODB/2_place.odb $ODB/2_place.sdc

set_routing_layers -clock $::env(MIN_CLK_ROUTING_LAYER)-$::env(MAX_ROUTING_LAYER)
set_routing_layers -signal $::env(MIN_ROUTING_LAYER)-$::env(MAX_ROUTING_LAYER)

clock_tree_synthesis \
    -root_buf BUFx4_ASAP7_75t_R \
    -buf_list {BUFx4_ASAP7_75t_R BUFx8_ASAP7_75t_R BUFx12f_ASAP7_75t_R} \
    -sink_clustering_enable

set_propagated_clock [all_clocks]
estimate_parasitics -placement
repair_clock_nets
detailed_placement

estimate_parasitics -placement
repair_timing -setup -skip_pin_swap
repair_timing -hold -hold_margin 5
detailed_placement
check_placement -verbose

estimate_parasitics -placement
save_stage 3_cts
report_cts -out_file $RPT/cts.rpt
report_clock_skew > $RPT/clock_skew.rpt
timing_summary 3_cts
puts "STAGE cts complete"
