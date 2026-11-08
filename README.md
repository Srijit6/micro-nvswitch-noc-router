# Micro-NVSwitch: 8x8 NoC Router ASIC with In-Network FP8 Reduction (Verilog RTL-to-GDSII Flow, ASAP7 7nm)

[![Release](https://img.shields.io/github/v/release/Srijit6/micro-nvswitch-noc-router)](https://github.com/Srijit6/micro-nvswitch-noc-router/releases)
[![Tests](https://img.shields.io/badge/cocotb-14%2F14%20passing-brightgreen.svg)](#4-verification)
[![Lint](https://img.shields.io/badge/Verilator%20lint-clean-blue.svg)](rtl/)
[![PDK](https://img.shields.io/badge/PDK-ASAP7%207nm-purple.svg)](#6-physical-design)

**Micro-NVSwitch is an open-source 8x8 network-on-chip (NoC) router, inspired by NVIDIA NVSwitch, written in synthesizable Verilog RTL and implemented on the ASAP7 7nm FinFET PDK with Yosys, OpenROAD and OpenSTA.** Unlike most academic NoC routers, it does more than move packets: a SHARP-style ALU reduces FP8 (E4M3) vectors inside the switch, the in-network All-Reduce used in GPU fabrics. It also has 4 virtual channels per port, credit-based flow control, iSLIP switch allocation and hardware multicast.

| | |
|---|---|
| **RTL** | Verilog-2001, 5 modules + package, Verilator lint-clean |
| **Verification** | 14/14 cocotb tests (incl. random traffic with scoreboard), 6/6 Icarus testbench checks |
| **Synthesis** | Yosys → ASAP7 RVT: 92,890 cells, 14,192 µm² |
| **Physical design** | OpenROAD floorplan → placement → CTS → global route, 185.6 µm × 185.6 µm die |
| **Sign-off** | OpenSTA at 2.5 ns: setup met (+74 ps), 142 mW. Hold, detailed routing and GDSII still open ([details](#limitations)) |

---

## 1. Architecture

![Block diagram of router_top: 8 input ports each with 4 VC FIFOs feed a VC allocator and input VC selector, which drive an iSLIP switch allocator; grants steer a pipelined 8x8 multicast crossbar to 8 output ports. Downstream credit counters gate requests, a SHARP ALU taps crossbar inputs 0 and 1, and VC occupancy feeds power telemetry.](docs/images/architecture.png)

*Figure 1. `router_top` block diagram. A flit takes three cycles: buffer write, VC + switch allocation, then crossbar traversal into the output register.*

- **8 ports × 4 virtual channels:** each VC is an 8-flit FIFO of 66-bit flits (2-bit type + 64-bit data), so a blocked packet on one VC does not stall the others (no head-of-line blocking).
- **Credit-based flow control:** 4-bit per-VC credit counters on every output. A flit is only sent when the downstream buffer has space, so nothing is dropped.
- **Atomic multicast VC allocation:** a head flit reserves *all* of its destination output VCs in one cycle or none of them. This keeps multicast wormhole routing deadlock-free.
- **iSLIP switch allocator:** round-robin request/grant/accept on an 8×8 request matrix. Multicast flits can be served over several cycles.
- **SHARP reduction ALU:** element-wise FP8 SUM/MAX/MIN (8 lanes), INT32 SUM (2 lanes) and XOR on the flits switched from inputs 0 and 1.
- **Power telemetry:** per-VC occupancy and idle flags drive the UPF 3.0 / CPF power-gating intent in `constraints/`.

Full specification: [`docs/microarchitecture.md`](docs/microarchitecture.md).

## 2. Design Methodology

![Flowchart: specification, RTL, Verilator lint, simulation, Yosys synthesis, then OpenROAD floorplan, placement, CTS, global routing and OpenSTA timing/power, each with its measured result. A red feedback loop shows the 800 ps target failing and being relaxed to 2.5 ns. Dashed boxes mark detailed routing, GDSII and the commercial flow as not yet run.](docs/images/design_flow.png)

*Figure 2. Flow from specification to sign-off, with the measured result of each step. Dashed steps are scripted but not yet run.*

## 3. Quick Start

```bash
make lint      # Verilator lint
make sim       # Icarus Verilog self-checking testbench
make cocotb    # cocotb regression (14 tests)
make test      # sim + cocotb
```

The ASAP7 flow runs in the `ghcr.io/efabless/openlane2:2.3.10` container, so the host only needs Docker and the ASAP7 platform files:

```bash
git clone --depth 1 --filter=blob:none --sparse \
    https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts.git ~/pdks/orfs
git -C ~/pdks/orfs sparse-checkout set flow/platforms/asap7

flow/run_flow.sh synth floorplan place cts groute sta-groute gui   # low-memory path
flow/run_flow.sh route finish sta gui                              # needs more RAM
```

Each stage saves a checkpoint in `build/odb/`, so later stages can be rerun on their own. Set `PLATFORM_HOST` if ASAP7 lives elsewhere.

## 4. Verification

| Suite | Tests | Result |
|---|---|---|
| cocotb (`dv/cocotb/tests/test_router.py`) | reset/credits, unicast, multi-flit wormhole, multicast, HoL avoidance, lossless backpressure, SHARP FP8 sum | 7/7 pass |
| cocotb (`dv/cocotb/tests/test_router_fixes.py`) | body flits follow own header, no output-VC interleave, partial multicast grant, zero-credit multicast, no credit overrun, SHARP needs both operands, random traffic with scoreboard | 7/7 pass |
| Icarus Verilog (`dv/common/tb_router_top.v`) | reset, unicast, multicast, HoL, SHARP, credits | 6/6 pass |

![Waveform from the Icarus testbench. Unicast: i_flit_valid=01 with dest_mask 10 at 4.5 ns; grant_valid=10 at 6.5 ns; o_flit_valid[4] and packet_id A1 at 7.5 ns. Multicast: i_flit_valid=04 with dest_mask AA at 14.5 ns; grant_valid=AA; o_flit_valid bits 1, 3, 5 and 7 rise together at 17.5 ns with packet_id B2.](docs/images/waveform_unicast_multicast.png)

*Figure 3. Simulation waveform for TEST 2 (unicast port 0 → port 4) and TEST 3 (multicast port 2 → ports 1, 3, 5, 7). Both reach the outputs 3 cycles after injection, and the multicast copies leave in the same cycle. Rendered from the regression VCD.*

Test plan: [`docs/verification_plan.md`](docs/verification_plan.md).

## 5. Synthesis

Yosys 0.46 maps the RTL to the ASAP7 RVT library (`synth/yosys/scripts/synth_asap7.tcl`). `check` reports 0 problems.

| Cell group | Count | Notes |
|---|---:|---|
| Flip-flops (`DFFASRHQNx1`) | 18,624 | 16,896 of them are VC buffer storage (8 ports × 4 VCs × 8 entries × 66 bits) |
| AND-OR / OR-AND complex gates (AO, OA, AOI, OAI) | 34,108 | mostly FIFO read muxes and crossbar selection |
| NAND / NOR / AND / OR (+1 tie cell) | 26,462 | |
| Buffers / inverters | 12,768 | |
| XOR / XNOR / MAJ | 928 | SHARP ALU arithmetic |
| **Total** | **92,890** | **14,192 µm² cell area, 49.8% sequential** |

The FIFOs are built from flip-flops rather than SRAM macros, so half the area is storage. Reports: [`synth_asap7_stat.rpt`](synth/yosys/reports/synth_asap7_stat.rpt) and [`synth_asap7_check.rpt`](synth/yosys/reports/synth_asap7_check.rpt). A technology-independent run (`make synth TOOL=yosys`) gives 73,159 generic gates with 18,670 flip-flops.

## 6. Physical Design

ASAP7 RVT, typical corner (0.70 V), 2.5 ns clock. Timing and power come from OpenSTA with parasitics estimated from global routes.

| Metric | Value |
|---|---|
| Setup WNS / TNS | **+74 ps / 0 ps** (met, Fmax ≈ 412 MHz) |
| Hold WNS / TNS | **−15 ps / −3,057 ps** (not met, input-port paths) |
| Standard cells (excl. tap/fill) | 115,201 |
| Cell area / utilization | 16,531 µm² / 52.5% |
| Clock tree | 2,350 clock buffers, 82.8 ps setup skew |
| Hold buffers | 6,451 |
| Global routing | 114,115 nets, 813,577 µm, 0 overflow |
| Power | 142 mW (80% combinational, 14% sequential, 6% clock) |

| Stage | Setup WNS | Hold WNS | Utilization |
|---|---|---|---|
| Placement | +146 ps | +39 ps | 49.3% |
| CTS + hold repair | +125 ps | +4.7 ps | 52.8% |
| Global route | +51 ps | −15 ps | 52.5% |

![Post-CTS placement of the 185.6 µm die with cells colored by function: flip-flops (blue) fill the outer region, combinational logic (grey) is concentrated in the centre, hold-fix buffers (orange) cluster along the left, top and bottom edges, and clock buffers (red) are spread evenly.](docs/images/pd_placement_cts.png)

*Figure 4. Placement after CTS, coloured by cell function. VC-buffer flip-flops fill the outside and the allocator/crossbar logic sits in the centre. Hold buffers bunch up near the I/O edges, which is where the remaining hold violations are.*

![RUDY routing-demand heat map of the die after CTS: mostly blue (low) with a green/yellow region over the central logic and a yellow hotspot at the bottom-edge pins.](docs/images/pd_congestion_rudy.png)

*Figure 5. Estimated routing demand (RUDY). Global routing finished with 0 overflow. Demand is highest over the central logic and the bottom-edge pins.*

![OpenROAD clock-tree view: one root branching through several buffer levels to 18,624 sinks, with sink insertion delays between about 116 and 147 ps.](docs/images/pd_clock_tree.png)

*Figure 6. Clock tree after CTS, plotted by insertion delay.*

**Critical path:** VC state flops → VC eligibility → `req_matrix` → iSLIP grant → crossbar input mux → output register. VC selection, switch allocation and the crossbar all happen in one cycle, which is why the 800 ps target missed by 1.6 ns.

Reports: [`signoff/sta/reports/`](signoff/sta/reports/) (setup, hold, DRV, skew, power) and [`pnr/openroad/reports/`](pnr/openroad/reports/) (per-stage summaries, congestion, CTS).

### Limitations

- **1.25 GHz is not met.** At 800 ps the post-placement setup WNS was −1,604 ps. The open flow uses a 2.5 ns clock (`constraints/router_openroad.sdc`). Reaching 1.25 GHz needs a pipeline register between switch allocation and the crossbar. `constraints/router.sdc` keeps the 800 ps target.
- **No detailed routing or GDSII yet.** Detailed routing ran out of memory on a 3.7 GB WSL host. The `route` and `finish` stages are scripted and resume from the CTS checkpoint.
- **Hold is open after global routing.** The 50 ps minimum input delay is shorter than the 240–280 ps clock insertion delay. A larger input delay or a post-route hold-repair pass should close it.
- **SPEF workaround.** OpenROAD writes `*DELIMITER :` but names pins `inst/pin`, so OpenSTA silently drops the parasitics. `flow/fix_spef_delimiter.py` rewrites the file.
- **Commercial flow not run.** Genus, Design Compiler and Innovus scripts are included but untested (no licences).

## 7. Repository Structure

```
micro-nvswitch-noc-router/
├── rtl/            Verilog RTL: router_pkg.v, vc_buffer, islip_arbiter, crossbar_8x8, sharp_alu, router_top
├── dv/             Icarus testbench (common/) and cocotb suite (cocotb/)
├── constraints/    SDC (800 ps and 2.5 ns), UPF 3.0, CPF
├── synth/          Yosys (generic + ASAP7), Genus and DC scripts, synthesis reports
├── pnr/            OpenROAD staged flow + reports, Innovus script
├── signoff/sta/    OpenSTA sign-off script and reports
├── flow/           run_flow.sh container driver, ASAP7 settings, SPEF fix
└── docs/           Microarchitecture, verification plan, PD guide, figures
```

## 8. Releases

| Version | Date | Contents |
|---|---|---|
| [v0.1.0](https://github.com/Srijit6/micro-nvswitch-noc-router/releases/tag/v0.1.0) | 2026-11-08 | Verified RTL (14/14 cocotb), ASAP7 synthesis, OpenROAD placement, CTS and global routing, OpenSTA sign-off at 2.5 ns |

Planned for v1.0.0: detailed routing, GDSII with DRC/LVS, hold closure, and a pipelined allocator to target 1.25 GHz.
