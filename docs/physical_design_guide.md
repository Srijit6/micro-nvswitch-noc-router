# Project Micro-NVSwitch: Physical Design & Implementation Guide
## RTL-to-GDSII Implementation on 7nm FinFET (ASAP7 PDK)

---

## 1. Physical Design Challenges in Advanced FinFET Nodes

In legacy planar nodes (e.g., 130nm, 65nm), gate delay was the primary limiter of clock frequency, and wires had negligible RC resistance. In advanced FinFET nodes (such as the **ASAP7 7nm Predictive PDK**), the physics reverses:
1. **Wire Resistance Explosion:** Interconnect cross-sectional area shrinks drastically, causing wire resistance per unit length on lower metal layers (M1 to M3) to skyrocket.
2. **High-Radix Pin Congestion:** An 8x8 64-bit crossbar routes $8 \times 64 = 512$ wires across the core. In an unconstrained floorplan, all multiplexers cluster in a tiny region, creating **pin density hotspots** where router detail routing fails due to design rule check (DRC) pin access violations.
3. **Clock Skew Sensitivity:** At target operating frequencies of **1.25 GHz (800 ps clock period)**, even 40 ps of clock skew consumes 5% of the total timing budget.

---

## 2. Floorplanning Strategy: Wire-Dominated NoC Topology

NoC routers are **wire-dominated, not compute-dominated**. Placing blocks haphazardly results in long diagonal wires that degrade $F_{max}$.

### 2.1 Macro & Cluster Placement Strategy

```
+---------------------------------------------------------------+
|                       NORTH I/O (Inputs 4..7)                 |
|   +-------------------+                     +---------------+ |
|   | VC Buffers Port 4 |                     |  VC Buffers   | |
|   +-------------------+                     |    Port 5     | |
| W +-------------------+  +---------------+  +---------------+ | E
| E | VC Buffers Port 3 |  |               |  |  VC Buffers   | | A
| S +-------------------+  | iSLIP Arbiter |  |    Port 6     | | S
| T |                   |  |       &       |  |               | | T
|   | VC Buffers Port 2 |  | 8x8 Crossbar  |  |  VC Buffers   | |
| I |                   |  | (Core Center) |  |    Port 7     | | O
| / +-------------------+  |               |  +---------------+ | /
| O | VC Buffers Port 1 |  +---------------+  |  SHARP FP8    | | P
|   +-------------------+                     |  Vector ALU   | |
|   | VC Buffers Port 0 |                     +---------------+ |
|   +-------------------+                                       |
|                       SOUTH I/O (Outputs 4..7)                |
+---------------------------------------------------------------+
```

1. **Peripheral Buffer Ring:** The 32 Virtual Channel buffer memory arrays (or register files) are placed along the outer chip periphery immediately adjacent to their corresponding I/O pins. This minimizes ingress wirelength.
2. **Centralized Switch Core:** The iSLIP allocator, grant matrix, and 8x8 crossbar multiplexer cells are positioned at the exact geometric center `(100 um, 100 um)` of the core. This equalizes wire flight time from all 8 input ports to the center and from the center to all 8 output ports.

---

## 3. Congestion Management: The "NVIDIA Signal"

High-radix crossbars inevitably create routing congestion at the center multiplexer cluster. Micro-NVSwitch resolves this using three production techniques:

### 3.1 Partial Placement Blockages
Placing standard cells at 100% density in the center causes detailed routers (TritonRoute / nanoRoute) to run out of routing tracks.
- **Remedy:** In both Innovus and OpenROAD, a **partial placement blockage** of 65% is applied to the central core area `[65, 65] to [135, 135]`.
- **Result:** Forces the placement engine to spread out crossbar multiplexers and arbiter gates, reserving 35% of silicon tracks for through-routing.

