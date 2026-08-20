// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// Block level bench for cdriscv_alu.
//
// Reads vectors produced by gen_vectors.py, which computes the expected
// result from an independent Python model of the RISC-V semantics, and
// checks the RTL against every one of them.  The ALU is combinational,
// so no clock is needed.
//
//   +VEC=<file>   vector file (required)
//   +NVEC=<n>     number of vectors in the file (required)
//   +MAXERR=<n>   stop printing after n mismatches (default 20)

`default_nettype none
`timescale 1ns/1ps

module tb_alu;

  import cdriscv_pkg::*;

  localparam int unsigned MaxVectors = 2_000_000;

  logic [99:0] vec [0:MaxVectors-1];

  logic [3:0]  op;
  logic [31:0] a, b, expected, result;

  alu_op_e     operator;

  assign operator = alu_op_e'(op);

  cdriscv_alu u_dut (
      .operator_i  (operator),
      .operand_a_i (a),
      .operand_b_i (b),
      .result_o    (result)
  );

  string       vecfile;
  int unsigned maxerr;
  int unsigned nvec, errors, i;

  initial begin
    if (!$value$plusargs("VEC=%s", vecfile)) begin
      $display("[tb_alu] ERROR: +VEC=<file> is required");
      $fatal(1);
    end
    if (!$value$plusargs("MAXERR=%d", maxerr)) maxerr = 20;
    // The count comes from the caller rather than from a sentinel: a
    // legitimate vector can be all zero (ADD of 0 and 0), so scanning
    // for the end of the data would truncate the run.
    if (!$value$plusargs("NVEC=%d", nvec)) begin
      $display("[tb_alu] ERROR: +NVEC=<count> is required");
      $fatal(1);
    end

    $readmemh(vecfile, vec);
    errors = 0;

    for (i = 0; i < nvec; i++) begin
      op       = vec[i][99:96];
      a        = vec[i][95:64];
      b        = vec[i][63:32];
      expected = vec[i][31:0];
      #1;
      if (result !== expected) begin
        errors++;
        if (errors <= maxerr) begin
          $display("[tb_alu] MISMATCH vector %0d: op=%0d a=%08x b=%08x expected=%08x got=%08x",
                   i, op, a, b, expected, result);
        end
      end
      #1;
    end

    if (errors == 0) $display("[tb_alu] PASS: %0d vectors", nvec);
    else             $display("[tb_alu] FAIL: %0d of %0d vectors mismatched", errors, nvec);
    $finish;
  end

endmodule
