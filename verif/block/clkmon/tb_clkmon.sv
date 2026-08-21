// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// Block bench for the clock monitor.
//
// Coverage put this one on the list: the branch that reports a *stopped*
// system clock had never executed.  It cannot be reached from software
// running on the subsystem, for the obvious reason -- the software would
// have to stop the clock it is running on -- so the only way to exercise
// it is a bench that owns the clock generator.
//
// HbDiv and CntW are overridden to small values.  With the defaults the
// counter saturates after 2^24 reference cycles, which is a perfectly
// sensible silicon setting and a hopeless simulation one.  The logic
// under test is identical; only the constants differ.
//
// System clock 100 MHz, reference clock 25 MHz, so the reference domain
// sees one heartbeat edge every HbDiv/4 = 4 of its own cycles.

`default_nettype none
`timescale 1ns/1ps

module tb_clkmon;

  localparam int unsigned HbDiv = 16;
  localparam int unsigned CntW  = 6;

  logic clk, rst_n, ref_clk, ref_rst_n;
  bit   clk_en;

  // clk_en gates the system clock without stopping simulation time --
  // that is the whole point of the bench.
  initial begin clk = 0; clk_en = 1; end
  always #5ns  if (clk_en) clk = ~clk;
  initial ref_clk = 0;
  always #20ns ref_clk = ~ref_clk;

  logic        psel, penable, pwrite;
  logic [11:0] paddr;
  logic [31:0] pwdata, prdata;
  logic        pready, pslverr, fault;

  cdriscv_clkmon #(.HbDiv (HbDiv), .CntW (CntW)) dut (
      .clk_i (clk), .rst_ni (rst_n),
      .psel_i (psel), .penable_i (penable), .paddr_i (paddr),
      .pwrite_i (pwrite), .pwdata_i (pwdata),
      .prdata_o (prdata), .pready_o (pready), .pslverr_o (pslverr),
      .fault_o (fault),
      .ref_clk_i (ref_clk), .ref_rst_ni (ref_rst_n)
  );

  int errors = 0, checks = 0;

  task automatic apb_write(input [11:0] a, input [31:0] d);
    @(posedge clk);
    psel <= 1'b1; penable <= 1'b0; pwrite <= 1'b1; paddr <= a; pwdata <= d;
    @(posedge clk);
    penable <= 1'b1;
    @(posedge clk);
    psel <= 1'b0; penable <= 1'b0; pwrite <= 1'b0;
  endtask

  task automatic apb_read(input [11:0] a, output [31:0] d);
    @(posedge clk);
    psel <= 1'b1; penable <= 1'b0; pwrite <= 1'b0; paddr <= a;
    @(posedge clk);
    penable <= 1'b1;
    @(negedge clk);
    d = prdata;
    @(posedge clk);
    psel <= 1'b0; penable <= 1'b0;
  endtask

  task automatic expect_eq(input string what, input [31:0] got, input [31:0] exp);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("[tb_clkmon] FAIL %s: got %0d expected %0d", what, got, exp);
    end
  endtask

  logic [31:0] v;

  initial begin
    psel = 0; penable = 0; pwrite = 0; paddr = 0; pwdata = 0;
    rst_n = 0; ref_rst_n = 0;
    repeat (5) @(posedge clk);
    rst_n = 1; ref_rst_n = 1;
    repeat (5) @(posedge clk);

    // ---------------------------------------------------------------
    // 1. a window the real ratio sits inside: no fault
    // ---------------------------------------------------------------
    apb_write(12'h004, 32'd2);          // MIN
    apb_write(12'h008, 32'd8);          // MAX
    apb_write(12'h000, 32'd1);          // enable
    repeat (400) @(posedge clk);
    expect_eq("in-range status", {31'b0, dut.sts_range_q}, 32'd0);
    expect_eq("in-range fault pin", {31'b0, fault}, 32'd0);
    apb_read(12'h010, v);               // COUNT
    if (v < 3 || v > 5) begin
      errors++;
      $display("[tb_clkmon] FAIL measured count %0d, expected about 4", v);
    end
    checks++;

    // register readback, including an address that decodes to nothing
    apb_read(12'h000, v); expect_eq("CTRL readback", v, 32'd1);
    apb_read(12'h004, v); expect_eq("MIN readback",  v, 32'd2);
    apb_read(12'h008, v); expect_eq("MAX readback",  v, 32'd8);
    apb_read(12'h014, v); expect_eq("undecoded read", v, 32'd0);
    apb_write(12'h014, 32'hffff_ffff);  // undecoded write: must not disturb
    apb_read(12'h000, v); expect_eq("CTRL after undecoded write", v, 32'd1);

    // ---------------------------------------------------------------
    // 2. system clock too fast for the window: MIN above the real ratio
    // ---------------------------------------------------------------
    apb_write(12'h000, 32'd0);          // quasi-static:程 change while off
    apb_write(12'h004, 32'd6);          // MIN now above the true count
    apb_write(12'h000, 32'd1);
    repeat (400) @(posedge clk);
    expect_eq("out-of-range status", {31'b0, dut.sts_range_q}, 32'd1);
    expect_eq("out-of-range fault pin", {31'b0, fault}, 32'd1);

    // clearing is write-one-to-clear on STATUS[0]
    apb_write(12'h000, 32'd0);
    apb_write(12'h004, 32'd2);          // back to a sane window
    apb_write(12'h00c, 32'd1);
    repeat (20) @(posedge clk);
    expect_eq("status after clear", {31'b0, dut.sts_range_q}, 32'd0);
    apb_write(12'h000, 32'd1);
    repeat (400) @(posedge clk);
    expect_eq("status stays clear", {31'b0, dut.sts_range_q}, 32'd0);

    // ---------------------------------------------------------------
    // 3. the case this bench exists for: the system clock stops.
    //
    // No heartbeat reaches the reference domain, its counter runs up to
    // MAX and the fault is latched there -- in a domain that is still
    // running.  The system side cannot be read while its clock is
    // stopped, so the check happens after the clock comes back, which
    // is also how it would be read in silicon.
    // ---------------------------------------------------------------
    clk_en = 1'b0;
    #2000ns;                            // 50 reference cycles, MAX is 8
    clk_en = 1'b1;
    repeat (40) @(posedge clk);
    expect_eq("clock-stopped status", {31'b0, dut.sts_range_q}, 32'd1);
    expect_eq("clock-stopped fault pin", {31'b0, fault}, 32'd1);
    expect_eq("clock-stopped ref fault", {31'b0, dut.ref_fault_q}, 32'd1);

    // and it clears again once the clock is back
    apb_write(12'h00c, 32'd1);
    repeat (40) @(posedge clk);
    expect_eq("status after clock returns", {31'b0, dut.sts_range_q}, 32'd0);

    // ---------------------------------------------------------------
    // 4. disabled means silent: no measurement, no fault
    // ---------------------------------------------------------------
    apb_write(12'h000, 32'd0);
    apb_write(12'h004, 32'd30);         // a window nothing could satisfy
    apb_write(12'h008, 32'd31);
    repeat (400) @(posedge clk);
    expect_eq("disabled stays clean", {31'b0, dut.sts_range_q}, 32'd0);

    if (errors == 0)
      $display("[tb_clkmon] PASS: %0d checks", checks);
    else
      $display("[tb_clkmon] FAIL: %0d of %0d checks failed", errors, checks);
    $finish;
  end

  initial begin
    #500us;
    $display("[tb_clkmon] FAIL: timeout");
    $finish;
  end

endmodule
