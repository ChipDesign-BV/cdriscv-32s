// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s -- sequential multiplier / divider (RV32M).
//
// One shift-add multiplier and one restoring divider, both 32 cycles,
// sharing the sign-correction logic.  Deliberately iterative: no wide
// combinational arrays, a short critical path, and a data-independent
// latency (always 32 iterations, also for a division by zero on the
// early-out path) so that execution time stays predictable, which
// matters for the WCET argument of a safety application.
//
// Handshake: assert req_i for one cycle while busy_o is low.  valid_o
// pulses for one cycle when result_o is valid.
//
// STATUS: verified to the O1-O7 gate of doc/verification_plan.md
//         (2026-08-24) -- may be used in a project.  O8-O9 and the
//         FMEDA are open: NOT qualified for safety-critical use.

`default_nettype none

module cdriscv_multdiv
  import cdriscv_pkg::*;
(
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic        req_i,
    input  md_op_e      operator_i,
    input  logic [31:0] operand_a_i,
    input  logic [31:0] operand_b_i,
    input  logic        kill_i,        // abort (flush on trap)

    output logic        busy_o,
    output logic        valid_o,
    output logic [31:0] result_o
);

  typedef enum logic [1:0] {
    MD_IDLE,
    MD_COMP,
    MD_FINISH
  } state_e;

  state_e      state_q, state_d;
  logic [5:0]  cnt_q;

  // latched operation attributes
  md_op_e      op_q;
  logic        is_div_q;      // division (as opposed to multiplication)
  logic        div_zero_q;    // divisor was zero
  logic [31:0] orig_a_q;      // original (unmodified) operand a
  logic        neg_res_q;     // negate the multiplication result
  logic        neg_quot_q;    // negate the quotient
  logic        neg_rem_q;     // negate the remainder

  // datapath registers
  logic [31:0] opa_q;         // multiplicand / divisor
  logic [31:0] num_q;         // multiplier / dividend
  logic [32:0] acc_q;         // product high part / partial remainder
  logic [31:0] quot_q;

  // ------------------------------------------------------------------
  // Operand preparation
  // ------------------------------------------------------------------
  logic signed_a, signed_b;

  always_comb begin
    unique case (operator_i)
      MD_MUL, MD_MULH: begin signed_a = 1'b1; signed_b = 1'b1; end
      MD_MULHSU:       begin signed_a = 1'b1; signed_b = 1'b0; end
      MD_MULHU:        begin signed_a = 1'b0; signed_b = 1'b0; end
      MD_DIV, MD_REM:  begin signed_a = 1'b1; signed_b = 1'b1; end
      default:         begin signed_a = 1'b0; signed_b = 1'b0; end  // DIVU / REMU
    endcase
  end

  logic        neg_a, neg_b;
  logic [31:0] abs_a, abs_b;

  assign neg_a = signed_a & operand_a_i[31];
  assign neg_b = signed_b & operand_b_i[31];
  assign abs_a = neg_a ? (~operand_a_i + 32'd1) : operand_a_i;
  assign abs_b = neg_b ? (~operand_b_i + 32'd1) : operand_b_i;

  logic is_div;
  assign is_div = (operator_i == MD_DIV)  || (operator_i == MD_DIVU) ||
                  (operator_i == MD_REM)  || (operator_i == MD_REMU);

  // ------------------------------------------------------------------
  // Iteration datapath
  // ------------------------------------------------------------------
  // multiply: acc_q holds the running high part, num_q the multiplier
  // and simultaneously collects the low part of the product.
  logic [32:0] mul_sum;
  assign mul_sum = num_q[0] ? ({1'b0, acc_q[31:0]} + {1'b0, opa_q})
                            : {1'b0, acc_q[31:0]};

  // divide: shift the dividend into the partial remainder, subtract
  // when it fits (restoring division).
  logic [32:0] rem_shifted, rem_sub;
  logic        rem_fits;
  assign rem_shifted = {acc_q[31:0], num_q[31]};
  assign rem_sub     = rem_shifted - {1'b0, opa_q};
  assign rem_fits    = (rem_shifted >= {1'b0, opa_q});

  // ------------------------------------------------------------------
  // Control
  // ------------------------------------------------------------------
  always_comb begin
    state_d = state_q;
    unique case (state_q)
      MD_IDLE:   if (req_i)          state_d = MD_COMP;
      MD_COMP:   if (cnt_q == 6'd31) state_d = MD_FINISH;
      MD_FINISH:                     state_d = MD_IDLE;
      default:                       state_d = MD_IDLE;
    endcase
    if (kill_i) state_d = MD_IDLE;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q    <= MD_IDLE;
      cnt_q      <= '0;
      op_q       <= MD_MUL;
      is_div_q   <= 1'b0;
      div_zero_q <= 1'b0;
      orig_a_q   <= '0;
      neg_res_q  <= 1'b0;
      neg_quot_q <= 1'b0;
      neg_rem_q  <= 1'b0;
      opa_q      <= '0;
      num_q      <= '0;
      acc_q      <= '0;
      quot_q     <= '0;
    end else begin
      state_q <= state_d;

      unique case (state_q)
        MD_IDLE: begin
          cnt_q <= '0;
          if (req_i) begin
            op_q       <= operator_i;
            is_div_q   <= is_div;
            div_zero_q <= is_div && (operand_b_i == 32'b0);
            orig_a_q   <= operand_a_i;
            neg_res_q  <= neg_a ^ neg_b;                 // multiplication
            neg_quot_q <= neg_a ^ neg_b;                 // division
            neg_rem_q  <= neg_a;                         // remainder follows the dividend
            opa_q      <= is_div ? abs_b : abs_a;        // divisor / multiplicand
            num_q      <= is_div ? abs_a : abs_b;        // dividend  / multiplier
            acc_q      <= '0;
            quot_q     <= '0;
          end
        end

        MD_COMP: begin
          cnt_q <= cnt_q + 6'd1;
          if (is_div_q) begin
            acc_q  <= rem_fits ? rem_sub : rem_shifted;
            num_q  <= {num_q[30:0], 1'b0};
            quot_q <= {quot_q[30:0], rem_fits};
          end else begin
            acc_q <= {1'b0, mul_sum[32:1]};
            num_q <= {mul_sum[0], num_q[31:1]};
          end
        end

        default: ;   // MD_FINISH: results are read combinationally
      endcase
    end
  end

  assign busy_o  = (state_q != MD_IDLE);
  assign valid_o = (state_q == MD_FINISH) && !kill_i;

  // ------------------------------------------------------------------
  // Result selection and sign correction
  // ------------------------------------------------------------------
  logic [63:0] product, product_corr;
  logic [31:0] quot_corr, rem_corr;

  assign product      = {acc_q[31:0], num_q};
  assign product_corr = neg_res_q ? (~product + 64'd1) : product;

  assign quot_corr = neg_quot_q ? (~quot_q + 32'd1) : quot_q;
  assign rem_corr  = neg_rem_q  ? (~acc_q[31:0] + 32'd1) : acc_q[31:0];

  always_comb begin
    unique case (op_q)
      MD_MUL:                 result_o = product_corr[31:0];
      MD_MULH, MD_MULHSU,
      MD_MULHU:               result_o = product_corr[63:32];
      MD_DIV, MD_DIVU:        result_o = div_zero_q ? 32'hffff_ffff : quot_corr;
      MD_REM, MD_REMU:        result_o = div_zero_q ? orig_a_q      : rem_corr;
      default:                result_o = '0;
    endcase
  end

endmodule
