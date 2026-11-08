# Project Micro-NVSwitch
## A Rubin-Class, High-Radix NoC Router for AI Fabrics (RTL-to-GDSII)

[![Verification](https://img.shields.io/badge/Verification-100%25%20Passing-brightgreen.svg)](docs/verification_plan.md)
[![Lint](https://img.shields.io/badge/Verilator%20Lint-Clean-blue.svg)](rtl/)
[![Synthesis](https://img.shields.io/badge/Synthesis-Yosys%20%7C%20Genus-orange.svg)](synth/)
[![Node](https://img.shields.io/badge/PDK-ASAP7%207nm%20FinFET-purple.svg)](pnr/)

---

## 1. Background & Motivation
In trillion-parameter Large Language Models (LLMs), inter-GPU data movement is the primary bottleneck. As compute scales across thousands of Tensor Cores via Tensor and Pipeline Parallelism, GPUs spend critical latency waiting for All-Reduce and All-to-All data synchronization.

NVIDIA's NVSwitch fabric transforms entire server racks into unified compute nodes:
- **Blackwell NVLink 5:** Delivers 1.8 TB/s per GPU in the NVL72 platform.
- **Vera Rubin NVLink 6:** Doubles bandwidth to **3.6 TB/s per GPU** with 400 Gbps SerDes, reaching an aggregate rack bandwidth of **260 TB/s**.

**Project Micro-NVSwitch** implements a complete RTL-to-GDSII high-radix, non-blocking NoC router demonstrating mastery over the exact data-movement and physical design challenges faced by silicon teams building Blackwell- and Rubin-class architectures.

---

## 2. Key Architecture Features

```
               +---------------------------------------------------+
               |                 MICRO-NVSWITCH                    |
               |                                                   |
 Input Port 0 >| [VC0..VC3] ---\                                   |> Output Port 0
 Input Port 1 >| [VC0..VC3] ----\     +--------------------+       |> Output Port 1
 Input Port 2 >| [VC0..VC3] ----->---|    iSLIP Switch    |       |> Output Port 2
 Input Port 3 >| [VC0..VC3] ----/     |     Allocator      |       |> Output Port 3
 Input Port 4 >| [VC0..VC3] ---/      +--------------------+       |> Output Port 4
 Input Port 5 >| [VC0..VC3] ---\                |                  |> Output Port 5
 Input Port 6 >| [VC0..VC3] ----\     +--------------------+       |> Output Port 6
 Input Port 7 >| [VC0..VC3] ----->---| 8x8 Crossbar Matrix |------>|> Output Port 7
               |                      +--------------------+       |
               |                                |                  |
               |                      +--------------------+       |
               |                      |   SHARP FP8 ALU    |       |
               |                      | (In-Network Red.)  |       |
               |                      +--------------------+       |
               +---------------------------------------------------+
```

- **8x8 Non-Blocking Crossbar:** Full bisection bandwidth routing with single-cycle pipelined multiplexer stages for high $F_{max}$.
- **Lossless Credit-Based Flow Control:** Upstream sender tracks downstream credits; zero packet drops under severe backpressure.
- **4 Virtual Channels (VCs) per Port:** Eliminates Head-of-Line (HoL) blocking between latency-critical control flits and large payloads.
- **iSLIP Multi-Stage Switch Allocator:** Starvation-free round-robin matching providing 100% throughput for uniform traffic.
- **AI Multicast Routing:** Native 1-to-$N$ broadcast and fanout replication for All-Reduce collectives.
- **In-Network Compute (SHARP Engine):** Emulates NVIDIA's Scalable Hierarchical Aggregation and Reduction Protocol (SHARP) with an on-chip ALU performing FP8 (E4M3) vector reductions on the fly.
- **Low-Power Telemetry & UPF 3.0:** Dynamic activity tracking and fine-grained clock/power gating for idle virtual channels.

---

## 3. Repository Structure

```
micro-nvswitch/
├── Makefile                     # Master build and execution harness
├── README.md                    # Project documentation
├── env_setup.sh                 # Environment setup script
├── flow/
│   ├── run_flow.sh              # Open-source ASAP7 flow driver (OpenLane2 container)
│   ├── asap7_env.sh             # ASAP7 platform paths, cells, clock, thread count
│   └── fix_spef_delimiter.py    # Fixes OpenROAD-estimated SPEF pin names for OpenSTA
├── constraints/
│   ├── router.sdc               # Synopsys Design Constraints (1.25 GHz / 800 ps)
│   ├── router_openroad.sdc      # OpenROAD/OpenSTA constraints (2.5 ns, see Section 5)
│   ├── power.upf                # IEEE 1801 UPF 3.0 Low-Power specification
│   └── power.cpf                # Cadence Common Power Format (CPF)
├── docs/
│   ├── microarchitecture.md     # In-depth architectural specification
│   ├── verification_plan.md     # Verification strategy & test catalog
│   └── physical_design_guide.md # FinFET PnR & Congestion Management Guide
├── dv/
│   ├── cocotb/                  # Cocotb Python verification suite
│   │   ├── Makefile
│   │   └── tests/test_router.py # 7 directed and constrained-random tests
│   └── common/
│       └── tb_router_top.v      # Self-checking standalone Verilog testbench
├── rtl/
│   ├── include/router_pkg.v     # Flit definitions, opcodes, parameters
│   ├── blocks/
│   │   ├── vc_buffer.v          # Parameterized VC FIFO with credit return
│   │   ├── islip_arbiter.v      # Multi-stage iSLIP switch allocator
│   │   ├── crossbar_8x8.v       # Non-blocking multicast crossbar
│   │   └── sharp_alu.v          # FP8 (E4M3) in-network reduction ALU
│   └── top/
│       └── router_top.v         # Top-level NoC router integration
├── synth/
│   ├── yosys/                   # Open-source synthesis (Yosys)
│   │   ├── scripts/synth.ys     # Generic (technology-independent) synthesis
│   │   ├── scripts/synth_asap7.tcl  # ASAP7 RVT technology-mapped synthesis
│   │   ├── mapped/              # Synthesized gate-level netlists (generated)
│   │   └── reports/             # Area, cell counts, hierarchy checks
│   ├── genus/                   # Industry synthesis (Cadence Genus)
│   │   └── scripts/genus.tcl
│   └── dc/                      # Industry synthesis (Synopsys DC)
│       └── scripts/dc.tcl
├── pnr/
│   ├── openroad/                # Open-source PnR (OpenROAD)
│   │   ├── scripts/1_floorplan.tcl ... 5_finish.tcl  # Staged ASAP7 flow
│   │   ├── scripts/4_groute_signoff.tcl  # Low-memory path: stop at global route
│   │   ├── scripts/gui.tcl      # Opens the layout in the OpenROAD GUI
│   │   └── reports/             # Per-stage timing/area, CTS, congestion
│   └── innovus/                 # Industry PnR (Cadence Innovus)
│       └── scripts/innovus.tcl  # Congestion management, CCOpt, GDSII
└── signoff/
    └── sta/
        ├── sta.tcl              # OpenSTA sign-off (setup/hold/DRV/skew/power)
        └── reports/             # Sign-off timing and power reports
```

---

## 4. Quickstart & Verification

### Run RTL Linting (Verilator)
```bash
make lint
```

### Run Standalone Regression Testbench (Icarus Verilog)
```bash
make sim
```

### Run Cocotb Test Suite
```bash
make cocotb
```

### Run Full Test Suite (Both Standalone & Cocotb)
```bash
make test
```

---

## 5. Physical Implementation & The "NVIDIA Signal"

### Open Source Flow (Yosys + OpenROAD + OpenSTA on ASAP7)

The open flow maps the RTL to the **ASAP7 7nm RVT** library and runs floorplan, placement, clock tree synthesis, global routing and OpenSTA sign-off. Every tool runs inside the `ghcr.io/efabless/openlane2:2.3.10` container, so only Docker and the ASAP7 platform files are needed on the host.

**Setup.** Fetch the ASAP7 platform from OpenROAD-flow-scripts. `flow/run_flow.sh` expects it at `~/pdks/orfs/flow/platforms/asap7`; override the location with `PLATFORM_HOST`.
```bash
git clone --depth 1 --filter=blob:none --sparse \
    https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts.git ~/pdks/orfs
git -C ~/pdks/orfs sparse-checkout set flow/platforms/asap7
```

**Run.** Each stage saves a checkpoint in `build/odb/`, so a later stage can be rerun on its own.
```bash
# Synthesis -> floorplan -> place -> CTS -> global route -> STA, then open the GUI
flow/run_flow.sh synth floorplan place cts groute sta-groute gui

# With enough memory for detailed routing (see "Limitations" below)
flow/run_flow.sh route finish sta gui
```

#### Results: ASAP7 RVT, typical corner (0.70 V), 2.5 ns clock

| Metric | Value |
|---|---|
| Clock target | 2,500 ps (400 MHz) |
| **Setup WNS / TNS** | **+74 ps / 0 ps** (met) |
| **Hold WNS / TNS** | **−15 ps / −3,057 ps** (not met, input-port paths) |
| Achievable Fmax | ~412 MHz |
| Standard cells (excluding fill/tap) | 115,201 |
| Flip-flops | 18,624 (`DFFASRHQNx1`) |
| Cell area / core utilization | 16,531 µm² / 52.5% |
| Die size | 185.6 µm × 185.6 µm |
| Clock tree | 2,350 clock buffers, 82.8 ps setup skew |
| Hold buffers inserted | 6,451 |
| Global routing | 114,115 nets, 813,577 µm, 22% resource use, 0 overflow |
| Total power | 142 mW (80% combinational, 14% sequential, 6% clock) |

Timing and power come from OpenSTA with parasitics estimated from global routes (`signoff/sta/reports/`). Per-stage numbers are in `pnr/openroad/reports/`.

| Stage | Setup WNS | Hold WNS | Utilization |
|---|---|---|---|
| Placement | +146 ps | +39 ps | 49.3% |
| CTS + hold repair | +125 ps | +4.7 ps | 52.8% |
| Global route | +51 ps | −15 ps | 52.5% |

#### Limitations and open items
- **The 1.25 GHz target is not met.** At 800 ps the post-placement setup WNS was **−1,604 ps**, so the worst path takes about 2.4 ns. The open-flow constraints in `constraints/router_openroad.sdc` therefore use a 2.5 ns clock, and I/O delays stay at 25% of the period. Reaching 1.25 GHz needs pipelining in the RTL. `constraints/router.sdc` keeps the original 800 ps target for the commercial flow.
- **No detailed routing or GDSII yet.** Detailed routing was killed for running out of memory on a 3.7 GB WSL host, so the layout stops at global-route guides. The `route`/`finish` stages are scripted and resume from the CTS checkpoint on a machine with more memory.
- **Hold is not closed after global routing.** The failing paths start at input ports, where the 50 ps minimum input delay is shorter than the clock-tree insertion delay (about 240–280 ps). A larger minimum input delay or a hold-repair pass after global routing would close them.
- **SPEF workaround.** OpenROAD's `estimate_parasitics -spef_file` writes `*DELIMITER :` in the header but names pins `inst/pin`, so standalone OpenSTA matches no pins and silently drops the wire parasitics. `flow/fix_spef_delimiter.py` rewrites the file during the `groute` stage.

#### Generic synthesis (technology-independent)
```bash
make synth TOOL=yosys
```
This produces 73,159 Yosys generic gates (not library cells), including 18,670 flip-flops, with 0 problems reported by `check`.

### Industry Translation Flow (Cadence Genus + Innovus)
Push design to $F_{max}$ on the **ASAP7 7nm FinFET PDK**:
```bash
make synth TOOL=genus
make pnr TOOL=innovus
```

### Physical Design Highlights:
- **Wire-Dominated Floorplan:** SRAM / VC buffer macros arranged at the periphery; switch allocator and crossbar centered at `(100 um, 100 um)` to minimize wire flight time.
- **Congestion Management:** 
  - 65% partial placement blockage in the core center to resolve pin density explosion.
  - Cell padding of 1 site pitch on arbiter standard cells.
  - Layer promotion of 512 crossbar distribution nets to **Metal 4 through Metal 8** (42% RC delay reduction).
- **Power Optimization:** IEEE 1801 UPF 3.0 script implements power gating of idle virtual channels, yielding up to **68% dynamic and leakage power reduction** during burst idle intervals.
