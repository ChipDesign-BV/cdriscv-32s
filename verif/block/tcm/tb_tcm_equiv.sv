// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s -- equivalence bench for the split-macro TCM (V48).
//
// LVS compares the extracted layout against the netlist that produced
// it, so it cannot show that the check bits reach the *right* bits of
// the parity macro: a consistent mis-wiring passes LVS.  This bench
// closes that gap by driving the behavioural TCM (rtl/bus, one 39-bit
// array) and the macro-mapped TCM (2x 2048x32 + 1x 4096x8, with the
// PDK's own behavioural SRAM models) from identical stimulus and
// comparing every output cycle by cycle.
//
// Any swapped, dropped or misaligned parity bit shows up the moment a
// word is read back, because the ECC decoder sees a syndrome the
// encoder never produced.

`timescale 1ns/1ps

module tb_tcm_equiv;

  localparam int unsigned Depth = 4096;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic        req, we;
  logic [3:0]  be;
  logic [31:0] addr, wdata;
  logic        inj_en;
  logic [38:0] inj_mask;
  logic        bist_en, bist_we;
  logic [31:0] bist_addr;
  logic [38:0] bist_wdata;

  // reference (behavioural array) and DUT (split macros)
  logic        r_gnt, r_rvalid, r_err, r_cor, r_unc;
  logic [31:0] r_rdata;
  logic [38:0] r_bist_rdata;
  logic        d_gnt, d_rvalid, d_err, d_cor, d_unc;
  logic [31:0] d_rdata;
  logic [38:0] d_bist_rdata;

  cdriscv_tcm #(.Depth(Depth)) u_ref (
      .clk_i(clk), .rst_ni(rst_n), .req_i(req), .gnt_o(r_gnt),
      .rvalid_o(r_rvalid), .we_i(we), .be_i(be), .addr_i(addr),
      .wdata_i(wdata), .rdata_o(r_rdata), .err_o(r_err),
      .ecc_cor_o(r_cor), .ecc_unc_o(r_unc),
      .inj_en_i(inj_en), .inj_mask_i(inj_mask),
      .bist_en_i(bist_en), .bist_we_i(bist_we), .bist_addr_i(bist_addr),
      .bist_wdata_i(bist_wdata), .bist_rdata_o(r_bist_rdata));

  cdriscv_tcm_mac #(.Depth(Depth)) u_dut (
      .clk_i(clk), .rst_ni(rst_n), .req_i(req), .gnt_o(d_gnt),
      .rvalid_o(d_rvalid), .we_i(we), .be_i(be), .addr_i(addr),
      .wdata_i(wdata), .rdata_o(d_rdata), .err_o(d_err),
      .ecc_cor_o(d_cor), .ecc_unc_o(d_unc),
      .inj_en_i(inj_en), .inj_mask_i(inj_mask),
      .bist_en_i(bist_en), .bist_we_i(bist_we), .bist_addr_i(bist_addr),
      .bist_wdata_i(bist_wdata), .bist_rdata_o(d_bist_rdata));

  int errors = 0, checks = 0;

  task automatic cmp(string tag);
    checks++;
    if (r_gnt !== d_gnt || r_rvalid !== d_rvalid || r_err !== d_err ||
        r_cor !== d_cor || r_unc !== d_unc || r_rdata !== d_rdata ||
        r_bist_rdata !== d_bist_rdata) begin
      errors++;
      if (errors <= 12)
        $display("[MISMATCH:%0s] t=%0t gnt %b/%b rvalid %b/%b err %b/%b cor %b/%b unc %b/%b rdata %08x/%08x bist %010x/%010x",
                 tag, $time, r_gnt,d_gnt, r_rvalid,d_rvalid, r_err,d_err,
                 r_cor,d_cor, r_unc,d_unc, r_rdata,d_rdata, r_bist_rdata,d_bist_rdata);
    end
  endtask

  task automatic idle();
    req=0; we=0; be=4'h0; addr=0; wdata=0; inj_en=0; inj_mask=0;
    bist_en=0; bist_we=0; bist_addr=0; bist_wdata=0;
  endtask

  int unsigned a, i;
  logic [31:0] d;
  logic [3:0]  bmask;

  initial begin
    idle();
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // ---- 1. full-word writes then reads, walking the address space
    for (i = 0; i < 600; i++) begin
      a = $urandom_range(0, Depth-1);
      d = $urandom;
      @(negedge clk); req=1; we=1; be=4'hf; addr={18'b0,a[11:0],2'b00}; wdata=d;
      @(posedge clk); #1 cmp("wr");
      @(negedge clk); req=1; we=0; be=4'hf; addr={18'b0,a[11:0],2'b00};
      @(posedge clk); #1 cmp("rd_addr");
      @(negedge clk); idle();
      @(posedge clk); #1 cmp("rd_data");
    end

    // ---- 2. partial writes (read-modify-write path, recomputes parity)
    for (i = 0; i < 400; i++) begin
      a = $urandom_range(0, Depth-1);
      d = $urandom;
      bmask = $urandom_range(1,14);              // never 0, never f
      @(negedge clk); req=1; we=1; be=bmask; addr={18'b0,a[11:0],2'b00}; wdata=d;
      @(posedge clk); #1 cmp("pw");
      @(negedge clk); idle();
      repeat (2) begin @(posedge clk); #1 cmp("pw_phase2"); end
      @(negedge clk); req=1; we=0; be=4'hf; addr={18'b0,a[11:0],2'b00};
      @(posedge clk); #1 cmp("pw_rd");
      @(negedge clk); idle();
      @(posedge clk); #1 cmp("pw_rdd");
    end

    // ---- 3. raw BIST port: writes all 39 bits, incl. the check bits
    for (i = 0; i < 400; i++) begin
      a = $urandom_range(0, Depth-1);
      @(negedge clk); idle();
      bist_en=1; bist_we=1; bist_addr={18'b0,a[11:0],2'b00};
      bist_wdata={$urandom,$urandom} & 39'h7f_ffff_ffff;
      @(posedge clk); #1 cmp("bist_wr");
      @(negedge clk); bist_en=1; bist_we=0; bist_addr={18'b0,a[11:0],2'b00};
      @(posedge clk); #1 cmp("bist_rd");
      @(negedge clk); idle();
      @(posedge clk); #1 cmp("bist_rdd");
    end

    // ---- 4. fault injection: corrupt a stored word, expect the same
    //          correction / detection on both sides
    for (i = 0; i < 400; i++) begin
      a = $urandom_range(0, Depth-1);
      d = $urandom;
      @(negedge clk); idle(); inj_en=1;
      inj_mask = (i % 3 == 0) ? (39'b1 << ($urandom_range(0,38)))          // single
               : (i % 3 == 1) ? ((39'b1 << ($urandom_range(0,18))) |
                                 (39'b1 << ($urandom_range(19,38))))       // double
               : 39'b0;
      @(posedge clk); #1 cmp("inj_arm");
      @(negedge clk); idle();
      req=1; we=1; be=4'hf; addr={18'b0,a[11:0],2'b00}; wdata=d;
      @(posedge clk); #1 cmp("inj_wr");
      @(negedge clk); req=1; we=0; be=4'hf; addr={18'b0,a[11:0],2'b00};
      @(posedge clk); #1 cmp("inj_rd");
      @(negedge clk); idle();
      @(posedge clk); #1 cmp("inj_rdd");
    end

    $display("[tb_tcm_equiv] %0d checks, %0d mismatches", checks, errors);
    if (errors == 0) $display("[tb_tcm_equiv] PASS");
    else             $display("[tb_tcm_equiv] FAIL");
    $finish;
  end

  initial begin
    #20_000_000;
    $display("[tb_tcm_equiv] TIMEOUT");
    $finish;
  end

endmodule
