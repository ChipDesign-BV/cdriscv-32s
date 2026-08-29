// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-10 -- 32 x 32-bit register file, 2 read ports, 1 write port.
//
// Flip-flop based (no latches, no memory macro) so that the array is
// covered by ordinary scan test.  With ParityEn each word carries an
// odd-parity bit that is checked on every read of a register the
// instruction actually uses; a mismatch is reported to the safety
// controller and is treated as an uncorrectable fault.
//
// STATUS: verified to the O1-O7 gate of doc/verification_plan.md
//         (2026-08-24) -- may be used in a project.  O8-O9 and the
//         FMEDA are open: NOT qualified for safety-critical use.

`default_nettype none

module cdriscv_regfile #(
    parameter bit ParityEn = 1'b1
)(
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic [4:0]  raddr_a_i,
    input  logic        ren_a_i,
    output logic [31:0] rdata_a_o,

    input  logic [4:0]  raddr_b_i,
    input  logic        ren_b_i,
    output logic [31:0] rdata_b_o,

    input  logic [4:0]  waddr_i,
    input  logic [31:0] wdata_i,
    input  logic        we_i,

    output logic        par_err_o
);

  // The storage holds entries 1..31; x0 is not implemented.  A separate
  // read view adds the constant entry 0, so the read ports can index
  // with the raw 5-bit address without an out-of-range access, and
  // without one array being driven both procedurally and continuously
  // (which not every simulator accepts).
  logic [31:1][31:0] rf_q;
  logic [31:1]       par_q;

  logic [31:0][31:0] rf_rd;
  logic [31:0]       par_rd;

  logic [31:0] we_dec;

  always_comb begin
    we_dec = '0;
    if (we_i && (waddr_i != 5'd0)) begin
      we_dec[waddr_i] = 1'b1;
    end
  end

  for (genvar i = 1; i < 32; i++) begin : g_rf
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        rf_q[i]  <= 32'b0;
        par_q[i] <= 1'b1;
      end else if (we_dec[i]) begin
        rf_q[i]  <= wdata_i;
        par_q[i] <= ~(^wdata_i);       // odd parity
      end
    end
  end

  // ------------------------------------------------------------------
  // Read ports
  // ------------------------------------------------------------------
  always_comb begin
    rf_rd[0]  = 32'b0;
    par_rd[0] = 1'b1;                  // odd parity of the all-zero word
    for (int unsigned i = 1; i < 32; i++) begin
      rf_rd[i]  = rf_q[i];
      par_rd[i] = par_q[i];
    end
  end

  logic par_a, par_b;

  assign rdata_a_o = rf_rd[raddr_a_i];
  assign par_a     = par_rd[raddr_a_i];

  assign rdata_b_o = rf_rd[raddr_b_i];
  assign par_b     = par_rd[raddr_b_i];

  // ------------------------------------------------------------------
  // Parity check, only for the ports the current instruction consumes.
  // A correct word satisfies  ^data ^ parity == 1  (odd parity).
  // ------------------------------------------------------------------
  if (ParityEn) begin : g_parity
    logic ok_a, ok_b;
    assign ok_a      = ((^rdata_a_o) ^ par_a);
    assign ok_b      = ((^rdata_b_o) ^ par_b);
    assign par_err_o = (ren_a_i && !ok_a) || (ren_b_i && !ok_b);
  end else begin : g_no_parity
    assign par_err_o = 1'b0;
  end

endmodule
