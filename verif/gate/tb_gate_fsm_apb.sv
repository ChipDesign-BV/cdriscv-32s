// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// Illegal state recovery for the APB bridge, on its gate netlist.
//
// Second of the six state machines waiver W2a covers.  V16 did the
// multiplier; this is the same check on a different machine, and it is
// done the same way -- against a *standalone* netlist rather than the
// flattened subsystem.
//
// That choice is deliberate and was made the hard way.  In the
// flattened subsystem netlist the state registers survive only as
// escaped identifiers whose names contain dots, declared at their RTL
// width with the constant bits optimised away, so a four-bit
// declaration can have three flops and one permanently floating bit.
// A bench built on those references spends its time fighting naming
// artefacts rather than testing the design.  In a standalone netlist
// `u_dut.state_q` is an ordinary driven wire.

`default_nettype none
`timescale 1ns/1ps

module tb_gate_fsm_apb;

  logic clk = 0, rst_n;
  always #5ns clk = ~clk;

  logic        req, we, rvalid, gnt, err;
  logic [3:0]  be;
  logic [31:0] addr, wdata, rdata;
  logic [15:0] psel;
  logic        penable, pwrite, pready, pslverr;
  logic [11:0] paddr;
  logic [31:0] pwdata, prdata;
  logic [3:0]  pstrb;

  cdriscv_apb_bridge u_dut (
      .clk_i (clk), .rst_ni (rst_n),
      .req_i (req), .gnt_o (gnt), .rvalid_o (rvalid), .we_i (we),
      .be_i (be), .addr_i (addr), .wdata_i (wdata), .rdata_o (rdata), .err_o (err),
      .psel_o (psel), .penable_o (penable), .paddr_o (paddr), .pwrite_o (pwrite),
      .pwdata_o (pwdata), .pstrb_o (pstrb),
      .prdata_i (prdata), .pready_i (pready), .pslverr_i (pslverr)
  );

  int errors = 0, checks = 0;
  logic [3:0] idle, got;
  int e;

  task automatic do_reset;
    rst_n = 0; req = 0; we = 0; be = 0; addr = 0; wdata = 0;
    prdata = 0; pready = 1; pslverr = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (4) @(posedge clk);
  endtask

  initial begin
    do_reset();
    idle = u_dut.state_q;
    $display("[fsm-apb] reset state = %0d", idle);

    for (e = 0; e < 16; e++) begin
      do_reset();
      force u_dut.state_q = 4'(e);
      @(posedge clk);
      #1ns;
      release u_dut.state_q;
      repeat (8) @(posedge clk);
      checks++;
      got = u_dut.state_q;
      if (got === 4'bxxxx) begin
        $display("[fsm-apb] FAIL: encoding %0d led to X", e);
        errors++;
      end else if (got !== idle) begin
        $display("[fsm-apb] FAIL: encoding %0d settled at %0d, not idle %0d", e, got, idle);
        errors++;
      end
    end

    // and it must still work afterwards
    do_reset();
    force u_dut.state_q = 4'hf;
    @(posedge clk);
    #1ns;
    release u_dut.state_q;
    repeat (6) @(posedge clk);
    @(posedge clk);
    req <= 1'b1; we <= 1'b0; addr <= 32'h2000_0200; be <= 4'hf;
    @(posedge clk);
    req <= 1'b0;
    fork
      begin while (!rvalid) @(posedge clk); end
      begin repeat (50) @(posedge clk); end
    join_any
    checks++;
    if (!rvalid) begin
      $display("[fsm-apb] FAIL: no response after recovering from an illegal state");
      errors++;
    end

    if (errors == 0)
      $display("[fsm-apb] PASS: %0d checks, every encoding recovers to idle", checks);
    else
      $display("[fsm-apb] FAIL: %0d of %0d", errors, checks);
    $finish;
  end

  initial begin #2ms; $display("[fsm-apb] FAIL: timeout"); $finish; end

endmodule
