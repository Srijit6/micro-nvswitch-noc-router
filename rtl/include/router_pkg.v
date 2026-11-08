// ==============================================================================
// Project Micro-NVSwitch: Rubin-Class High-Radix NoC Router for AI Fabrics
// File: router_pkg.v
// Description: Global parameters, flit definitions, and architectural constants.
// ==============================================================================

`ifndef ROUTER_PKG_V
`define ROUTER_PKG_V

// -----------------------------------------------------------------------------
// Core Architectural Constants
// -----------------------------------------------------------------------------
`define NUM_PORTS           8      // 8x8 Non-blocking Crossbar
`define NUM_VCS             4      // 4 Virtual Channels per Physical Port
`define VC_DEPTH            8      // Buffer depth per VC (in flits)
`define CREDIT_WIDTH        4      // Log2(VC_DEPTH) + 1 bits (counts 0..8)

`define FLIT_DATA_WIDTH     64     // 64-bit payload width (8 x FP8 elements)
`define FLIT_TYPE_WIDTH     2      // Head, Body, Tail, Single
`define VC_ID_WIDTH         2      // 2 bits for 4 VCs
`define PORT_ID_WIDTH       3      // 3 bits for 8 Ports
`define DEST_MASK_WIDTH     8      // 8-bit one-hot/multicast bitmask

// -----------------------------------------------------------------------------
// Flit Types
// -----------------------------------------------------------------------------
`define FLIT_TYPE_HEAD      2'b00  // First flit of a multi-flit packet
`define FLIT_TYPE_BODY      2'b01  // Payload flit
`define FLIT_TYPE_TAIL      2'b10  // Final flit of a packet
`define FLIT_TYPE_SINGLE    2'b11  // 1-flit atomic packet (Head + Tail)

// -----------------------------------------------------------------------------
// SHARP In-Network Compute Operations (FP8 All-Reduce)
// -----------------------------------------------------------------------------
`define SHARP_OP_NONE       3'b000 // Standard routing (no ALU reduction)
`define SHARP_OP_FP8_SUM    3'b001 // Element-wise FP8 Sum (8 x FP8 per flit)
`define SHARP_OP_FP8_MAX    3'b010 // Element-wise FP8 Max
`define SHARP_OP_FP8_MIN    3'b011 // Element-wise FP8 Min
`define SHARP_OP_INT32_SUM  3'b100 // 2 x Int32 Vector Sum
`define SHARP_OP_BITWISE_XOR 3'b101 // 64-bit Bitwise XOR reduction

// -----------------------------------------------------------------------------
// Header Flit Bit-Field Mapping inside [63:0] Data:
// [63:56] dest_mask    (8 bits: bit k = 1 -> route to Output Port k)
// [55:53] src_id       (3 bits: source port 0..7)
// [52:45] packet_id    (8 bits: sequence / tag)
// [44:42] sharp_op     (3 bits: SHARP in-network compute opcode)
// [41:40] reserved     (2 bits)
// [39:0]  head_payload (40 bits: header payload or initial vector elements)
// -----------------------------------------------------------------------------
`define HDR_DEST_MASK_MSB   63
`define HDR_DEST_MASK_LSB   56
`define HDR_SRC_ID_MSB      55
`define HDR_SRC_ID_LSB      53
`define HDR_PKT_ID_MSB      52
`define HDR_PKT_ID_LSB      45
`define HDR_SHARP_OP_MSB    44
`define HDR_SHARP_OP_LSB    42

`endif // ROUTER_PKG_V
