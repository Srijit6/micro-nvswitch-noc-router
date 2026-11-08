// ==============================================================================
// Project Micro-NVSwitch: Rubin-Class High-Radix NoC Router for AI Fabrics
// File: crossbar_8x8.v
// Description: Fully connected, non-blocking 8x8 crossbar matrix with multicast
//              fanout support and optional pipelined output registers for Fmax.
// ==============================================================================

`timescale 1ns / 1ps

module crossbar_8x8 #(
    parameter DATA_WIDTH = 64,
    parameter PIPELINED  = 1   // 1 = Pipelined crossbar stage for 1GHz+ FinFET operation
)(
    input  wire clk,
    input  wire rst_n,

    // Multiplexer Controls from Switch Allocator
    input  wire [7:0]   sel_valid,      // [j] is 1 if Output j is granted
    input  wire [23:0]  sel_in,         // [j*3 +: 3] = input port index driving Output j

    // 8 Input Ports (packed)
    input  wire [7:0]               in_valid,
    input  wire [8*2-1:0]           in_flit_type,
    input  wire [8*2-1:0]           in_vc,
    input  wire [8*DATA_WIDTH-1:0]  in_data,

    // 8 Output Ports (packed)
    output reg  [7:0]               out_valid,
    output reg  [8*2-1:0]           out_flit_type,
    output reg  [8*2-1:0]           out_vc,
    output reg  [8*DATA_WIDTH-1:0]  out_data
);

    wire [7:0]              comb_out_valid;
    wire [8*2-1:0]          comb_out_flit_type;
    wire [8*2-1:0]          comb_out_vc;
    wire [8*DATA_WIDTH-1:0] comb_out_data;

    genvar j;
    generate
        for (j = 0; j < 8; j = j + 1) begin : gen_out_mux
            wire [2:0] in_idx = sel_in[j*3 +: 3];
            wire valid_match  = sel_valid[j] && in_valid[in_idx];

            assign comb_out_valid[j] = valid_match;
            assign comb_out_flit_type[j*2 +: 2] = valid_match ? in_flit_type[in_idx*2 +: 2] : 2'b00;
            assign comb_out_vc[j*2 +: 2]        = valid_match ? in_vc[in_idx*2 +: 2] : 2'b00;
            assign comb_out_data[j*DATA_WIDTH +: DATA_WIDTH] = 
                   valid_match ? in_data[in_idx*DATA_WIDTH +: DATA_WIDTH] : {DATA_WIDTH{1'b0}};
        end
    endgenerate

    // Pipelining / Output Assignment
    generate
        if (PIPELINED) begin : gen_pipelined_stage
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    out_valid     <= 8'd0;
                    out_flit_type <= 16'd0;
                    out_vc        <= 16'd0;
                    out_data      <= {(8*DATA_WIDTH){1'b0}};
                end else begin
                    out_valid     <= comb_out_valid;
                    out_flit_type <= comb_out_flit_type;
                    out_vc        <= comb_out_vc;
                    out_data      <= comb_out_data;
                end
            end
        end else begin : gen_combinatorial_stage
            always @(*) begin
                out_valid     = comb_out_valid;
                out_flit_type = comb_out_flit_type;
                out_vc        = comb_out_vc;
                out_data      = comb_out_data;
            end
        end
    endgenerate

endmodule
