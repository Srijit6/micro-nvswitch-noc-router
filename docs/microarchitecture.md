# Project Micro-NVSwitch: Microarchitecture Specification
## Rubin-Class High-Radix NoC Router for Trillion-Parameter AI Fabrics

---

## 1. Executive Overview & Industry Motivation

In the era of trillion-parameter Large Language Models (LLMs), distributed training and inference workloads are fundamentally **communication-bound**. Split across tens of thousands of GPUs via Tensor Parallelism (TP), Pipeline Parallelism (PP), and Expert Parallelism (MoE), deep learning models require continuous all-to-all and all-reduce data exchanges between layers.

Traditional interconnects (such as PCIe Gen 5/6) introduce severe bandwidth bottlenecks:
- **NVIDIA Blackwell (NVLink 5):** Delivers 1.8 TB/s bidirectional bandwidth per GPU, enabling 72 GPUs in a single NVL72 liquid-cooled domain.
- **NVIDIA Vera Rubin (NVLink 6):** Doubles per-GPU bandwidth to **3.6 TB/s** utilizing 400 Gbps PAM4 SerDes, delivering an aggregate rack-scale fabric bandwidth of **260 TB/s**.

**Project Micro-NVSwitch** is a cycle-accurate, synthesizable RTL implementation of a high-radix, non-blocking Network-on-Chip (NoC) router embodying the architectural principles of NVIDIA's NVSwitch ASICs. It incorporates:
1. **8x8 Non-Blocking Crossbar:** Full bisection bandwidth routing with zero internal blocking.
2. **Lossless Credit-Based Flow Control:** Eliminates packet drops under saturation without fragile valid/ready backpressure deadlocks.
3. **4 Virtual Channels (VCs) per Port:** Eliminates Head-of-Line (HoL) blocking between control and data packets.
4. **iSLIP Round-Robin Allocator:** Starvation-free, multi-stage matching achieving near-100% throughput under heavy traffic.
5. **AI Multicast Replication:** Native 1-to-$N$ hardware fanout for All-Reduce collectives.
6. **In-Network Compute (SHARP Engine):** Emulates NVIDIA's Scalable Hierarchical Aggregation and Reduction Protocol (SHARP) with an on-chip ALU performing FP8 (E4M3) vector reductions on the fly.
7. **UPF Low-Power Telemetry:** Fine-grained clock and power-gating hooks for idle virtual channels.

---

## 2. Top-Level Architecture

```
                  +---------------------------------------------------+
                  |                 MICRO-NVSWITCH                    |
                  |                                                   |
 Input Port 0 --->| [VC0..VC3] ---\                                   |---> Output Port 0
 Input Port 1 --->| [VC0..VC3] ----\     +--------------------+       |---> Output Port 1
 Input Port 2 --->| [VC0..VC3] ----->---|    iSLIP Switch    |       |---> Output Port 2
 Input Port 3 --->| [VC0..VC3] ----/     |     Allocator      |       |---> Output Port 3
 Input Port 4 --->| [VC0..VC3] ---/      +--------------------+       |---> Output Port 4
 Input Port 5 --->| [VC0..VC3] ---\                |                  |---> Output Port 5
 Input Port 6 --->| [VC0..VC3] ----\     +--------------------+       |---> Output Port 6
 Input Port 7 --->| [VC0..VC3] ----->---| 8x8 Crossbar Matrix |------>|---> Output Port 7
                  |                      +--------------------+       |
                  |                                |                  |
                  |                      +--------------------+       |
                  |                      |   SHARP FP8 ALU    |       |
                  |                      | (In-Network Red.)  |       |
                  |                      +--------------------+       |
                  +---------------------------------------------------+
```

### 2.1 Interface Signal Definitions

