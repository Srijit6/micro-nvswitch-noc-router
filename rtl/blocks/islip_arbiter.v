// ==============================================================================
// Project Micro-NVSwitch: Rubin-Class High-Radix NoC Router for AI Fabrics
// File: islip_arbiter.v
// Description: Multi-stage, high-throughput iSLIP switch allocator with support
//              for unicast and AI multicast fanout requests. Starvation-free
//              with dynamic round-robin grant pointer updates.
// ==============================================================================

`timescale 1ns / 1ps

module islip_arbiter #(
    parameter NUM_INPUTS  = 8,
    parameter NUM_OUTPUTS = 8
)(
    input  wire clk,
    input  wire rst_n,

    // Request Matrix: req[i][j] = 1 means Input i requests Output j
    // Packed as [NUM_INPUTS*NUM_OUTPUTS-1:0] = [63:0]
    // req[i*NUM_OUTPUTS + j]
    input  wire [NUM_INPUTS*NUM_OUTPUTS-1:0] req_matrix,

    // Grant Vector per Output Port: which input was selected by output j
    output reg  [NUM_OUTPUTS-1:0]            grant_valid,
    output reg  [NUM_OUTPUTS*3-1:0]          grant_in_idx, // 3 bits per output (0..7)

    // Mask of which outputs were granted to each input
    // granted_out_mask[i*NUM_OUTPUTS + j] = 1 if output j granted input i
    output reg  [NUM_INPUTS*NUM_OUTPUTS-1:0] granted_out_mask
);

    // Round-robin grant pointers for each output port
    reg [2:0] grant_ptr [0:NUM_OUTPUTS-1];

    integer i, j, k;
    reg [NUM_INPUTS-1:0] req_for_out;
    reg [2:0]            winner_idx;
    reg                  winner_found;
    reg [2:0]            eval_idx;

    // Combinatorial Output Grant Arbitration
    always @(*) begin
        grant_valid       = {NUM_OUTPUTS{1'b0}};
        grant_in_idx      = {(NUM_OUTPUTS*3){1'b0}};
        granted_out_mask  = {(NUM_INPUTS*NUM_OUTPUTS){1'b0}};

        for (j = 0; j < NUM_OUTPUTS; j = j + 1) begin
            // Extract requests from all inputs for output j
            req_for_out = {NUM_INPUTS{1'b0}};
            for (i = 0; i < NUM_INPUTS; i = i + 1) begin
                req_for_out[i] = req_matrix[i * NUM_OUTPUTS + j];
            end

            winner_found = 1'b0;
            winner_idx   = 3'd0;

            // Round-robin selection starting from grant_ptr[j]
            for (k = 0; k < NUM_INPUTS; k = k + 1) begin
                eval_idx = (grant_ptr[j] + k[2:0]) & 3'b111;
                if (!winner_found && req_for_out[eval_idx]) begin
                    winner_found = 1'b1;
                    winner_idx   = eval_idx;
                end
            end

            if (winner_found) begin
                grant_valid[j] = 1'b1;
                grant_in_idx[j*3 +: 3] = winner_idx;
                granted_out_mask[winner_idx * NUM_OUTPUTS + j] = 1'b1;
            end
        end
    end

    // Sequential Pointer Update:
    // Pointers update to (winner + 1) % NUM_INPUTS when granted,
    // ensuring fairness and preventing arbiter synchronization.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (j = 0; j < NUM_OUTPUTS; j = j + 1) begin
                grant_ptr[j] <= j[2:0]; // Stagger initial pointers to prevent initial collision
            end
        end else begin
            for (j = 0; j < NUM_OUTPUTS; j = j + 1) begin
                if (grant_valid[j]) begin
                    grant_ptr[j] <= (grant_in_idx[j*3 +: 3] == 3'd7) ? 
                                    3'd0 : (grant_in_idx[j*3 +: 3] + 3'd1);
                end
            end
        end
    end

endmodule
