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
├── constraints/
│   ├── router.sdc               # Synopsys Design Constraints (1.25 GHz / 800 ps)
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
│   │   ├── scripts/synth.ys
│   │   ├── mapped/              # Synthesized gate-level netlists
│   │   └── reports/             # Area, cell counts, hierarchy checks
│   ├── genus/                   # Industry synthesis (Cadence Genus)
│   │   └── scripts/genus.tcl
│   └── dc/                      # Industry synthesis (Synopsys DC)
│       └── scripts/dc.tcl
└── pnr/
    ├── openroad/                # Open-source PnR (OpenROAD)
    │   ├── floorplan.def        # Pin and boundary placement DEF
    │   └── scripts/flow.tcl     # CTS, FastRoute, TritonRoute, OpenSTA
    └── innovus/                 # Industry PnR (Cadence Innovus)
        └── scripts/innovus.tcl  # Congestion management, CCOpt, GDSII
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

### Open Source Flow (Yosys + OpenROAD)
Run generic synthesis and gate-level netlist generation:
```bash
make synth TOOL=yosys
```
*Synthesis Results:* 73,159 standard cells, 18,670 flip-flops, 0 DRC violations reported by `check`.

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
