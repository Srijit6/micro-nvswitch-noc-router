# Open the layout in the OpenROAD GUI with timing loaded.
# Uses the detailed-routed design if it exists, else the global-routed one.
source /work/pnr/openroad/scripts/common.tcl
load_libs
if {[file exists $ODB/5_final.odb]} {
    read_db $ODB/5_final.odb
    read_sdc $OUT/${DESIGN}_final.sdc
    post_load
    set_propagated_clock [all_clocks]
    read_spef $OUT/${DESIGN}.spef
} else {
    read_db $ODB/4_groute.odb
    read_sdc $OUT/${DESIGN}_groute.sdc
    post_load
    set_propagated_clock [all_clocks]
    read_spef $OUT/${DESIGN}_groute_fixed.spef
    # Show FastRoute guides (no detailed wires exist in this view)
    catch {read_guides $OUT/${DESIGN}_route.guide}
}
gui::fit