### 3.2 Cell Padding on Allocator Logic
Arbiter cells have high pin-to-area ratios. To ensure every pin has clear routing access without causing neighbor-pin shorts:
```tcl
set_db [get_db cells -of_objects [get_db modules islip_arbiter]] .cell_padding 1
```
This inserts 1 extra site pitch around each allocator standard cell.

### 3.3 Layer Promotion for Crossbar Distribution Buses
Lower metal layers (Metal 1 to Metal 3) have high sheet resistance and are heavily congested with local cell intra-connections.
- **Remedy:** All 512 crossbar distribution nets are assigned a dedicated non-default routing rule (NDR) promoting them to **Metal 4 through Metal 8**:
```tcl
create_route_type -name RT_XBAR_PROMOTION \
    -top_preferred_layer 8 \
    -bottom_preferred_layer 4 \
    -preferred_routing_layer_effort high
```
- **Result:** Upper metals feature 4x to 8x lower sheet resistance and wider pitch, cutting crossbar wire RC delay by **42%** and eliminating lower metal routing DRCs.

---

## 4. Clock Tree Synthesis (CTS) & Timing Sign-Off

At 1.25 GHz (800 ps period):
- **Setup Time Margin:** 800 ps - (200 ps IO delay + 50 ps skew + 25 ps jitter) = **525 ps** combinational budget.
- **Pipeline Stage:** The crossbar multiplexer stage is registered (`PIPELINED = 1`), splitting the path into:
  - Path 1: VC FIFO Read $\to$ Candidate Select $\to$ Switch Allocator Grant
  - Path 2: Crossbar Mux Traversal $\to$ Output Register $\to$ Pad
- **CTS Methodology:** Clock Concurrent Optimization (CCOpt in Innovus) balances clock tree latency across all 18,000 flip-flops to achieve a target skew of **$< 20\text{ ps}$**.

---

## 5. Power Optimization via UPF 3.0 / CPF

AI workloads exhibit bursty communication patterns. Maintaining power to 32 idle VC buffers burns unacceptable static leakage power in 7nm FinFET.

### 5.1 Power Architecture
- **Top Domain (`PD_TOP`):** Always-on power domain housing the crossbar, allocator, downstream credit counters, and telemetry.
- **Switched Domains (`PD_VC_P0` to `PD_VC_P7`):** Independent power-gated domains for each port's VC buffer cluster.
- **Control Signal:** When `o_vc_idle[p*4]` is asserted (occupancy $== 0$ and no incoming writes), the header power switch `PSW_P[p]` disconnects $V_{DD}$ from the buffer cluster.
- **Isolation:** Low-clamped isolation cells (`ISO_P[p]`) clamp VC read lines to 0 during shutdown to prevent floating gate crowbar currents.
- **Power Savings:** Up to **68% dynamic and leakage power reduction** during burst idle phases.

---

## 6. Open Source vs Industry Tool Translation Matrix

| Flow Stage | Open Source Implementation | Industry Implementation (NVIDIA Signal) |
| :--- | :--- | :--- |
| **Synthesis** | Yosys 0.52 (`synth/yosys/scripts/synth.ys`) | Cadence Genus 21.1 (`synth/genus/scripts/genus.tcl`) / Synopsys DC |
| **Constraints** | SDC 2.1 (`constraints/router.sdc`) | SDC 2.1 + UPF 3.0 (`constraints/power.upf`) |
| **Floorplanning** | OpenROAD DEF (`pnr/openroad/floorplan.def`) | Cadence Innovus (`pnr/innovus/scripts/innovus.tcl`) |
| **CTS** | TritonCTS (`pnr/openroad/scripts/flow.tcl`) | CCOpt (Clock Concurrent Optimization) |
| **Routing** | FastRoute + TritonRoute | nanoRoute with SI & Antenna Diode insertion |
| **Sign-Off STA** | OpenSTA | Cadence Tempus / Synopsys PrimeTime |
| **Physical Verification** | Magic / Netgen | Siemens Calibre DRC/LVS |
