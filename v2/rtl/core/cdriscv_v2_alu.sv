// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s v2 -- ALU with Zba / Zbb / Zbs.
//
// Variant 1's ALU covered the base RV32I operations.  This adds the 27
// bit-manipulation operations of the B extension as ratified
// (Zba+Zbb+Zbs), all single-cycle and purely combinational, so nothing
// in the pipeline control changes.
//
// The three shift-add operations of Zba reuse the adder; the counting
// operations (clz/ctz/cpop) are the only genuinely new structures and
// are written as explicit reduction trees rather than loops so the
// synthesised depth is predictable.
//
// STATUS: NEW AND UNVERIFIED -- not through the O1-O9 gate.  Do not use.

`default_nettype none

module cdriscv_v2_alu
  import cdriscv_v2_pkg::*;
(
    input  alu_op_e     operator_i,
    input  logic [31:0] operand_a_i,
    input  logic [31:0] operand_b_i,
    output logic [31:0] result_o
);

  // ---- shared adder/subtractor -------------------------------------
  logic        sub;
  logic [31:0] add_b, add_res;
  assign sub     = (operator_i inside {ALU_SUB, ALU_SLT, ALU_SLTU,
                                       ALU_EQ, ALU_NE, ALU_GE, ALU_GEU});
  assign add_b   = sub ? ~operand_b_i : operand_b_i;
  assign add_res = operand_a_i + add_b + {31'b0, sub};

  // ---- comparisons --------------------------------------------------
  logic eq, lt_s, lt_u;
  assign eq   = (operand_a_i == operand_b_i);
  assign lt_s = ($signed(operand_a_i) < $signed(operand_b_i));
  assign lt_u = (operand_a_i < operand_b_i);

  // ---- shifts --------------------------------------------------------
  logic [4:0]  shamt;
  logic [32:0] shift_ext;
  logic [31:0] shr, shl, rot_r, rot_l;
  assign shamt     = operand_b_i[4:0];
  assign shift_ext = {(operator_i == ALU_SRA) ? operand_a_i[31] : 1'b0, operand_a_i};
  assign shr       = 32'($signed(shift_ext) >>> shamt);
  assign shl       = operand_a_i << shamt;
  // Zbb rotates: a rotate is the OR of the two shift directions.
  // (5'd0 - shamt) wraps mod 32 by construction, which is exactly the
  // complement a rotate needs -- and avoids a 32-bit subtract.
  assign rot_r = (operand_a_i >> shamt) | (operand_a_i << (5'd0 - shamt));
  assign rot_l = (operand_a_i << shamt) | (operand_a_i >> (5'd0 - shamt));

  // ---- Zbb counting --------------------------------------------------
  // cpop as an adder tree; clz/ctz as priority encodes.  Written out so
  // the logic depth is visible rather than left to loop unrolling.
  logic [5:0] cpop;
  always_comb begin
    cpop = 6'd0;
    for (int unsigned i = 0; i < 32; i++) cpop = cpop + {5'b0, operand_a_i[i]};
  end

  logic [5:0] clz, ctz;
  always_comb begin
    clz = 6'd32;
    for (int i = 31; i >= 0; i--) if (operand_a_i[i]) begin clz = 6'(31 - i); break; end
  end
  always_comb begin
    ctz = 6'd32;
    for (int unsigned i = 0; i < 32; i++) if (operand_a_i[i]) begin ctz = 6'(i); break; end
  end

  // ---- Zbb byte operations -------------------------------------------
  logic [31:0] rev8, orcb;
  assign rev8 = {operand_a_i[7:0], operand_a_i[15:8],
                 operand_a_i[23:16], operand_a_i[31:24]};
  always_comb begin
    for (int unsigned b = 0; b < 4; b++)
      orcb[8*b +: 8] = (|operand_a_i[8*b +: 8]) ? 8'hff : 8'h00;
  end

  // ---- Zbs single-bit --------------------------------------------------
  logic [31:0] bit_mask;
  assign bit_mask = 32'b1 << shamt;

  // ---- result mux ------------------------------------------------------
  always_comb begin
    unique case (operator_i)
      ALU_ADD, ALU_SUB : result_o = add_res;
      ALU_SLL          : result_o = shl;
      ALU_SRL, ALU_SRA : result_o = shr;
      ALU_XOR          : result_o = operand_a_i ^ operand_b_i;
      ALU_OR           : result_o = operand_a_i | operand_b_i;
      ALU_AND          : result_o = operand_a_i & operand_b_i;
      ALU_SLT          : result_o = {31'b0, lt_s};
      ALU_SLTU         : result_o = {31'b0, lt_u};
      ALU_EQ           : result_o = {31'b0, eq};
      ALU_NE           : result_o = {31'b0, ~eq};
      ALU_GE           : result_o = {31'b0, ~lt_s};
      ALU_GEU          : result_o = {31'b0, ~lt_u};
      ALU_PASSB        : result_o = operand_b_i;
      // Zba
      ALU_SH1ADD       : result_o = (operand_a_i << 1) + operand_b_i;
      ALU_SH2ADD       : result_o = (operand_a_i << 2) + operand_b_i;
      ALU_SH3ADD       : result_o = (operand_a_i << 3) + operand_b_i;
      // Zbb
      ALU_ANDN         : result_o = operand_a_i & ~operand_b_i;
      ALU_ORN          : result_o = operand_a_i | ~operand_b_i;
      ALU_XNOR         : result_o = ~(operand_a_i ^ operand_b_i);
      ALU_CLZ          : result_o = {26'b0, clz};
      ALU_CTZ          : result_o = {26'b0, ctz};
      ALU_CPOP         : result_o = {26'b0, cpop};
      ALU_MAX          : result_o = lt_s ? operand_b_i : operand_a_i;
      ALU_MAXU         : result_o = lt_u ? operand_b_i : operand_a_i;
      ALU_MIN          : result_o = lt_s ? operand_a_i : operand_b_i;
      ALU_MINU         : result_o = lt_u ? operand_a_i : operand_b_i;
      ALU_SEXTB        : result_o = {{24{operand_a_i[7]}},  operand_a_i[7:0]};
      ALU_SEXTH        : result_o = {{16{operand_a_i[15]}}, operand_a_i[15:0]};
      ALU_ZEXTH        : result_o = {16'b0, operand_a_i[15:0]};
      ALU_ROL          : result_o = rot_l;
      ALU_ROR          : result_o = rot_r;
      ALU_ORCB         : result_o = orcb;
      ALU_REV8         : result_o = rev8;
      // Zbs
      ALU_BCLR         : result_o = operand_a_i & ~bit_mask;
      ALU_BEXT         : result_o = {31'b0, |(operand_a_i & bit_mask)};
      ALU_BINV         : result_o = operand_a_i ^ bit_mask;
      ALU_BSET         : result_o = operand_a_i | bit_mask;
      default          : result_o = 32'b0;
    endcase
  end

endmodule
