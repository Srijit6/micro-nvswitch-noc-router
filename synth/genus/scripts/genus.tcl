# ==============================================================================
# Project Micro-NVSwitch: Rubin-Class High-Radix NoC Router for AI Fabrics
# File: genus.tcl
# Description: Cadence Genus Ultra-High Frequency Synthesis Script
#              Pushes design to Fmax (1.25 GHz / 800 ps) on ASAP7 7nm FinFET PDK.
# ==============================================================================

set_db / .information_level 7
set_db / .threads 8

set DESIGN "router_top"
set PDK_DIR [expr {[info exists env(PDK_ROOT)] ? $env(PDK_ROOT) : "/opt/pdk/asap7"}]

# ------------------------------------------------------------------------------
# Target Library Setup (ASAP7 7nm FinFET)
# ------------------------------------------------------------------------------
set_db init_lib_search_path [list \
    "${PDK_DIR}/asap7sc7p5t_28/LIB/NLDM" \
    "${PDK_DIR}/asap7sc7p5t_28/LIB/CCS" \
    "../../constraints" \
]

set_db target_library [list \
    "asap7sc7p5t_AO_RVT_TT_08302018.lib" \
    "asap7sc7p5t_OA_RVT_TT_08302018.lib" \
    "asap7sc7p5t_INVBUF_RVT_TT_08302018.lib" \
    "asap7sc7p5t_SIMPLE_RVT_TT_08302018.lib" \
    "asap7sc7p5t_SEQ_RVT_TT_08302018.lib" \
]

set_db link_library [get_db target_library]

# ------------------------------------------------------------------------------
# Read HDL Design Files
# ------------------------------------------------------------------------------
set_db init_hdl_search_path [list "../../rtl/include" "../../rtl/blocks" "../../rtl/top"]

read_hdl -language v2001 [list \
    "router_pkg.v" \
    "vc_buffer.v" \
    "islip_arbiter.v" \
    "crossbar_8x8.v" \
    "sharp_alu.v" \
    "router_top.v" \
]

# Elaborate
elaborate $DESIGN
check_design -unresolved

# ------------------------------------------------------------------------------
# Constraints & Low-Power Intent
# ------------------------------------------------------------------------------
read_sdc "../../constraints/router.sdc"

if {[file exists "../../constraints/power.cpf"]} {
    read_power_intent -cpf "../../constraints/power.cpf"
    apply_power_intent
}

# ------------------------------------------------------------------------------
# High-Frequency Optimization Settings (The NVIDIA Signal)
# ------------------------------------------------------------------------------
# Crossbar Switch Allocation Pipelining & Retiming
set_db [get_db modules crossbar_8x8] .retime true
set_db [get_db modules islip_arbiter] .retime true
set_db / .retime_async_reset true

# Aggressive Datapath Optimization
set_db / .optimize_constant_0_flops true
set_db / .optimize_constant_1_flops true
set_db / .delete_unloaded_seqs true

# ------------------------------------------------------------------------------
# Synthesis Execution: Generic -> Mapping -> Optimization
# ------------------------------------------------------------------------------
syn_generic -effort high
syn_map -effort high
syn_opt -effort high

# Incremental timing closure push
syn_opt -incremental -effort high

# ------------------------------------------------------------------------------
# Sign-Off Reports Generation
# ------------------------------------------------------------------------------
file mkdir ../reports
file mkdir ../mapped

report_timing -unconstrained > ../reports/timing_unconstrained.rpt
report_timing -max_paths 50  > ../reports/timing_worst_paths.rpt
report_area -depth 3         > ../reports/area_hierarchical.rpt
report_power -detail         > ../reports/power_breakdown.rpt
report_gates                 > ../reports/gate_summary.rpt
report_qor                   > ../reports/qor_summary.rpt

# ------------------------------------------------------------------------------
# Export Database
# ------------------------------------------------------------------------------
write_hdl > ../mapped/${DESIGN}_genus.v
write_sdc > ../mapped/${DESIGN}_genus.sdc

puts "Genus synthesis complete for ${DESIGN}."
