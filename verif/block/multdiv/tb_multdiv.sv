// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// Block level bench for cdriscv_multdiv.
//
// Besides checking results against an independent model, this bench
// checks two structural properties the design claims:
//
//   * the latency is the same for every operation and every operand,
//     including division by zero.  That is the WCET evidence quoted in
//     the safety manual, so it is asserted rather than observed.
//   * acc_q[32] is always zero at an iteration boundary (finding
//     V0-A1): the multiply path writes it as zero, and the restoring
//     division invariant keeps the partial remainder below the divisor.
//     Lint reported the bit as unused; this turns the reasoning into a
//     check that runs.
//
//   +VEC=<file> +NVEC=<n> +MAXERR=<n>

`default_nettype none
`timescale 1ns/1ps

module tb_multdiv;

  import cdriscv_pkg::*;

  localparam int unsigned MaxVectors = 500_000;

  logic clk, rst_n;

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  logic        req, busy, valid;
  md_op_e      operator;
  logic [31:0] op_a, op_b, result;

  cdriscv_multdiv u_dut (
      .clk_i       (clk),
      .rst_ni      (rst_n),
      .req_i       (req),
      .operator_i  (operator),
      .operand_a_i (op_a),
      .operand_b_i (op_b),
      .kill_i      (1'b0),
      .busy_o      (busy),
      .valid_o     (valid),
      .result_o    (result)
  );

  logic [98:0] vec [0:MaxVectors-1];
  string       vecfile;
  int unsigned nvec, maxerr, errors, acc_violations, i;
  int unsigned first_latency, cycles;
  logic [31:0] expected;

  // V0-A1: the top bit of the accumulator must never carry information.
  //
  // This is a white box check and it cannot survive synthesis, which is
  // the correct outcome rather than a problem: yosys reaches the same
  // conclusion the invariant asserts, finds bit 32 carries nothing, and
  // emits `assign acc_q[32] = 1'hx;` with flops for the other
  // thirty-two.  Probing it at gate level then reads the don't-care.
  // +NOWHITEBOX skips it, and the gate level run says so rather than
  // quietly claiming the invariant still holds.
  bit white_box;
  initial white_box = !$test$plusargs("NOWHITEBOX");

  always @(posedge clk) begin
    if (white_box && rst_n && (u_dut.acc_q[32] !== 1'b0)) begin
      $display("[tb_multdiv] INVARIANT acc_q[32] set at time %0t", $time);
      acc_violations++;
    end
  end

  initial begin
    rst_n          = 1'b0;
    req            = 1'b0;
    operator       = MD_MUL;
    op_a           = 32'b0;
    op_b           = 32'b0;
    errors         = 0;
    acc_violations = 0;
    first_latency  = 0;

    if (!$value$plusargs("VEC=%s", vecfile)) begin
      $display("[tb_multdiv] ERROR: +VEC=<file> required"); $fatal(1);
    end
    if (!$value$plusargs("NVEC=%d", nvec)) begin
      $display("[tb_multdiv] ERROR: +NVEC=<count> required"); $fatal(1);
    end
    if (!$value$plusargs("MAXERR=%d", maxerr)) maxerr = 20;

    $readmemh(vecfile, vec);

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    for (i = 0; i < nvec; i++) begin
      operator = md_op_e'(vec[i][98:96]);
      op_a     = vec[i][95:64];
      op_b     = vec[i][63:32];
      expected = vec[i][31:0];

      @(negedge clk);
      req = 1'b1;
      @(negedge clk);
      req = 1'b0;

      cycles = 1;
      while (!valid) begin
        @(negedge clk);
        cycles++;
      end

      if (result !== expected) begin
        errors++;
        if (errors <= maxerr)
          $display("[tb_multdiv] MISMATCH %0d: op=%0d a=%08x b=%08x expected=%08x got=%08x",
                   i, vec[i][98:96], op_a, op_b, expected, result);
      end

      if (first_latency == 0) first_latency = cycles;
      else if (cycles != first_latency) begin
        errors++;
        if (errors <= maxerr)
          $display("[tb_multdiv] LATENCY %0d: op=%0d took %0d cycles, expected %0d",
                   i, vec[i][98:96], cycles, first_latency);
      end

      @(negedge clk);
    end

    if (errors == 0 && acc_violations == 0)
      $display("[tb_multdiv] PASS: %0d vectors, constant latency %0d cycles, %s",
               nvec, first_latency,
               white_box ? "acc_q[32] never set"
                         : "invariant acc_q[32] NOT checked (white box, +NOWHITEBOX)");
    else
      $display("[tb_multdiv] FAIL: %0d result/latency errors, %0d invariant violations, over %0d vectors",
               errors, acc_violations, nvec);
    $finish;
  end

endmodule
