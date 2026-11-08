// ==============================================================================
// Project Micro-NVSwitch: Rubin-Class High-Radix NoC Router for AI Fabrics
// File: sharp_alu.v
// Description: NVIDIA SHARP-emulating In-Network Compute ALU.
//              Performs vector reduction on 8 x FP8 (E4M3) elements per 64-bit
//              flit, including FP8 SUM, FP8 MAX/MIN, INT32 SUM, and bitwise XOR.
// ==============================================================================

`timescale 1ns / 1ps

module sharp_alu (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        enable,
    input  wire [2:0]  op_code,      // 001: FP8_SUM, 010: FP8_MAX, 011: FP8_MIN, 100: INT32_SUM, 101: XOR
    input  wire [63:0] operand_a,    // 8 x FP8 elements or 2 x INT32
    input  wire [63:0] operand_b,
    output reg  [63:0] result,
    output reg         result_valid
);

    // Operation codes
    localparam OP_FP8_SUM = 3'b001;
    localparam OP_FP8_MAX = 3'b010;
    localparam OP_FP8_MIN = 3'b011;
    localparam OP_INT32   = 3'b100;
    localparam OP_XOR     = 3'b101;

    // -------------------------------------------------------------------------
    // Function: FP8 E4M3 Element Addition
    // E4M3: 1 sign, 4 exp (bias 7), 3 mantissa. Max representable = 448.
    // -------------------------------------------------------------------------
    function [7:0] fp8_add_e4m3;
        input [7:0] a;
        input [7:0] b;

        reg        sign_a, sign_b, sign_r;
        reg [3:0]  exp_a, exp_b, exp_r;
        reg [3:0]  man_a, man_b; // 1 hidden bit + 3 mantissa bits
        reg [7:0]  align_a, align_b;
        reg signed [9:0] sum_val;
        reg [3:0]  diff;
        begin
            sign_a = a[7];
            sign_b = b[7];
            exp_a  = a[6:3];
            exp_b  = b[6:3];

            // Handle zero
            if (a[6:0] == 7'd0) begin
                fp8_add_e4m3 = b;
            end else if (b[6:0] == 7'd0) begin
                fp8_add_e4m3 = a;
            end else begin
                // Hidden bit (normal vs subnormal)
                man_a = (exp_a == 4'd0) ? {1'b0, a[2:0]} : {1'b1, a[2:0]};
                man_b = (exp_b == 4'd0) ? {1'b0, b[2:0]} : {1'b1, b[2:0]};

                if (exp_a >= exp_b) begin
                    exp_r   = exp_a;
                    diff    = exp_a - exp_b;
                    align_a = {man_a, 4'b0000};
                    align_b = (diff >= 4'd8) ? 8'd0 : ({man_b, 4'b0000} >> diff);
                end else begin
                    exp_r   = exp_b;
                    diff    = exp_b - exp_a;
                    align_b = {man_b, 4'b0000};
                    align_a = (diff >= 4'd8) ? 8'd0 : ({man_a, 4'b0000} >> diff);
                end

                // Signed addition
                if (sign_a == sign_b) begin
                    sum_val = {2'b00, align_a} + {2'b00, align_b};
                    sign_r  = sign_a;
                end else if (align_a >= align_b) begin
                    sum_val = {2'b00, align_a} - {2'b00, align_b};
                    sign_r  = sign_a;
                end else begin
                    sum_val = {2'b00, align_b} - {2'b00, align_a};
                    sign_r  = sign_b;
                end

                // Renormalize
                if (sum_val[8]) begin // Overflow carry
                    if (exp_r < 4'hE) begin
                        exp_r = exp_r + 1'b1;
                        sum_val = sum_val >> 1;
                    end else begin
                        exp_r = 4'hF; // Saturate
                        sum_val[6:4] = 3'b111;
                    end
                end

                if (sum_val == 10'd0) begin
                    fp8_add_e4m3 = 8'd0;
                end else begin
                    fp8_add_e4m3 = {sign_r, exp_r, sum_val[6:4]};
                end
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    // Function: FP8 E4M3 Element Comparison (Max / Min)
    // -------------------------------------------------------------------------
    function [7:0] fp8_compare;
        input [7:0] a;
        input [7:0] b;
        input       is_max; // 1 = Max, 0 = Min

        reg a_is_greater;
        begin
            if (a[7] != b[7]) begin
                // Opposite signs: positive is greater (with +0 == -0 handled)
                if (a[6:0] == 7'd0 && b[6:0] == 7'd0) begin
                    a_is_greater = 1'b0;
                end else begin
                    a_is_greater = (b[7] == 1'b1);
                end
            end else if (a[7] == 1'b0) begin
                // Both positive: larger magnitude is greater
                a_is_greater = (a[6:0] >= b[6:0]);
            end else begin
                // Both negative: smaller magnitude is greater
                a_is_greater = (a[6:0] <= b[6:0]);
            end

            if (is_max) begin
                fp8_compare = a_is_greater ? a : b;
            end else begin
                fp8_compare = a_is_greater ? b : a;
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    // Vector Compute Loop (8 FP8 slices or 2 INT32 slices)
    // -------------------------------------------------------------------------
    reg [63:0] comb_result;
    integer e;

    always @(*) begin
        comb_result = 64'd0;
        case (op_code)
            OP_FP8_SUM: begin
                for (e = 0; e < 8; e = e + 1) begin
                    comb_result[e*8 +: 8] = fp8_add_e4m3(operand_a[e*8 +: 8], operand_b[e*8 +: 8]);
                end
            end

            OP_FP8_MAX: begin
                for (e = 0; e < 8; e = e + 1) begin
                    comb_result[e*8 +: 8] = fp8_compare(operand_a[e*8 +: 8], operand_b[e*8 +: 8], 1'b1);
                end
            end

            OP_FP8_MIN: begin
                for (e = 0; e < 8; e = e + 1) begin
                    comb_result[e*8 +: 8] = fp8_compare(operand_a[e*8 +: 8], operand_b[e*8 +: 8], 1'b0);
                end
            end

            OP_INT32: begin
                comb_result[31:0]  = operand_a[31:0]  + operand_b[31:0];
                comb_result[63:32] = operand_a[63:32] + operand_b[63:32];
            end

            OP_XOR: begin
                comb_result = operand_a ^ operand_b;
            end

            default: begin
                comb_result = operand_a; // Pass-through
            end
        endcase
    end

    // Sequential Output Register
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result       <= 64'd0;
            result_valid <= 1'b0;
        end else begin
            result_valid <= enable;
            if (enable) begin
                result <= comb_result;
            end
        end
    end

endmodule