| Signal Group | Port Name | Direction | Width | Description |
| :--- | :--- | :---: | :---: | :--- |
| **System** | `clk` | Input | 1 | Primary clock (1.25 GHz target on 7nm FinFET) |
| | `rst_n` | Input | 1 | Active-low asynchronous reset |
| **Upstream Rx** | `i_flit_valid` | Input | 8 | Flit valid flag (1 bit per port) |
| | `i_flit_type` | Input | 16 | Flit framing type: Head (00), Body (01), Tail (10), Single (11) |
| | `i_flit_vc` | Input | 16 | Target Virtual Channel index (2 bits per port: VC0..VC3) |
| | `i_flit_data` | Input | 512 | Flit payload (64 bits per port) |
| | `o_credit_ret` | Output | 32 | Credit return pulse to upstream sender (4 VCs x 8 ports) |
| **Downstream Tx** | `o_flit_valid` | Output | 8 | Transmitted flit valid flag (1 bit per port) |
| | `o_flit_type` | Output | 16 | Egress flit framing type |
| | `o_flit_vc` | Output | 16 | Egress Virtual Channel index |
| | `o_flit_data` | Output | 512 | Transmitted flit payload |
| | `i_credit_ret` | Input | 32 | Credit return pulse from downstream receiver |
| **Telemetry** | `o_occupancy` | Output | 128 | Real-time buffer fill levels (4 bits x 4 VCs x 8 ports) |
| | `o_vc_idle` | Output | 32 | Power-gating activity indicator (1 bit per VC) |
| | `o_sharp_active` | Output | 1 | High when in-network reduction engine is executing |
| | `o_sharp_result` | Output | 64 | Reduced FP8 vector output |

---

## 3. Protocol & Packet Framing

The router operates on fixed-width **Flow Control Units (Flits)** of 64 bits of data plus 2 bits of framing header:

### 3.1 Flit Types
- `2'b00` - **HEAD**: Carries routing header, multicast mask, packet ID, and SHARP opcode.
- `2'b01` - **BODY**: Raw data payload.
- `2'b10` - **TAIL**: Last flit of a packet; deallocates the virtual channel and resets packet active states.
- `2'b11` - **SINGLE**: Atomic single-flit packet (HEAD + TAIL combined).

### 3.2 Header Flit Bit-Field Breakdown (`[63:0]`)

```
 63          56 55      53 52      45 44      42 41 40 39                     0
+--------------+----------+----------+----------+-----+------------------------+
|  dest_mask   |  src_id  |  pkt_id  | sharp_op | RSV |      head_payload      |
|   (8 bits)   | (3 bits) | (8 bits) | (3 bits) | (2) |       (40 bits)        |
+--------------+----------+----------+----------+-----+------------------------+
```

- `dest_mask [63:56]`: 8-bit one-hot or bitmask for multicast. Bit $k=1$ indicates destination Output Port $k$.
  - Unicast to Port 3: `8'b00001000`
  - All-Reduce Broadcast to all 8 ports: `8'b11111111`
- `src_id [55:53]`: Source port ID (0..7).
- `pkt_id [52:45]`: 8-bit sequence number for end-to-end ordering.
- `sharp_op [44:42]`: In-network compute reduction opcode:
  - `3'b000`: `SHARP_OP_NONE` (Standard crossbar routing)
  - `3'b001`: `SHARP_OP_FP8_SUM` (Vector sum of 8 x FP8 E4M3 values)
  - `3'b010`: `SHARP_OP_FP8_MAX` (Element-wise vector max)
  - `3'b011`: `SHARP_OP_FP8_MIN` (Element-wise vector min)
  - `3'b100`: `SHARP_OP_INT32` (2 x 32-bit integer vector add)
  - `3'b101`: `SHARP_OP_XOR` (64-bit bitwise XOR reduction)

---

## 4. Lossless Credit-Based Flow Control

Standard Valid/Ready streaming interfaces suffer from combinational backpressure loops and link-latency bubbles. Micro-NVSwitch employs **credit-based flow control**:

```
Upstream Sender                                     Downstream Router
+-----------------------+                         +-----------------------+
|  Credit Counter = 8   |                         |  VC Buffer (Depth 8)  |
|                       |  --- Flit Transmit ---> |                       |
|  Transmit if cred > 0 |                         |  Queue Flit           |
|  cred <= cred - 1     |                         |                       |
|                       |  <-- Credit Return ---- |  Flit Read & Egress   |
|  cred <= cred + 1     |      (credit_ret = 1)   |  Pulse credit_ret = 1 |
+-----------------------+                         +-----------------------+
```

### 4.1 Invariants & Correctness Guarantees
1. **Zero Buffer Overflow:** Upstream never transmits unless downstream credits $> 0$. Since downstream initial credits equal buffer depth $D=8$, downstream queue occupancy strictly satisfies $0 \le \text{occupancy} \le D$.
2. **Zero Underflow:** Credit returns only pulse when a flit is legitimately dequeued from the buffer.
3. **Lossless Transmission:** Packets are never dropped due to congestion; backpressure gracefully holds flits in upstream buffers.

