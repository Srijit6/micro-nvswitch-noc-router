// ==============================================================================
// Project Micro-NVSwitch: Rubin-Class High-Radix NoC Router for AI Fabrics
// File: vc_buffer.v
// Description: Parameterized Virtual Channel FIFO with credit-return generation
//              and clock-gating activity indication for UPF power optimization.
// ==============================================================================

`timescale 1ns / 1ps

module vc_buffer #(
    parameter DATA_WIDTH = 66,   // 64-bit flit_data + 2-bit flit_type
    parameter DEPTH      = 8     // VC buffer capacity (flits)
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // Write Interface (From input port demux)
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] wr_data,

    // Read Interface (To crossbar switch allocator)
    input  wire                  rd_en,
    output wire [DATA_WIDTH-1:0] rd_data,

    // Status & Flow Control
    output wire                  empty,
    output wire                  full,
    output reg  [3:0]            occupancy,   // Current flit count (0..DEPTH)
    output reg                   credit_ret,  // Pulses 1 when slot is freed
    output wire                  idle         // For dynamic clock-gating
);

    localparam ADDR_BITS = 3; // $clog2(8) = 3

    // Storage array (registers or mapped to RF/SRAM macro)
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    reg [ADDR_BITS-1:0]  wr_ptr;
    reg [ADDR_BITS-1:0]  rd_ptr;

    assign empty = (occupancy == 4'd0);
    assign full  = (occupancy == 4'd8);
    assign idle  = empty && !wr_en;

    // Look-ahead read: memory read output is continuous from rd_ptr
    assign rd_data = mem[rd_ptr];

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr     <= 3'd0;
            rd_ptr     <= 3'd0;
            occupancy  <= 4'd0;
            credit_ret <= 1'b0;
            for (i = 0; i < DEPTH; i = i + 1) begin
                mem[i] <= {DATA_WIDTH{1'b0}};
            end
        end else begin
            // Default credit return pulse
            credit_ret <= 1'b0;

            case ({wr_en && !full, rd_en && !empty})
                2'b10: begin // Write only
                    mem[wr_ptr] <= wr_data;
                    wr_ptr      <= (wr_ptr == 3'd7) ? 3'd0 : (wr_ptr + 3'd1);
                    occupancy   <= occupancy + 4'd1;
                end

                2'b01: begin // Read only
                    rd_ptr      <= (rd_ptr == 3'd7) ? 3'd0 : (rd_ptr + 3'd1);
                    occupancy   <= occupancy - 4'd1;
                    credit_ret  <= 1'b1; // Free a buffer slot
                end

                2'b11: begin // Simultaneous read and write
                    mem[wr_ptr] <= wr_data;
                    wr_ptr      <= (wr_ptr == 3'd7) ? 3'd0 : (wr_ptr + 3'd1);
                    rd_ptr      <= (rd_ptr == 3'd7) ? 3'd0 : (rd_ptr + 3'd1);
                    occupancy   <= occupancy; // Net zero change
                    credit_ret  <= 1'b1; // Slot was consumed and freed simultaneously
                end

                default: begin
                    // No write, no read
                end
            endcase
        end
    end

endmodule
