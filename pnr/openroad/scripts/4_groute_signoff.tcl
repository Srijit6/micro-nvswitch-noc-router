# ==============================================================================
# Stage 4 (low-memory path): global routing only, no detailed routing.
# Detailed routing needs > 3.7 GB for this design (OOM-killed in WSL), so the
# layout stops at FastRoute guides; parasitics are estimated from global routes.
# Outputs feed signoff/sta/sta.tcl and the GUI.
# ==============================================================================
source /work/pnr/openroad/scripts/common.tcl
load_stage $ODB/3_cts.odb $ODB/3_cts.sdc
set_propagated_clock [all_clocks]

source $PDK/fastroute.tcl
global_route -congestion_iterations 50 -allow_congestion \
    -congestion_report_file $RPT/congestion.rpt -verbose

filler_placement [regexp -all -inline {\S+} $::env(FILL_CELLS)]

# OpenROAD appends the corner name: writes ${DESIGN}_groute_default.spef
estimate_parasitics -global_routing -spef_file $OUT/${DESIGN}_groute.spef

# Save before reporting so a report error cannot lose the run
write_db      $ODB/4_groute.odb
write_guides  $OUT/${DESIGN}_route.guide
write_def     $OUT/${DESIGN}_groute.def
write_verilog $OUT/${DESIGN}_groute.v
write_sdc     $OUT/${DESIGN}_groute.sdc

report_checks -path_delay max -fields {slew cap input_pins fanout} -digits 2 > $RPT/groute_setup.rpt
report_checks -path_delay min -fields {slew cap input_pins fanout} -digits 2 > $RPT/groute_hold.rpt
timing_summary 4_groute
puts "STAGE groute complete"
