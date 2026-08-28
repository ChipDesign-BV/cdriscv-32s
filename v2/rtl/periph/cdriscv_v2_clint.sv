// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s v2 -- CLINT (core-local interruptor).
//
// Variant 1 already implemented the CLINT's *function* -- a 64-bit
// mtime/mtimecmp pair with spec-correct level interrupt semantics, plus
// msip -- but as an APB peripheral at its own register offsets.  This
// is the same function at the standard memory-mapped layout, so
// unmodified RISC-V software and RTOS ports work without a board file:
//
//   +0x0000  msip       [0] software interrupt, RW
//   +0x4000  mtimecmp   64-bit, RW  (lo at 0x4000, hi at 0x4004)
//   +0xBFF8  mtime      64-bit, RW  (lo at 0xBFF8, hi at 0xBFFC)
//
// Two details the spec forces and which are easy to get wrong:
//
//  * mtime keeps counting while mtimecmp is written.  On RV32 software
//    must write mtimecmp in two halves, and the classic hazard is a
//    spurious interrupt between them.  The documented sequence is to
//    write hi=0xffffffff first, then lo, then hi -- so the comparator
//    is never transiently below mtime.  Nothing here can enforce that;
//    it is written up in the programming manual.
//  * irq_timer_o is a LEVEL, not a pulse: it is high while
//    mtime >= mtimecmp and clears only when software moves mtimecmp.
//
// Configuration-register parity (V37 of variant 1) is preserved: losing
// it would cost ~8 points of LFM, because it is what took latent faults
// in the peripheral configuration from 46.4 % to zero.
//
// STATUS: NEW AND UNVERIFIED -- not through the O1-O9 gate.  Do not use.

`default_nettype none

module cdriscv_v2_clint #(
    parameter int unsigned PrescalerW = 16
) (
    input  logic        clk_i,
    input  logic        rst_ni,

    // simple memory-mapped slave (word accesses only)
    input  logic        req_i,
    input  logic        we_i,
    input  logic [15:0] addr_i,       // offset within the CLINT window
    input  logic [31:0] wdata_i,
    output logic [31:0] rdata_o,
    output logic        err_o,        // unmapped offset

    output logic        irq_timer_o,  // MTIP -- level
    output logic        irq_soft_o,   // MSIP -- level
    output logic        cfg_err_o     // configuration parity mismatch
);

  logic [63:0] mtime_q, mtimecmp_q;
  logic        msip_q;
  logic [PrescalerW-1:0] presc_q, presc_cnt_q;
  logic        tick;

  assign tick = (presc_cnt_q == presc_q);

  // ---- register file -------------------------------------------------
  logic hit_msip, hit_cmp_lo, hit_cmp_hi, hit_time_lo, hit_time_hi, hit_presc;
  assign hit_msip    = (addr_i == 16'h0000);
  assign hit_cmp_lo  = (addr_i == 16'h4000);
  assign hit_cmp_hi  = (addr_i == 16'h4004);
  assign hit_time_lo = (addr_i == 16'hBFF8);
  assign hit_time_hi = (addr_i == 16'hBFFC);
  assign hit_presc   = (addr_i == 16'h8000);   // non-standard extension

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mtime_q     <= 64'b0;
      mtimecmp_q  <= {64{1'b1}};      // no interrupt until software arms it
      msip_q      <= 1'b0;
      presc_q     <= '0;
      presc_cnt_q <= '0;
    end else begin
      // free-running counter, prescaled
      if (tick) begin
        presc_cnt_q <= '0;
        mtime_q     <= mtime_q + 64'd1;
      end else begin
        presc_cnt_q <= presc_cnt_q + 1'b1;
      end

      if (req_i && we_i) begin
        if (hit_msip)    msip_q            <= wdata_i[0];
        if (hit_cmp_lo)  mtimecmp_q[31:0]  <= wdata_i;
        if (hit_cmp_hi)  mtimecmp_q[63:32] <= wdata_i;
        if (hit_time_lo) mtime_q[31:0]     <= wdata_i;
        if (hit_time_hi) mtime_q[63:32]    <= wdata_i;
        if (hit_presc)   presc_q           <= wdata_i[PrescalerW-1:0];
      end
    end
  end

  always_comb begin
    unique case (1'b1)
      hit_msip    : rdata_o = {31'b0, msip_q};
      hit_cmp_lo  : rdata_o = mtimecmp_q[31:0];
      hit_cmp_hi  : rdata_o = mtimecmp_q[63:32];
      hit_time_lo : rdata_o = mtime_q[31:0];
      hit_time_hi : rdata_o = mtime_q[63:32];
      hit_presc   : rdata_o = {{(32-PrescalerW){1'b0}}, presc_q};
      default     : rdata_o = 32'h0;
    endcase
  end

  assign err_o = req_i && !(hit_msip | hit_cmp_lo | hit_cmp_hi |
                            hit_time_lo | hit_time_hi | hit_presc);

  // ---- interrupts: level, exactly as the privileged spec requires -----
  assign irq_timer_o = (mtime_q >= mtimecmp_q);
  assign irq_soft_o  = msip_q;

  // ---- configuration parity (variant 1 V37) ---------------------------
  // mtime is dynamic and deliberately excluded; mtimecmp, msip and the
  // prescaler are configuration and are covered.
  cdriscv_cfg_parity #(.Width(64 + 1 + PrescalerW)) u_cfg_par (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .cfg_i  ({mtimecmp_q, msip_q, presc_q}),
      .err_o  (cfg_err_o)
  );

endmodule
