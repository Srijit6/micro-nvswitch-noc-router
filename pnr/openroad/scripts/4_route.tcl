# ==============================================================================
# Stage 4: Global routing (FastRoute) + detailed routing (TritonRoute)
# ==============================================================================
source /work/pnr/openroad/scripts/common.tcl
load_stage $ODB/3_cts.odb $ODB/3_cts.sdc
set_propagated_clock [all_clocks]

source $PDK/fastroute.tcl
global_route -congestion_iterations 50 -allow_congestion \
    -congestion_report_file $RPT/congestion.rpt -verbose

estimate_parasitics -global_routing
timing_summary 4_groute

set_thread_count $::env(NUM_THREADS)
detailed_route \
    -bottom_routing_layer $::env(MIN_ROUTING_LAYER) \
    -top_routing_layer $::env(MAX_ROUTING_LAYER) \
    -output_drc $RPT/drc_route.rpt \
    -droute_end_iter 30 \
    -save_guide_updates \
    -verbose 1

save_stage 4_route
puts "STAGE route complete"
