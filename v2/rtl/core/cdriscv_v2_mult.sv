// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s v2 -- fast multiplier.
//
// Variant 1 multiplies iteratively, sharing a shift-and-add datapath
// with the divider: 32 cycles for any MUL.  Here the multiply is a
// single 33x33 signed product, so MUL/MULH/MULHSU/MULHU all retire in
// one cycle and only division remains iterative.
//
// The 33rd bit carries the sign, which is what lets one signed
// multiplier serve all four variants: each operand is sign-extended or
// zero-extended according to the operation, and the same array
// computes the 66-bit product.
//
//   MUL      low  32 bits, operand signedness irrelevant
//   MULH     high 32, both signed
//   MULHSU   high 32, a signed, b unsigned
//   MULHU    high 32, both unsigned
//
// Cost: one 33x33 array instead of a 32-cycle loop.  On this process
// that is the largest single block in the core, and it is why the
// multiplier is a variant-2 option rather than a variant-1 change.
//
// STATUS: NEW AND UNVERIFIED -- not through the O1-O9 gate.  Do not use.

`default_nettype none

module cdriscv_v2_mult
  import cdriscv_v2_pkg::*;
(
    input  md_op_e      operator_i,
    input  logic [31:0] operand_a_i,
    input  logic [31:0] operand_b_i,
    output logic [31:0] result_o
);

  logic a_signed, b_signed;
  always_comb begin
    unique case (operator_i)
      MD_MULH   : begin a_signed = 1'b1; b_signed = 1'b1; end
      MD_MULHSU : begin a_signed = 1'b1; b_signed = 1'b0; end
      MD_MULHU  : begin a_signed = 1'b0; b_signed = 1'b0; end
      default   : begin a_signed = 1'b1; b_signed = 1'b1; end  // MUL: low half
    endcase
  end

  logic signed [32:0] a_ext, b_ext;
  logic signed [65:0] product;
  assign a_ext   = {a_signed & operand_a_i[31], operand_a_i};
  assign b_ext   = {b_signed & operand_b_i[31], operand_b_i};
  assign product = a_ext * b_ext;

  assign result_o = (operator_i == MD_MUL) ? product[31:0] : product[63:32];

  // A 33x33 signed product is 66 bits; RV32 defines only the low 64.
  // The top two are sign extension and are deliberately discarded.
  logic unused;
  assign unused = |product[65:64];

endmodule
