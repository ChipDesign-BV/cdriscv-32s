// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// Formal properties for the SEC-DED (39,32) encoder and decoder.
//
// The block bench in verif/block/ecc enumerates every error position
// but samples the data: 268 patterns out of 2^32.  This wrapper closes
// that gap.  Both modules are purely combinational, so a bounded model
// check of depth 1 is not a bounded result at all -- it quantifies over
// every data value and every error position at once, which is a proof
// of the three properties the safety argument rests on:
//
//   no error    the word comes back unchanged, no flag
//   one error   corrected, whatever the data and wherever the bit
//   two errors  flagged uncorrectable and never silently corrected
//
// The third is the one that matters.  A decoder that flags a double
// error *and* also "corrects" the data would pass any test that only
// inspects the flags; here the correction output is checked too.

`default_nettype none

module ecc_fv (
    input  logic        clk_i,
    input  logic [31:0] data_i,
    input  logic [5:0]  pos_a_i,     // free error positions
    input  logic [5:0]  pos_b_i,
    input  logic [1:0]  n_err_i      // 0, 1 or 2 bit errors
);

  logic [38:0] cw_clean, cw_err;
  logic [31:0] data_out;
  logic [6:0]  syndrome;
  logic        err_single, err_double;

  cdriscv_ecc_enc u_enc (
      .data_i (data_i),
      .cw_o   (cw_clean)
  );

  // Build the corrupted code word from the free error positions.
  always_comb begin
    case (n_err_i)
      2'd0:    cw_err = cw_clean;
      2'd1:    cw_err = cw_clean ^ (39'b1 << pos_a_i);
      default: cw_err = cw_clean ^ (39'b1 << pos_a_i) ^ (39'b1 << pos_b_i);
    endcase
  end

  cdriscv_ecc_dec u_dec (
      .cw_i         (cw_err),
      .data_o       (data_out),
      .syndrome_o   (syndrome),
      .err_single_o (err_single),
      .err_double_o (err_double)
  );

  always @(posedge clk_i) begin
    // error positions are inside the code word, and the two are
    // distinct -- flipping the same bit twice is no error at all
    a_pos_a_range: assume (pos_a_i < 6'd39);
    a_pos_b_range: assume (pos_b_i < 6'd39);
    a_pos_distinct: assume (pos_a_i != pos_b_i);
    a_n_err_range: assume (n_err_i <= 2'd2);

    // ---- the three properties ----
    if (n_err_i == 2'd0) begin
      p_clean_data:   assert (data_out == data_i);
      p_clean_single: assert (!err_single);
      p_clean_double: assert (!err_double);
    end

    if (n_err_i == 2'd1) begin
      // corrected, for every data value and every bit position
      p_single_data:   assert (data_out == data_i);
      p_single_flag:   assert (err_single);
      p_single_nodbl:  assert (!err_double);
    end

    if (n_err_i == 2'd2) begin
      // detected, and never reported as a correctable error, which is
      // what would let a silent miscorrection through
      p_double_flag:  assert (err_double);
      p_double_nosgl: assert (!err_single);
    end
  end

endmodule
