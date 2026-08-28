// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s -- equivalence bench for the replicated IF read pointer.
//
// V50 replicated rd_ptr_q into three flops so the 65 bits of mux select
// it drives are split at the source.  yosys equiv_induct cannot prove
// this: replication changes the state encoding, so equiv_make has no
// counterpart to pair rd_ptr_rdata_q / rd_ptr_pc_q against and induction
// has no invariant to hold.  That is a limitation of the proof, not
// evidence about the design -- so the design is checked here instead,
// by driving the original and the replicated IF stage from identical
// random stimulus and comparing every output cycle by cycle.

`timescale 1ns/1ps

module tb_if_equiv;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic        fetch_en, redirect, instr_ready, gnt, rvalid, err_i;
  logic [31:0] redirect_pc, rdata_i, boot_addr;

  logic        g_valid, g_err, g_req;  logic [31:0] g_rdata, g_pc, g_addr;
  logic        n_valid, n_err, n_req;  logic [31:0] n_rdata, n_pc, n_addr;

  cdriscv_if_stage_gold u_gold (
    .clk_i(clk), .rst_ni(rst_n), .boot_addr_i(boot_addr), .fetch_en_i(fetch_en),
    .redirect_i(redirect), .redirect_pc_i(redirect_pc),
    .instr_valid_o(g_valid), .instr_rdata_o(g_rdata), .instr_pc_o(g_pc),
    .instr_err_o(g_err), .instr_ready_i(instr_ready),
    .instr_req_o(g_req), .instr_gnt_i(gnt), .instr_rvalid_i(rvalid),
    .instr_addr_o(g_addr), .instr_rdata_i(rdata_i), .instr_err_i(err_i));

  cdriscv_if_stage u_new (
    .clk_i(clk), .rst_ni(rst_n), .boot_addr_i(boot_addr), .fetch_en_i(fetch_en),
    .redirect_i(redirect), .redirect_pc_i(redirect_pc),
    .instr_valid_o(n_valid), .instr_rdata_o(n_rdata), .instr_pc_o(n_pc),
    .instr_err_o(n_err), .instr_ready_i(instr_ready),
    .instr_req_o(n_req), .instr_gnt_i(gnt), .instr_rvalid_i(rvalid),
    .instr_addr_o(n_addr), .instr_rdata_i(rdata_i), .instr_err_i(err_i));

  int checks = 0, errors = 0;

  // Only compare instr_rdata/pc/err when the buffer actually presents an
  // instruction; they are don't-care otherwise and the gold model leaves
  // stale data there.
  task automatic cmp();
    checks++;
    if (g_valid !== n_valid || g_req !== n_req || g_addr !== n_addr ||
        (g_valid && (g_rdata !== n_rdata || g_pc !== n_pc || g_err !== n_err))) begin
      errors++;
      if (errors <= 10)
        $display("[MISMATCH] t=%0t valid %b/%b req %b/%b addr %08x/%08x rdata %08x/%08x pc %08x/%08x err %b/%b",
                 $time, g_valid,n_valid, g_req,n_req, g_addr,n_addr,
                 g_rdata,n_rdata, g_pc,n_pc, g_err,n_err);
    end
  endtask

  int i;
  initial begin
    boot_addr = 32'h0000_0000;
    fetch_en=0; redirect=0; redirect_pc=0; instr_ready=0; gnt=0; rvalid=0;
    rdata_i=0; err_i=0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    for (i = 0; i < 200000; i++) begin
      @(negedge clk);
      // random but legal-ish stimulus across the whole protocol space
      fetch_en    = ($urandom_range(0,99) < 90);
      instr_ready = ($urandom_range(0,99) < 70);
      gnt         = ($urandom_range(0,99) < 75);
      rvalid      = ($urandom_range(0,99) < 60);
      rdata_i     = $urandom;
      err_i       = ($urandom_range(0,99) < 3);
      redirect    = ($urandom_range(0,999) < 25);
      redirect_pc = {$urandom} & 32'hffff_fffc;
      if ($urandom_range(0,4999) == 0) begin   // occasional reset pulse
        rst_n = 1'b0; @(posedge clk); #1 cmp(); @(negedge clk); rst_n = 1'b1;
      end
      @(posedge clk); #1 cmp();
    end

    $display("[tb_if_equiv] %0d checks, %0d mismatches", checks, errors);
    $display("[tb_if_equiv] %s", errors == 0 ? "PASS" : "FAIL");
    $finish;
  end
endmodule
