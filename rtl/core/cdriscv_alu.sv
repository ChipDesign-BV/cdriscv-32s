// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-10 -- arithmetic/logic unit.
//
// One shared 33-bit adder serves ADD/SUB and every comparison, so the
// comparison result and the arithmetic result are produced by the same
// hardware (fewer gates, and one fault site instead of two).
//
// STATUS: verified to the O1-O7 gate of doc/verification_plan.md
//         (2026-08-24) -- may be used in a project.  O8-O9 and the
//         FMEDA are open: NOT qualified for safety-critical use.

`default_nettype none

module cdriscv_alu
  import cdriscv_pkg::*;
(
    input  alu_op_e     operator_i,
    input  logic [31:0] operand_a_i,
    input  logic [31:0] operand_b_i,
    output logic [31:0] result_o
);

  // ------------------------------------------------------------------
  // Shared adder: a + b for ADD, a - b for everything else that needs
  // a magnitude comparison.
  // ------------------------------------------------------------------
  logic        sub;
  logic        cmp_signed;
  logic [32:0] op_a_ext, op_b_ext, adder_in_b;
  logic [32:0] adder_result;

  always_comb begin
    unique case (operator_i)
      ALU_ADD: sub = 1'b0;
      default: sub = 1'b1;
    endcase
  end

  always_comb begin
    unique case (operator_i)
      ALU_SLT, ALU_GE: cmp_signed = 1'b1;
      default:         cmp_signed = 1'b0;
    endcase
  end

  // Sign-extend for signed comparisons, zero-extend otherwise.  The
  // extra bit turns the signed compare into an unsigned one.
  assign op_a_ext   = {cmp_signed & operand_a_i[31], operand_a_i};
  assign op_b_ext   = {cmp_signed & operand_b_i[31], operand_b_i};
  assign adder_in_b = sub ? ~op_b_ext : op_b_ext;

  assign adder_result = op_a_ext + adder_in_b + {32'b0, sub};

  // a < b, in the selected signedness.  Both operands are extended to
  // 33 bits (sign extended for a signed compare, zero extended for an
  // unsigned one), so the difference always fits and cannot overflow;
  // bit 32 of the 33-bit result is therefore its sign, and the sign is
  // set exactly when a < b.
  //
  // Note this is the sign of the sum, not a carry-out: adder_result is
  // 33 bits wide, so the carry out of bit 32 is not kept.
  logic cmp_lt, cmp_eq;
  assign cmp_lt = adder_result[32];
  assign cmp_eq = (operand_a_i == operand_b_i);

  // ------------------------------------------------------------------
  // Shifter: one right shifter, left shifts are done by reversing the
  // operand on the way in and on the way out.
  // ------------------------------------------------------------------
  logic [4:0]  shift_amt;
  logic        shift_left, shift_arith;
  logic [31:0] shift_in, shift_in_rev, shift_out, shift_out_rev;
  logic [32:0] shift_ext;

  assign shift_amt = operand_b_i[4:0];

  always_comb begin
    unique case (operator_i)
      ALU_SLL: shift_left = 1'b1;
      default: shift_left = 1'b0;
    endcase
  end

  always_comb begin
    unique case (operator_i)
      ALU_SRA: shift_arith = 1'b1;
      default: shift_arith = 1'b0;
    endcase
  end

  always_comb begin
    for (int unsigned i = 0; i < 32; i++) begin
      shift_in_rev[i] = operand_a_i[31-i];
    end
  end

  assign shift_in  = shift_left ? shift_in_rev : operand_a_i;
  assign shift_ext = $signed({shift_arith & shift_in[31], shift_in}) >>> shift_amt;
  assign shift_out = shift_ext[31:0];

  always_comb begin
    for (int unsigned i = 0; i < 32; i++) begin
      shift_out_rev[i] = shift_out[31-i];
    end
  end

  // ------------------------------------------------------------------
  // Result mux
  // ------------------------------------------------------------------
  always_comb begin
    unique case (operator_i)
      ALU_ADD, ALU_SUB: result_o = adder_result[31:0];
      ALU_AND:          result_o = operand_a_i & operand_b_i;
      ALU_OR:           result_o = operand_a_i | operand_b_i;
      ALU_XOR:          result_o = operand_a_i ^ operand_b_i;
      ALU_SLL:          result_o = shift_out_rev;
      ALU_SRL, ALU_SRA: result_o = shift_out;
      ALU_SLT, ALU_SLTU:result_o = {31'b0,  cmp_lt};
      ALU_GE,  ALU_GEU: result_o = {31'b0, ~cmp_lt};
      ALU_EQ:           result_o = {31'b0,  cmp_eq};
      ALU_NE:           result_o = {31'b0, ~cmp_eq};
      ALU_PASSB:        result_o = operand_b_i;
      default:          result_o = '0;
    endcase
  end

endmodule
