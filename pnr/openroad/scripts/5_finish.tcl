# ==============================================================================
# Stage 5: Fillers, RC extraction (OpenRCX), final reports and outputs
# ==============================================================================
source /work/pnr/openroad/scripts/common.tcl
load_stage $ODB/4_route.odb $ODB/4_route.sdc
set_propagated_clock [all_clocks]

filler_placement [regexp -all -inline {\S+} $::env(FILL_CELLS)]
check_placement

define_process_corner -ext_model_index 0 X
extract_parasitics -ext_model_file $PDK/rcx_patterns.rules
write_spef $OUT/${DESIGN}.spef
read_spef $OUT/${DESIGN}.spef

# Save outputs before reporting so a report error cannot lose the run
write_db      $ODB/5_final.odb
write_def     $OUT/${DESIGN}_final.def
write_verilog $OUT/${DESIGN}_final.v
write_sdc     $OUT/${DESIGN}_final.sdc


report_checks -path_delay max -fields {slew cap input_pins fanout} -digits 2 > $RPT/final_setup.rpt
report_checks -path_delay min -fields {slew cap input_pins fanout} -digits 2 > $RPT/final_hold.rpt
report_power > $RPT/final_power.rpt
timing_summary 5_final

puts "STAGE finish complete"
