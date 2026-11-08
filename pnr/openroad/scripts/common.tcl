# ==============================================================================
# Project Micro-NVSwitch: shared OpenROAD setup for ASAP7 (sourced by each stage)
# ==============================================================================
set DESIGN  $::env(DESIGN_NAME)
set PDK     $::env(PLATFORM_DIR)
set ODB     /work/build/odb
set RPT     $::env(PNR_DIR)/reports
set OUT     $::env(PNR_DIR)/outputs
file mkdir $ODB $RPT $OUT

source $PDK/liberty_suppressions.tcl

proc load_libs {} {
    foreach l [regexp -all -inline {\S+} $::env(LIB_FILES)] { read_liberty $l }
}

proc load_lefs {} {
    read_lef $::env(TECH_LEF)
    read_lef $::env(SC_LEF)
}

# Load the previous stage checkpoint with libraries and constraints
proc load_stage {odb {sdc ""}} {
    load_libs
    read_db $odb
    if {$sdc eq ""} { set sdc $::env(SDC_FILE) }
    read_sdc $sdc
    post_load
}

proc post_load {} {
    source $::env(PLATFORM_DIR)/setRC.tcl
    set_dont_use [regexp -all -inline {\S+} $::env(DONT_USE_CELLS)]
}

proc save_stage {name} {
    write_db $::ODB/${name}.odb
    write_sdc $::ODB/${name}.sdc
}

proc timing_summary {tag} {
    set f [open $::RPT/${tag}_summary.rpt w]
    puts $f "=== $tag ==="
    puts $f "WNS (setup): [sta::format_time [sta::worst_slack_cmd max] 3] ps"
    puts $f "TNS (setup): [sta::format_time [sta::total_negative_slack_cmd max] 3] ps"
    puts $f "WNS (hold) : [sta::format_time [sta::worst_slack_cmd min] 3] ps"
    puts $f [design_area_str]
    close $f
    puts "[exec cat $::RPT/${tag}_summary.rpt]"
}

# Cell area / core utilization straight from the odb (rsz::design_area segfaults
# when the resizer has not been initialised in the current stage)
proc design_area_str {} {
    set block [ord::get_db_block]
    set dbu [$block getDefUnits]
    set area 0.0
    foreach inst [$block getInsts] {
        set m [$inst getMaster]
        if {[$m getType] eq "CORE_SPACER" || [string match "TAPCELL*" [$m getName]]} { continue }
        set area [expr {$area + double([$m getWidth]) * [$m getHeight] / ($dbu * $dbu)}]
    }
    set core [$block getCoreArea]
    set core_area [expr {double([$core dx]) * [$core dy] / ($dbu * $dbu)}]
    return [format "Design area: %.0f um^2  util %.1f%%" $area [expr {100.0 * $area / $core_area}]]
}
