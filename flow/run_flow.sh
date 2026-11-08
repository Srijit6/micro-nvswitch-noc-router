#!/usr/bin/env bash
# ==============================================================================
# Project Micro-NVSwitch: open-source RTL-to-layout flow on ASAP7
#   synth -> floorplan -> place -> cts -> route -> finish -> sta -> gui
# Tools come from the OpenLane2 container (yosys 0.46, OpenROAD, OpenSTA).
# Usage: flow/run_flow.sh [stage ...]     (default: all stages except gui)
# ==============================================================================
set -euo pipefail

PROJ=$(cd "$(dirname "$0")/.." && pwd)
PLATFORM_HOST=${PLATFORM_HOST:-$HOME/pdks/orfs/flow/platforms/asap7}
IMAGE=${IMAGE:-ghcr.io/efabless/openlane2:2.3.10}
LOGS=$PROJ/build/logs
mkdir -p "$LOGS" "$PROJ/build/lib" "$PROJ/build/odb"

if [ ! -d "$PLATFORM_HOST" ]; then
  echo "ASAP7 platform not found at $PLATFORM_HOST (sparse-clone ORFS flow/platforms/asap7)"; exit 1
fi

# Un-gzip the TT/RVT liberty files once (abc cannot read .gz)
for f in "$PLATFORM_HOST"/lib/NLDM/asap7sc7p5t_{AO,INVBUF,OA,SIMPLE}_RVT_TT_nldm_*.lib.gz; do
  out=$PROJ/build/lib/$(basename "${f%.gz}")
  [ -f "$out" ] || gunzip -c "$f" > "$out"
done
cp -n "$PLATFORM_HOST"/lib/NLDM/asap7sc7p5t_SEQ_RVT_TT_nldm_220123.lib "$PROJ/build/lib/" 2>/dev/null || true

in_container() {   # $1 = log name, rest = command
  local log=$1; shift
  docker run --rm --init \
    --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "$PROJ":/work -v "$PLATFORM_HOST":/pdk/asap7:ro -w /work \
    "$IMAGE" bash -c "source /work/flow/asap7_env.sh && $*" 2>&1 | tee "$LOGS/$log.log"
  return "${PIPESTATUS[0]}"
}

gui() {
  # WSLg: X11 socket + Wayland/PulseAudio runtime dir
  docker run --rm -d --name micro-nvswitch-gui \
    --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -e DISPLAY="${DISPLAY:-:0}" -e WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
    -e XDG_RUNTIME_DIR=/mnt/wslg/runtime-dir -e QT_X11_NO_MITSHM=1 \
    -v /tmp/.X11-unix:/tmp/.X11-unix -v /mnt/wslg:/mnt/wslg \
    -v "$PROJ":/work -v "$PLATFORM_HOST":/pdk/asap7:ro -w /work \
    "$IMAGE" bash -c "source /work/flow/asap7_env.sh && openroad -gui /work/pnr/openroad/scripts/gui.tcl" \
    > /dev/null
  echo "OpenROAD GUI launched (container micro-nvswitch-gui)."
}

run_stage() {
  case $1 in
    synth)     in_container 1_synth     "yosys -c /work/synth/yosys/scripts/synth_asap7.tcl" ;;
    floorplan) in_container 2_floorplan "openroad -exit -no_init -threads \$NUM_THREADS /work/pnr/openroad/scripts/1_floorplan.tcl" ;;
    place)     in_container 3_place     "openroad -exit -no_init -threads \$NUM_THREADS /work/pnr/openroad/scripts/2_place.tcl" ;;
    cts)       in_container 4_cts       "openroad -exit -no_init -threads \$NUM_THREADS /work/pnr/openroad/scripts/3_cts.tcl" ;;
    groute)    in_container 5_groute    "openroad -exit -no_init -threads \$NUM_THREADS /work/pnr/openroad/scripts/4_groute_signoff.tcl && python3 -I /work/flow/fix_spef_delimiter.py \$PNR_DIR/outputs/\${DESIGN_NAME}_groute_default.spef \$PNR_DIR/outputs/\${DESIGN_NAME}_groute_fixed.spef" ;;
    sta-groute) in_container 7_sta      "STA_VIEW=groute sta -no_init -exit /work/signoff/sta/sta.tcl" ;;
    route)     in_container 5_route     "openroad -exit -no_init -threads \$NUM_THREADS /work/pnr/openroad/scripts/4_route.tcl" ;;
    finish)    in_container 6_finish    "openroad -exit -no_init -threads \$NUM_THREADS /work/pnr/openroad/scripts/5_finish.tcl" ;;
    sta)       in_container 7_sta       "sta -no_init -exit /work/signoff/sta/sta.tcl" ;;
    gui)       gui ;;
    *) echo "unknown stage $1"; exit 1 ;;
  esac
}

STAGES=("$@")
[ ${#STAGES[@]} -eq 0 ] && STAGES=(synth floorplan place cts route finish sta)
for s in "${STAGES[@]}"; do
  echo "================ $s ================"
  start=$(date +%s)
  run_stage "$s"
  echo "---- $s done in $(( $(date +%s) - start ))s"
done
