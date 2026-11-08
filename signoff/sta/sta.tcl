# ==============================================================================
# Project Micro-NVSwitch: OpenSTA sign-off on the routed netlist + OpenRCX SPEF
# ASAP7 RVT TT corner, clock period from CLOCK_PERIOD_PS
# ==============================================================================
set DESIGN $::env(DESIGN_NAME)
set PNR    $::env(PNR_DIR)/outputs
set RPT    $::env(STA_DIR)/reports
file mkdir $RPT

catch {suppress_message STA 1212}   ;# OpenROAD-only command; standalone OpenSTA lacks it
foreach l [regexp -all -inline {\S+} $::env(LIB_FILES)] { read_liberty $l }
# STA_VIEW = final (detailed route + RCX) or groute (global route estimate)
set VIEW [expr {[info exists ::env(STA_VIEW)] ? $::env(STA_VIEW) : "final"}]
set SPEF [expr {$VIEW eq "final" ? "$PNR/${DESIGN}.spef" : "$PNR/${DESIGN}_groute_fixed.spef"}]
read_verilog $PNR/${DESIGN}_${VIEW}.v
link_design $DESIGN
read_sdc $PNR/${DESIGN}_${VIEW}.sdc
set_propagated_clock [all_clocks]
read_spef $SPEF

report_checks -path_delay max -group_count 10 -fields {slew cap input_pins nets fanout} -digits 2 > $RPT/setup.rpt
report_checks -path_delay min -group_count 10 -fields {slew cap input_pins nets fanout} -digits 2 > $RPT/hold.rpt
report_check_types -max_slew -max_capacitance -max_fanout -violators > $RPT/drv.rpt
report_clock_skew > $RPT/clock_skew.rpt
report_power > $RPT/power.rpt

set wns_s [worst_slack -max]
set wns_h [worst_slack -min]
set tns_s [total_negative_slack -max]
set tns_h [total_negative_slack -min]
# Fmax from the worst reg-to-reg/IO path: period minus setup slack
set fmax  [expr {1e6 / ($::env(CLOCK_PERIOD_PS) - $wns_s)}]

set f [open $RPT/summary.rpt w]
puts $f "Micro-NVSwitch router_top  |  ASAP7 RVT TT  |  clk $::env(CLOCK_PERIOD_PS) ps  |  parasitics: $VIEW"
puts $f [format "Setup WNS %8.2f ps   TNS %10.2f ps" $wns_s $tns_s]
puts $f [format "Hold  WNS %8.2f ps   TNS %10.2f ps" $wns_h $tns_h]
puts $f [format "Achievable Fmax ~ %.0f MHz" $fmax]
close $f
puts [exec cat $RPT/summary.rpt]
