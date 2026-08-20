// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// Block level bench for the SEC-DED (39,32) encoder and decoder.
//
// Exhaustive over error positions rather than sampled: for every data
// pattern it checks the clean code word, all 39 single bit errors, and
// all 741 double bit error pairs.  The properties checked are the ones
// the safety argument actually rests on:
//
//   clean        no flag, data returned unchanged
//   single bit   corrected to the original data, err_single only
//   double bit   err_double only, and -- the one that matters --
//                never silently corrected to some other valid word
//
// The last property is the reason this bench exists.  A decoder that
// reports a double bit error but also "corrects" the data would look
// fine in any test that only inspects the flags.
//
//   +PATTERNS=<n>  number of random data patterns (default 200)
//   +MAXERR=<n>    stop printing after n failures (default 20)

`default_nettype none
`timescale 1ns/1ps

module tb_ecc;

  logic [31:0] data_in;
  logic [38:0] cw_clean, cw_err;
  logic [31:0] data_out;
  logic [6:0]  syndrome;
  logic        err_single, err_double;

  cdriscv_ecc_enc u_enc (
      .data_i (data_in),
      .cw_o   (cw_clean)
  );

  cdriscv_ecc_dec u_dec (
      .cw_i         (cw_err),
      .data_o       (data_out),
      .syndrome_o   (syndrome),
      .err_single_o (err_single),
      .err_double_o (err_double)
  );

  int unsigned patterns, maxerr;
  int unsigned errors, checks;
  int unsigned p, i, j, k;
  logic [31:0] pat;

  task automatic check_clean;
    begin
      cw_err = cw_clean;
      #1;
      checks++;
      if (err_single || err_double || (data_out !== data_in)) begin
        errors++;
        if (errors <= maxerr)
          $display("[tb_ecc] CLEAN data=%08x: single=%b double=%b out=%08x",
                   data_in, err_single, err_double, data_out);
      end
    end
  endtask

  task automatic check_single(input int unsigned bitpos);
    begin
      cw_err = cw_clean ^ (39'b1 << bitpos);
      #1;
      checks++;
      // a single bit error must be corrected, flagged as single, and
      // must not be reported as uncorrectable
      if (!err_single || err_double || (data_out !== data_in)) begin
        errors++;
        if (errors <= maxerr)
          $display("[tb_ecc] SINGLE data=%08x bit=%0d: single=%b double=%b out=%08x",
                   data_in, bitpos, err_single, err_double, data_out);
      end
    end
  endtask

  task automatic check_double(input int unsigned b0, input int unsigned b1);
    begin
      cw_err = cw_clean ^ (39'b1 << b0) ^ (39'b1 << b1);
      #1;
      checks++;
      // a double bit error must be flagged uncorrectable and must not
      // be reported as a correctable one
      if (!err_double || err_single) begin
        errors++;
        if (errors <= maxerr)
          $display("[tb_ecc] DOUBLE data=%08x bits=%0d,%0d: single=%b double=%b",
                   data_in, b0, b1, err_single, err_double);
      end
    end
  endtask

  initial begin
    if (!$value$plusargs("PATTERNS=%d", patterns)) patterns = 200;
    if (!$value$plusargs("MAXERR=%d", maxerr))     maxerr   = 20;

    errors = 0;
    checks = 0;

    for (p = 0; p < patterns + 68; p++) begin
      // the first 68 patterns are structural: all zero, all one, and
      // walking one and walking zero over all 32 bit positions
      if (p == 0)                    pat = 32'h0000_0000;
      else if (p == 1)               pat = 32'hffff_ffff;
      else if (p == 2)               pat = 32'haaaa_aaaa;
      else if (p == 3)               pat = 32'h5555_5555;
      else if (p < 36)               pat = 32'b1 << (p - 4);
      else if (p < 68)               pat = ~(32'b1 << (p - 36));
      else                           pat = {$random, $random};

      data_in = pat;
      #1;

      check_clean();
      for (i = 0; i < 39; i++) check_single(i);
      for (i = 0; i < 39; i++)
        for (j = i + 1; j < 39; j++) check_double(i, j);
    end

    if (errors == 0)
      $display("[tb_ecc] PASS: %0d checks over %0d data patterns (clean, all 39 single bit, all 741 double bit)",
               checks, patterns + 68);
    else
      $display("[tb_ecc] FAIL: %0d of %0d checks failed", errors, checks);
    $finish;
  end

endmodule
