// ==============================================================================
// Project Micro-NVSwitch: Rubin-Class High-Radix NoC Router for AI Fabrics
// File: router_top.v
// Description: Top-level 8x8 NoC Router featuring:
//              - 8 physical Input Ports and 8 physical Output Ports
//              - 4 Virtual Channels per port with independent buffer queues
//              - Credit-based flow control upstream and downstream (zero drop)
//              - Output-VC allocation (wormhole packet ownership of output VCs)
//              - HoL-blocking-free VC switch allocation
//              - Multi-stage iSLIP switch allocation
//              - AI Multicast routing with fanout handling
//              - Integrated SHARP FP8 in-network reduction ALU
//              - Low-power activity telemetry for UPF clock/power gating
//
// Pipeline per packet:
//   VA (head/single at buffer front reserves ALL its output VCs atomically)
//   -> SA (iSLIP, per-flit, partial multicast service tracked per input VC)
//   -> ST (crossbar + output pipeline register)
// ==============================================================================

`timescale 1ns / 1ps
`include "router_pkg.v"

module router_top #(
    parameter DATA_WIDTH = 64,
    parameter NUM_PORTS  = 8,
    parameter NUM_VCS    = 4,
    parameter VC_DEPTH   = 8
)(
    input  wire clk,
    input  wire rst_n,

    // -------------------------------------------------------------------------
    // Upstream Interface (8 Input Ports)
    // -------------------------------------------------------------------------
    input  wire [NUM_PORTS-1:0]                  i_flit_valid,
    input  wire [NUM_PORTS*`FLIT_TYPE_WIDTH-1:0] i_flit_type,
    input  wire [NUM_PORTS*`VC_ID_WIDTH-1:0]    i_flit_vc,
    input  wire [NUM_PORTS*DATA_WIDTH-1:0]       i_flit_data,
    output wire [NUM_PORTS*NUM_VCS-1:0]          o_credit_ret,

    // -------------------------------------------------------------------------
    // Downstream Interface (8 Output Ports)
    // -------------------------------------------------------------------------
    output wire [NUM_PORTS-1:0]                  o_flit_valid,
    output wire [NUM_PORTS*`FLIT_TYPE_WIDTH-1:0] o_flit_type,
    output wire [NUM_PORTS*`VC_ID_WIDTH-1:0]    o_flit_vc,
    output wire [NUM_PORTS*DATA_WIDTH-1:0]       o_flit_data,
    input  wire [NUM_PORTS*NUM_VCS-1:0]          i_credit_ret,

    // -------------------------------------------------------------------------
    // Power & Performance Telemetry (for UPF / Verification)
    // -------------------------------------------------------------------------
    output wire [NUM_PORTS*NUM_VCS*4-1:0]        o_occupancy,
    output wire [NUM_PORTS*NUM_VCS-1:0]          o_vc_idle,
    output wire                                  o_sharp_active,
    output wire [DATA_WIDTH-1:0]                 o_sharp_result
);

    localparam FLIT_BUF_WIDTH = `FLIT_TYPE_WIDTH + DATA_WIDTH; // 2 + 64 = 66 bits

    // -------------------------------------------------------------------------
    // Downstream Credit Tracking (per Output Port and per VC)
    // -------------------------------------------------------------------------
    reg [3:0] downstream_credits [0:NUM_PORTS-1][0:NUM_VCS-1];

    // -------------------------------------------------------------------------
    // Input VC Buffer Arrays
    // -------------------------------------------------------------------------
    wire [NUM_VCS-1:0]          vc_wr_en      [0:NUM_PORTS-1];
    wire [FLIT_BUF_WIDTH-1:0]   vc_wr_data    [0:NUM_PORTS-1];
    reg  [NUM_VCS-1:0]          vc_rd_en      [0:NUM_PORTS-1];
    wire [FLIT_BUF_WIDTH-1:0]   vc_rd_data    [0:NUM_PORTS-1][0:NUM_VCS-1];
    wire [NUM_VCS-1:0]          vc_empty      [0:NUM_PORTS-1];
    /* verilator lint_off UNUSEDSIGNAL */
    wire [NUM_VCS-1:0]          vc_full       [0:NUM_PORTS-1];
    /* verilator lint_on UNUSEDSIGNAL */
    wire [3:0]                  vc_occupancy  [0:NUM_PORTS-1][0:NUM_VCS-1];
    wire [NUM_VCS-1:0]          vc_credit_ret [0:NUM_PORTS-1];
    wire [NUM_VCS-1:0]          vc_idle_w     [0:NUM_PORTS-1];

    genvar p, v;
    generate
        for (p = 0; p < NUM_PORTS; p = p + 1) begin : gen_input_port
            wire [1:0] in_vc = i_flit_vc[p*2 +: 2];
            assign vc_wr_data[p] = {i_flit_type[p*2 +: 2], i_flit_data[p*DATA_WIDTH +: DATA_WIDTH]};

            for (v = 0; v < NUM_VCS; v = v + 1) begin : gen_vc_inst
                assign vc_wr_en[p][v] = i_flit_valid[p] && (in_vc == v[1:0]);
                assign o_credit_ret[p*NUM_VCS + v] = vc_credit_ret[p][v];
                assign o_vc_idle[p*NUM_VCS + v]    = vc_idle_w[p][v];
                assign o_occupancy[(p*NUM_VCS + v)*4 +: 4] = vc_occupancy[p][v];

                vc_buffer #(
                    .DATA_WIDTH(FLIT_BUF_WIDTH),
                    .DEPTH(VC_DEPTH)
                ) u_vc_buffer (
                    .clk        (clk),
                    .rst_n      (rst_n),
                    .wr_en      (vc_wr_en[p][v]),
                    .wr_data    (vc_wr_data[p]),
                    .rd_en      (vc_rd_en[p][v]),
                    .rd_data    (vc_rd_data[p][v]),
                    .empty      (vc_empty[p][v]),
                    .full       (vc_full[p][v]),
                    .occupancy  (vc_occupancy[p][v]),
                    .credit_ret (vc_credit_ret[p][v]),
                    .idle       (vc_idle_w[p][v])
                );
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Per-Input-VC Packet State (Wormhole Flow Control)
    // Route state is captured from the head flit at the FRONT of the buffer
    // (not at enqueue), so a following packet's head that is already queued
    // can never redirect the body flits of the packet in progress.
    // -------------------------------------------------------------------------
    reg                 vc_routed    [0:NUM_PORTS-1][0:NUM_VCS-1]; // output VCs owned
    reg [NUM_PORTS-1:0] vc_cur_dest  [0:NUM_PORTS-1][0:NUM_VCS-1]; // packet dest mask
    reg [2:0]           vc_cur_sharp [0:NUM_PORTS-1][0:NUM_VCS-1]; // packet SHARP op
    reg [NUM_PORTS-1:0] vc_served    [0:NUM_PORTS-1][0:NUM_VCS-1]; // outputs done for front flit

    // Output VC ownership: set when a packet is VC-allocated, cleared when its
    // TAIL/SINGLE flit leaves on that output. Prevents packet interleaving.
    reg                 out_vc_locked [0:NUM_PORTS-1][0:NUM_VCS-1];

    // Front-of-queue decode helpers
    reg [1:0]           front_type [0:NUM_PORTS-1][0:NUM_VCS-1];
    reg                 front_hdr  [0:NUM_PORTS-1][0:NUM_VCS-1];
    reg [NUM_PORTS-1:0] front_dest [0:NUM_PORTS-1][0:NUM_VCS-1];

    integer fp, fv;
    always @(*) begin
        for (fp = 0; fp < NUM_PORTS; fp = fp + 1) begin
            for (fv = 0; fv < NUM_VCS; fv = fv + 1) begin
                front_type[fp][fv] = vc_rd_data[fp][fv][65:64];
                front_hdr[fp][fv]  = (vc_rd_data[fp][fv][65:64] == `FLIT_TYPE_HEAD) ||
                                     (vc_rd_data[fp][fv][65:64] == `FLIT_TYPE_SINGLE);
                front_dest[fp][fv] = vc_rd_data[fp][fv][`HDR_DEST_MASK_LSB +: 8];
            end
        end
    end

    // -------------------------------------------------------------------------
    // VC Allocator (VA)
    // For each VC independently, scan input ports in rotating priority order.
    // A head/single flit at the buffer front is granted only if ALL of its
    // destination output VCs are free, and reserves them all in the same cycle.
    // Atomic all-or-nothing reservation makes multicast wormhole deadlock-free.
    // -------------------------------------------------------------------------
    reg [2:0]           va_ptr;
    reg                 va_grant [0:NUM_PORTS-1][0:NUM_VCS-1];
    reg [NUM_PORTS-1:0] va_busy;
    reg [2:0]           va_idx;
    integer va_v, va_s, va_o, va_p;

    always @(*) begin
        for (va_p = 0; va_p < NUM_PORTS; va_p = va_p + 1)
            for (va_v = 0; va_v < NUM_VCS; va_v = va_v + 1)
                va_grant[va_p][va_v] = 1'b0;

        for (va_v = 0; va_v < NUM_VCS; va_v = va_v + 1) begin
            for (va_o = 0; va_o < NUM_PORTS; va_o = va_o + 1)
                va_busy[va_o] = out_vc_locked[va_o][va_v];

            for (va_s = 0; va_s < NUM_PORTS; va_s = va_s + 1) begin
                va_idx = va_ptr + va_s[2:0];
                if (!vc_empty[va_idx][va_v] && !vc_routed[va_idx][va_v] &&
                    front_hdr[va_idx][va_v] && (front_dest[va_idx][va_v] != 8'd0) &&
                    ((front_dest[va_idx][va_v] & va_busy) == 8'd0)) begin
                    va_grant[va_idx][va_v] = 1'b1;
                    va_busy = va_busy | front_dest[va_idx][va_v];
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Input Port VC Selection (HoL Blocking-Free)
    // A VC is eligible when it owns its output VCs and at least one not-yet-
    // served destination has a downstream credit.
    // -------------------------------------------------------------------------
    reg [1:0] cand_vc        [0:NUM_PORTS-1];
    reg       cand_valid     [0:NUM_PORTS-1];
    reg [7:0] cand_dest_mask [0:NUM_PORTS-1];
    reg [1:0] vc_rr_ptr      [0:NUM_PORTS-1];

    reg [7:0]         vc_avail    [0:NUM_PORTS-1][0:NUM_VCS-1];
    reg [NUM_VCS-1:0] vc_eligible [0:NUM_PORTS-1];

    integer port_i, step_i, check_v, chk_p;
    reg [1:0] eval_vc;

    always @(*) begin
        // Step 1: Remaining destinations with credits for each VC
        for (port_i = 0; port_i < NUM_PORTS; port_i = port_i + 1) begin
            for (check_v = 0; check_v < NUM_VCS; check_v = check_v + 1) begin
                for (chk_p = 0; chk_p < NUM_PORTS; chk_p = chk_p + 1) begin
                    vc_avail[port_i][check_v][chk_p] =
                        vc_cur_dest[port_i][check_v][chk_p] &&
                        !vc_served[port_i][check_v][chk_p] &&
                        (downstream_credits[chk_p][check_v] != 4'd0);
                end
                vc_eligible[port_i][check_v] = !vc_empty[port_i][check_v] &&
                                               vc_routed[port_i][check_v] &&
                                               (vc_avail[port_i][check_v] != 8'd0);
            end
        end

        // Step 2: Round-robin select among eligible VCs
        for (port_i = 0; port_i < NUM_PORTS; port_i = port_i + 1) begin
            cand_valid[port_i]     = 1'b0;
            cand_vc[port_i]        = 2'd0;
            cand_dest_mask[port_i] = 8'd0;

            for (step_i = 0; step_i < NUM_VCS; step_i = step_i + 1) begin
                eval_vc = vc_rr_ptr[port_i] + step_i[1:0];
                if (!cand_valid[port_i] && vc_eligible[port_i][eval_vc]) begin
                    cand_valid[port_i]     = 1'b1;
                    cand_vc[port_i]        = eval_vc;
                    cand_dest_mask[port_i] = vc_avail[port_i][eval_vc];
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Request Matrix (credit gating already folded into cand_dest_mask)
    // req_matrix[in_port * 8 + out_port] = 1 if input requests output
    // -------------------------------------------------------------------------
    reg [63:0] req_matrix;
    integer in_p, out_p;
    always @(*) begin
        req_matrix = 64'd0;
        for (in_p = 0; in_p < NUM_PORTS; in_p = in_p + 1) begin
            for (out_p = 0; out_p < NUM_PORTS; out_p = out_p + 1) begin
                req_matrix[in_p * NUM_PORTS + out_p] = cand_valid[in_p] && cand_dest_mask[in_p][out_p];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Switch Allocator (iSLIP)
    // -------------------------------------------------------------------------
    wire [NUM_PORTS-1:0] grant_valid;
    wire [23:0]          grant_in_idx;
    wire [63:0]          granted_out_mask;

    islip_arbiter #(
        .NUM_INPUTS(8),
        .NUM_OUTPUTS(8)
    ) u_switch_allocator (
        .clk              (clk),
        .rst_n            (rst_n),
        .req_matrix       (req_matrix),
        .grant_valid      (grant_valid),
        .grant_in_idx     (grant_in_idx),
        .granted_out_mask (granted_out_mask)
    );

    // -------------------------------------------------------------------------
    // Read Enable and Buffer Dequeue Logic
    // A flit is popped only once every destination of its packet has been
    // served (multicast flits may be served over several cycles).
    // -------------------------------------------------------------------------
    reg [7:0] port_grant [0:NUM_PORTS-1];
    reg       port_sent  [0:NUM_PORTS-1];
    integer r_p;
    always @(*) begin
        for (r_p = 0; r_p < NUM_PORTS; r_p = r_p + 1) begin
            port_grant[r_p] = granted_out_mask[r_p * NUM_PORTS +: 8];
            port_sent[r_p]  = cand_valid[r_p] && (port_grant[r_p] != 8'd0);
            vc_rd_en[r_p]   = {NUM_VCS{1'b0}};
            if (port_sent[r_p] &&
                ((vc_served[r_p][cand_vc[r_p]] | port_grant[r_p]) == vc_cur_dest[r_p][cand_vc[r_p]])) begin
                vc_rd_en[r_p][cand_vc[r_p]] = 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Crossbar Inputs Multiplexing
    // -------------------------------------------------------------------------
    reg [7:0]               xbar_in_valid;
    reg [8*2-1:0]           xbar_in_flit_type;
    reg [8*2-1:0]           xbar_in_vc;
    reg [8*DATA_WIDTH-1:0]  xbar_in_data;

    integer xp;
    always @(*) begin
        xbar_in_valid     = 8'd0;
        xbar_in_flit_type = 16'd0;
        xbar_in_vc        = 16'd0;
        xbar_in_data      = {(8*DATA_WIDTH){1'b0}};

        for (xp = 0; xp < NUM_PORTS; xp = xp + 1) begin
            if (port_sent[xp]) begin
                xbar_in_valid[xp] = 1'b1;
                xbar_in_flit_type[xp*2 +: 2] = vc_rd_data[xp][cand_vc[xp]][65:64];
                xbar_in_vc[xp*2 +: 2]        = cand_vc[xp];
                xbar_in_data[xp*DATA_WIDTH +: DATA_WIDTH] = vc_rd_data[xp][cand_vc[xp]][63:0];
            end
        end
    end

    // Per-output view of the flit being switched this cycle
    reg [1:0] out_send_vc   [0:NUM_PORTS-1];
    reg       out_send_last [0:NUM_PORTS-1]; // TAIL or SINGLE -> releases output VC
    reg [2:0] out_src;
    integer so;
    always @(*) begin
        for (so = 0; so < NUM_PORTS; so = so + 1) begin
            out_src           = grant_in_idx[so*3 +: 3];
            out_send_vc[so]   = xbar_in_vc[out_src*2 +: 2];
            out_send_last[so] = (xbar_in_flit_type[out_src*2 +: 2] == `FLIT_TYPE_TAIL) ||
                                (xbar_in_flit_type[out_src*2 +: 2] == `FLIT_TYPE_SINGLE);
        end
    end

    // -------------------------------------------------------------------------
    // Downstream Credit Tracking Logic
    // Debit at switch-grant time (same cycle the request saw the credit), so a
    // flit already in the output pipeline is never double-counted. Credit on
    // i_credit_ret.
    // -------------------------------------------------------------------------
    integer op, ov;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (op = 0; op < NUM_PORTS; op = op + 1) begin
                for (ov = 0; ov < NUM_VCS; ov = ov + 1) begin
                    downstream_credits[op][ov] <= VC_DEPTH[3:0];
                end
            end
        end else begin
            for (op = 0; op < NUM_PORTS; op = op + 1) begin
                for (ov = 0; ov < NUM_VCS; ov = ov + 1) begin
                    if (grant_valid[op] && (out_send_vc[op] == ov[1:0]) && !i_credit_ret[op*NUM_VCS + ov]) begin
                        downstream_credits[op][ov] <= downstream_credits[op][ov] - 4'd1;
                    end else if (!(grant_valid[op] && (out_send_vc[op] == ov[1:0])) && i_credit_ret[op*NUM_VCS + ov]) begin
                        downstream_credits[op][ov] <= downstream_credits[op][ov] + 4'd1;
                    end
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // VA / SA State Update
    // -------------------------------------------------------------------------
    integer sp, sv;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            va_ptr <= 3'd0;
            for (sp = 0; sp < NUM_PORTS; sp = sp + 1) begin
                vc_rr_ptr[sp] <= sp[1:0];
                for (sv = 0; sv < NUM_VCS; sv = sv + 1) begin
                    vc_routed[sp][sv]     <= 1'b0;
                    vc_cur_dest[sp][sv]   <= {NUM_PORTS{1'b0}};
                    vc_cur_sharp[sp][sv]  <= `SHARP_OP_NONE;
                    vc_served[sp][sv]     <= {NUM_PORTS{1'b0}};
                    out_vc_locked[sp][sv] <= 1'b0;
                end
            end
        end else begin
            va_ptr <= va_ptr + 3'd1;

            // VC allocation: capture route from the front head flit
            for (sp = 0; sp < NUM_PORTS; sp = sp + 1) begin
                for (sv = 0; sv < NUM_VCS; sv = sv + 1) begin
                    if (va_grant[sp][sv]) begin
                        vc_routed[sp][sv]    <= 1'b1;
                        vc_cur_dest[sp][sv]  <= front_dest[sp][sv];
                        vc_cur_sharp[sp][sv] <= vc_rd_data[sp][sv][`HDR_SHARP_OP_LSB +: 3];
                        vc_served[sp][sv]    <= {NUM_PORTS{1'b0}};
                    end
                end
            end

            // Switch traversal: track multicast service, release route on tail
            for (sp = 0; sp < NUM_PORTS; sp = sp + 1) begin
                if (port_sent[sp]) begin
                    vc_rr_ptr[sp] <= cand_vc[sp] + 2'd1;
                    if (vc_rd_en[sp][cand_vc[sp]]) begin
                        vc_served[sp][cand_vc[sp]] <= {NUM_PORTS{1'b0}};
                        if ((front_type[sp][cand_vc[sp]] == `FLIT_TYPE_TAIL) ||
                            (front_type[sp][cand_vc[sp]] == `FLIT_TYPE_SINGLE)) begin
                            vc_routed[sp][cand_vc[sp]] <= 1'b0;
                        end
                    end else begin
                        vc_served[sp][cand_vc[sp]] <= vc_served[sp][cand_vc[sp]] | port_grant[sp];
                    end
                end
            end

            // Output VC ownership (lock on VA grant, release when last flit leaves)
            for (sp = 0; sp < NUM_PORTS; sp = sp + 1) begin       // sp = output port
                for (sv = 0; sv < NUM_VCS; sv = sv + 1) begin
                    if (grant_valid[sp] && out_send_last[sp] && (out_send_vc[sp] == sv[1:0])) begin
                        out_vc_locked[sp][sv] <= 1'b0;
                    end
                end
            end
            for (sp = 0; sp < NUM_PORTS; sp = sp + 1) begin       // sp = input port
                for (sv = 0; sv < NUM_VCS; sv = sv + 1) begin
                    if (va_grant[sp][sv]) begin
                        for (op = 0; op < NUM_PORTS; op = op + 1) begin
                            if (front_dest[sp][sv][op]) out_vc_locked[op][sv] <= 1'b1;
                        end
                    end
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Crossbar Datapath (8x8)
    // -------------------------------------------------------------------------
    wire [7:0]              xbar_out_valid;
    wire [8*2-1:0]          xbar_out_flit_type;
    wire [8*2-1:0]          xbar_out_vc;
    wire [8*DATA_WIDTH-1:0] xbar_out_data;

    crossbar_8x8 #(
        .DATA_WIDTH(DATA_WIDTH),
        .PIPELINED(1)
    ) u_crossbar (
        .clk           (clk),
        .rst_n         (rst_n),
        .sel_valid     (grant_valid),
        .sel_in        (grant_in_idx),
        .in_valid      (xbar_in_valid),
        .in_flit_type  (xbar_in_flit_type),
        .in_vc         (xbar_in_vc),
        .in_data       (xbar_in_data),
        .out_valid     (xbar_out_valid),
        .out_flit_type (xbar_out_flit_type),
        .out_vc        (xbar_out_vc),
        .out_data      (xbar_out_data)
    );

    // -------------------------------------------------------------------------
    // SHARP In-Network Reduction Unit Integration
    // Reduces Input 0 (carrying the opcode) with Input 1; fires only when both
    // operands are actually being switched this cycle.
    // -------------------------------------------------------------------------
    wire [2:0]  sharp_op      = vc_cur_sharp[0][cand_vc[0]];
    wire        sharp_trigger = xbar_in_valid[0] && xbar_in_valid[1] && (sharp_op != `SHARP_OP_NONE);
    wire [63:0] sharp_alu_result;
    wire        sharp_alu_valid;

    sharp_alu u_sharp_alu (
        .clk          (clk),
        .rst_n        (rst_n),
        .enable       (sharp_trigger),
        .op_code      (sharp_op),
        .operand_a    (xbar_in_data[0*DATA_WIDTH +: DATA_WIDTH]),
        .operand_b    (xbar_in_data[1*DATA_WIDTH +: DATA_WIDTH]),
        .result       (sharp_alu_result),
        .result_valid (sharp_alu_valid)
    );

    assign o_sharp_active = sharp_trigger || sharp_alu_valid;
    assign o_sharp_result = sharp_alu_result;

    // Connect Crossbar Outputs to Router Output Ports
    assign o_flit_valid = xbar_out_valid;
    assign o_flit_type  = xbar_out_flit_type;
    assign o_flit_vc    = xbar_out_vc;
    assign o_flit_data  = xbar_out_data;

endmodule
