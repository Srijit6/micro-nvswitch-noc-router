# ==============================================================================
# Project Micro-NVSwitch: ASAP7 platform settings for the open-source flow
# Sourced by flow/run_flow.sh inside the OpenLane2 container (yosys/openroad/sta)
# ==============================================================================
export DESIGN_NAME=router_top
export PLATFORM_DIR=${PLATFORM_DIR:-/pdk/asap7}
export LIB_DIR=${LIB_DIR:-/work/build/lib}         # un-gzipped TT/RVT liberty files

export TECH_LEF=$PLATFORM_DIR/lef/asap7_tech_1x_201209.lef
export SC_LEF=$PLATFORM_DIR/lef/asap7sc7p5t_28_R_1x_220121a.lef
export GDS_FILE=$PLATFORM_DIR/gds/asap7sc7p5t_28_R_220121a.gds

# Typical corner, RVT (0.70 V, 0 C)
export LIB_FILES="$LIB_DIR/asap7sc7p5t_AO_RVT_TT_nldm_211120.lib \
$LIB_DIR/asap7sc7p5t_INVBUF_RVT_TT_nldm_220122.lib \
$LIB_DIR/asap7sc7p5t_OA_RVT_TT_nldm_211120.lib \
$LIB_DIR/asap7sc7p5t_SIMPLE_RVT_TT_nldm_211120.lib \
$LIB_DIR/asap7sc7p5t_SEQ_RVT_TT_nldm_220123.lib"

export DONT_USE_CELLS="*x1p*_ASAP7* *xp*_ASAP7* SDF* ICG*"
export TIEHI_CELL=TIEHIx1_ASAP7_75t_R
export TIELO_CELL=TIELOx1_ASAP7_75t_R
export MIN_BUF_CELL=BUFx2_ASAP7_75t_R
export TAP_CELL_NAME=TAPCELL_ASAP7_75t_R
export FILL_CELLS="FILLERxp5_ASAP7_75t_R FILLER_ASAP7_75t_R DECAPx1_ASAP7_75t_R DECAPx2_ASAP7_75t_R DECAPx4_ASAP7_75t_R DECAPx6_ASAP7_75t_R DECAPx10_ASAP7_75t_R"
export PLACE_SITE=asap7sc7p5t

export CLOCK_PERIOD_PS=2500
export CORE_UTILIZATION=${CORE_UTILIZATION:-45}
export PLACE_DENSITY=${PLACE_DENSITY:-0.60}
export MIN_ROUTING_LAYER=M2
export MAX_ROUTING_LAYER=M7
export MIN_CLK_ROUTING_LAYER=M4
export ROUTING_LAYER_ADJUSTMENT=0.25
export MACRO_ROWS_HALO_X=2
export MACRO_ROWS_HALO_Y=2

# Host has ~3 GB RAM: keep detailed-router threads low to bound memory.
export NUM_THREADS=${NUM_THREADS:-3}

export SDC_FILE=/work/constraints/router_openroad.sdc
export SYNTH_NETLIST=/work/synth/yosys/mapped/router_top_asap7.v
export PNR_DIR=/work/pnr/openroad
export STA_DIR=/work/signoff/sta