---

## 5. Virtual Channel Architecture & HoL Blocking Avoidance

Head-of-Line (HoL) blocking occurs when a blocked packet at the head of a FIFO prevents subsequent packets destined for uncongested ports from advancing.

Micro-NVSwitch solves this by providing **4 independent Virtual Channels per physical port**:
- Each VC has its own dedicated 8-flit FIFO buffer.
- The input port arbiter evaluates the destination port of the packet at the head of each VC.
- If VC 0 is destined to a congested/stalled output port (credits $=0$), the candidate selector **bypasses VC 0 and selects VC 1**, allowing VC 1's traffic to traverse the crossbar without delay.

---

## 6. Switch Allocation: Multi-Stage iSLIP Algorithm

Crossbar arbitration is performed by an **8x8 iSLIP switch allocator** based on Nick McKeown's landmark algorithm:

### 6.1 Three-Phase Matching
1. **Request:** Each non-empty input port with available downstream credits sends requests to its destination output port(s) via the $8 \times 8$ `req_matrix`.
2. **Grant:** Each output port $j$ selects one requesting input $i$ using a round-robin arbiter with priority pointer $g_j$.
3. **Accept & Pointer Update:**
   - The selected input $i$ is granted to output $j$.
   - **Crucial iSLIP Property:** Output grant pointer $g_j$ updates to $(winner + 1) \pmod 8$ **only when a grant is made**. Pointers do not advance during idle cycles, preventing arbiter synchronization and ensuring 100% throughput under uniform traffic.

### 6.2 Multicast Extension
Unlike unicast crossbars where an input can only connect to 1 output, Micro-NVSwitch's crossbar distribution bus connects each input port to all 8 output multiplexers. If an input requests multiple outputs (multicast `dest_mask`), all output arbiters that grant to this input transmit the flit concurrently in the same cycle!

---

## 7. In-Network Compute: SHARP FP8 Reduction ALU

To offload All-Reduce collectives in distributed LLM training, Micro-NVSwitch integrates an in-network reduction coprocessor:

```
                  64-bit Flit A: [FP8_7][FP8_6][FP8_5][FP8_4][FP8_3][FP8_2][FP8_1][FP8_0]
                  64-bit Flit B: [FP8_7][FP8_6][FP8_5][FP8_4][FP8_3][FP8_2][FP8_1][FP8_0]
                                        |      |      |      |      |      |      |      |
                                        v      v      v      v      v      v      v      v
                              +-------------------------------------------------------+
                              |         8 x Parallel FP8 E4M3 Reduction Units         |
                              |   (Exponent align, mantissa add, normalize, saturate) |
                              +-------------------------------------------------------+
                                        |      |      |      |      |      |      |      |
                                        v      v      v      v      v      v      v      v
                  64-bit Result: [RES_7][RES_6][RES_5][RES_4][RES_3][RES_2][RES_1][RES_0]
```

- **Format:** FP8 E4M3 (1 sign, 4 exponent with bias 7, 3 mantissa). Max value: 448.
- **Hardware Efficiency:** Unpacks 8 elements in parallel, aligns mantissas using 4-bit barrel shifters, performs 10-bit signed addition, normalizes, and saturates on overflow.
- **Latency:** 1 pipelined clock cycle.

---

## 8. Pipeline Microarchitecture

```
Cycle 1: [ Input Buffering (IB) ]
         - Flit arrived at physical port; demultiplexed into targeted VC buffer.
         - Credit return generated upstream if read is active.

Cycle 2: [ Route Compute & Switch Allocation (RC / SA) ]
         - Candidate VC selected among unblocked VCs.
         - Header dest_mask decoded.
         - Downstream credit availability checked.
         - iSLIP arbiter resolves output port contention.

Cycle 3: [ Crossbar Traversal (ST) ]
         - 8x8 multiplexer array routes flit data from winning inputs to output registers.
         - Optional SHARP FP8 ALU executes in-network reduction.

Cycle 4: [ Link Traversal (LT) ]
         - Flit emerges at output port pins; downstream credit decremented.
```

Total zero-load latency: **2 clock cycles** from ingress to egress.
