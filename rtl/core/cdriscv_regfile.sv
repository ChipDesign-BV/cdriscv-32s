// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s -- 32 x 32-bit register file, 2 read ports, 1 write port.
//
// Flip-flop based (no latches, no memory macro) so that the array is
// covered by ordinary scan test.  With ParityEn each word carries an
// odd-parity bit that is checked on every read of a register the
// instruction actually uses; a mismatch is reported to the safety
// controller and is treated as an uncorrectable fault.
//
// STATUS: NOT VERIFIED YET -- DO NOT USE YET.

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

  // Entry 0 exists but is tied off: x0 always reads as zero and is
  // never written.  Keeping it in the array avoids an out-of-range
  // index on the read ports.
  logic [31:0][31:0] rf_q;
  logic [31:0]       par_q;

  logic [31:0] we_dec;

  always_comb begin
    we_dec = '0;
    if (we_i && (waddr_i != 5'd0)) begin
      we_dec[waddr_i] = 1'b1;
    end
  end

  assign rf_q[0]  = 32'b0;
  assign par_q[0] = 1'b1;              // odd parity of the all-zero word

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
  logic par_a, par_b;

  assign rdata_a_o = rf_q[raddr_a_i];
  assign par_a     = par_q[raddr_a_i];

  assign rdata_b_o = rf_q[raddr_b_i];
  assign par_b     = par_q[raddr_b_i];

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
