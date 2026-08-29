// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-10 -- safety controller (fault collection and reaction unit).
//
// Every fault source in the subsystem ends here.  Each source has one
// sticky status bit and a configurable reaction: interrupt, reset
// request, external error pin, or any combination.  The configuration
// can be locked until the next reset so that a runaway program cannot
// switch the safety reactions off.
//
//   0x00  STATUS    RW  sticky fault status, write 1 to clear
//   0x04  ENABLE    RW  per source: contribute to the status
//   0x08  REACT_IRQ RW  per source: raise the safety interrupt
//   0x0c  REACT_RST RW  per source: request a reset
//   0x10  REACT_PIN RW  per source: signal on the external error pin
//   0x14  CTRL      RW  [0] enable [1] pin invert [2] pin toggle mode
//                       [3] lock (sticky)
//   0x18  INJECT    WO  pulse the given fault bits for one cycle
//   0x1c  PIN_DIV   RW  half period of the healthy pin toggle
//   0x20  RAW       RO  current fault inputs, before the sticky stage
//   0x28  CFG_SRC   RO  which register group raised the configuration
//                       parity fault: [0] this block [1] watchdog
//                       [2] clock monitor [3] interrupt controller
//                       [4] timer [5] AMS [6] core mtvec.  Sticky;
//                       cleared by the W1C of STATUS bit 13.
//   0x24  SELFTEST  WO  one shot self tests, all bits self clearing
//                       [0] force a lockstep comparator mismatch
//                       [1] corrupt one bit of the next TCM write
//                       [2] corrupt two bits of the next TCM write
//                       [3] target: 0 = D-TCM, 1 = I-TCM
//                       The write here only *arms* the corruption; the
//                       TCM applies it to its next write and disarms.
//                       Anything else could not be triggered from
//                       software at all -- see finding V4-F1.
//
// Configuration parity (V29/V37).  Every mechanism above is armed by a
// register, and V29 measured that an upset in any of them was 100 %
// latent -- including this block's own ENABLE and CTRL, where the
// register the fault disabled was the one that would have recorded it.
// Each register group in the subsystem now carries one parity bit
// (cdriscv_cfg_parity); the mismatch signals arrive here on cfg_err_i,
// this block guards its own configuration the same way, and the result
// latches into STATUS bit 13 (FLT_CFG_PAR) UNGATED -- not masked by
// ENABLE, not masked by CTRL.enable -- with its interrupt and error
// pin reaction hardwired rather than taken from REACT_*.  A fault that
// may have corrupted the reaction configuration cannot be left asking
// that same configuration for permission to report.
//
// External error pin protocol.  In level mode the pin is asserted while
// a fault is latched.  In toggle mode the pin carries a square wave
// while the subsystem is healthy and stops when a fault is latched, so
// that an external monitor also notices a subsystem that has stopped
// working entirely -- a stuck-at fault on the pin itself no longer
// looks healthy.
//
// STATUS: verified to the O1-O7 gate of doc/verification_plan.md
//         (2026-08-24) -- may be used in a project.  O8-O9 and the
//         FMEDA are open: NOT qualified for safety-critical use.

`default_nettype none

module cdriscv_safety_ctrl
  import cdriscv_pkg::*;
(
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic        psel_i,
    input  logic        penable_i,
    input  logic [11:0] paddr_i,
    input  logic        pwrite_i,
    input  logic [31:0] pwdata_i,
    output logic [31:0] prdata_o,
    output logic        pready_o,
    output logic        pslverr_o,

    // fault sources
    input  logic [NUM_INT_FAULTS-1:0] fault_int_i,   // synchronous to clk_i
    input  logic [NUM_EXT_FAULTS-1:0] fault_ext_i,   // asynchronous, from the SoC
    input  logic [5:0]                cfg_err_i,     // config parity: wdog, clkmon,
                                                     // irqc, timer, ams, core mtvec

    // reactions
    output logic        irq_o,
    output logic        reset_req_o,
    output logic        err_pin_o,
    output logic        fault_any_o,

    // self test hooks driven by this block
    output logic        inj_lockstep_o,
    output logic        inj_itcm_en_o,
    output logic        inj_dtcm_en_o,
    output logic [38:0] inj_tcm_mask_o
);

  // ------------------------------------------------------------------
  // Registers
  // ------------------------------------------------------------------
  logic [31:0] status_q, enable_q, react_irq_q, react_rst_q, react_pin_q;
  logic        ctrl_en_q, pin_inv_q, pin_tog_q, lock_q;
  logic [15:0] pin_div_q;
  logic [31:0] inject_q;
  logic [3:0]  selftest_q;

  logic wr, rd, cfg_wr;
  assign wr     = psel_i && penable_i &&  pwrite_i;
  assign rd     = psel_i && !pwrite_i;
  assign cfg_wr = wr && !lock_q;

  // ------------------------------------------------------------------
  // Fault input conditioning
  // ------------------------------------------------------------------
  logic [NUM_EXT_FAULTS-1:0] fault_ext_sync;

  for (genvar i = 0; i < NUM_EXT_FAULTS; i++) begin : g_ext_sync
    cdriscv_sync_lvl #(.Stages(2)) u_sync (
        .clk_i  (clk_i),
        .rst_ni (rst_ni),
        .d_i    (fault_ext_i[i]),
        .q_o    (fault_ext_sync[i])
    );
  end

  logic [31:0] fault_raw;
  assign fault_raw = {fault_ext_sync, fault_int_i} | inject_q;

  logic [31:0] fault_latched;
  assign fault_latched = fault_raw & enable_q & {32{ctrl_en_q}};

  // ------------------------------------------------------------------
  // Configuration parity -- own registers, and the collected errors
  // ------------------------------------------------------------------
  logic cfg_err_own;
  cdriscv_cfg_parity #(.Width(4*32 + 4 + 16)) u_cfg_par (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .cfg_i  ({enable_q, react_irq_q, react_rst_q, react_pin_q,
                ctrl_en_q, pin_inv_q, pin_tog_q, lock_q, pin_div_q}),
      .wr_i   (wr && ((paddr_i[7:0] == 8'h04) || (paddr_i[7:0] == 8'h08) ||
                      (paddr_i[7:0] == 8'h0c) || (paddr_i[7:0] == 8'h10) ||
                      (paddr_i[7:0] == 8'h14) || (paddr_i[7:0] == 8'h1c))),
      .err_o  (cfg_err_own)
  );

  logic [6:0]  cfg_src;
  logic [6:0]  cfg_src_q;
  assign cfg_src = {cfg_err_i[5:0], cfg_err_own};

  // The one status contribution that no configuration can gate.
  logic [31:0] cfg_fault_set;
  assign cfg_fault_set = |cfg_src ? (32'b1 << FLT_CFG_PAR) : 32'b0;

  // ------------------------------------------------------------------
  // Register file
  // ------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      status_q    <= 32'b0;
      cfg_src_q   <= 7'b0;
      enable_q    <= 32'hffff_ffff;
      react_irq_q <= 32'hffff_ffff;
      react_rst_q <= 32'b0;
      react_pin_q <= 32'hffff_ffff;
      ctrl_en_q   <= 1'b1;
      pin_inv_q   <= 1'b0;
      pin_tog_q   <= 1'b0;
      lock_q      <= 1'b0;
      pin_div_q   <= 16'd1023;
      inject_q    <= 32'b0;
      selftest_q  <= 4'b0;
    end else begin
      status_q   <= status_q | fault_latched | cfg_fault_set;
      cfg_src_q  <= cfg_src_q | cfg_src;
      inject_q   <= 32'b0;                     // injection is a one cycle pulse
      selftest_q <= 4'b0;

      if (wr) begin
        unique case (paddr_i[7:0])
          8'h00: begin
            status_q <= (status_q & ~pwdata_i) | fault_latched | cfg_fault_set;   // W1C
            if (pwdata_i[FLT_CFG_PAR]) cfg_src_q <= cfg_src;   // clears with its bit
          end
          8'h04:   if (cfg_wr) enable_q    <= pwdata_i;
          8'h08:   if (cfg_wr) react_irq_q <= pwdata_i;
          8'h0c:   if (cfg_wr) react_rst_q <= pwdata_i;
          8'h10:   if (cfg_wr) react_pin_q <= pwdata_i;
          8'h14: begin
            if (cfg_wr) begin
              ctrl_en_q <= pwdata_i[0];
              pin_inv_q <= pwdata_i[1];
              pin_tog_q <= pwdata_i[2];
            end
            if (pwdata_i[3]) lock_q <= 1'b1;
          end
          8'h18:   inject_q  <= pwdata_i;
          8'h1c:   if (cfg_wr) pin_div_q <= pwdata_i[15:0];
          8'h24:   selftest_q <= pwdata_i[3:0];
          default: ;
        endcase
      end
    end
  end

  // ------------------------------------------------------------------
  // Reactions
  // ------------------------------------------------------------------
  // The configuration parity bit reacts unconditionally: REACT_* may be
  // exactly what the fault corrupted.
  assign irq_o       = |(status_q & react_irq_q) || status_q[FLT_CFG_PAR];
  assign fault_any_o = |status_q;

  // The reset request is a pulse per fault, not a level.
  //
  // It cannot be a level: the status is sticky and only software can
  // clear it, so a level would hold the core in reset for ever and the
  // software that was supposed to clear it would never run again.  A
  // configured reset reaction would turn the first fault of that class
  // into a permanently dead subsystem -- worse than having no reaction
  // at all.  Found by V7-F1.
  //
  // rst_acted_q remembers which fault bits have already had their
  // reset, and is itself cleared when software clears the status, so a
  // later recurrence of the same fault requests a new reset.
  logic [31:0] rst_pending, rst_acted_q;

  assign rst_pending = status_q & react_rst_q;
  assign reset_req_o = |(rst_pending & ~rst_acted_q);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) rst_acted_q <= 32'b0;
    else         rst_acted_q <= (rst_acted_q | rst_pending) & status_q;
  end

  logic pin_fault;
  assign pin_fault = |(status_q & react_pin_q) || status_q[FLT_CFG_PAR];

  logic [15:0] pin_cnt_q;
  logic        pin_tog_q_state;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pin_cnt_q       <= 16'b0;
      pin_tog_q_state <= 1'b0;
    end else if (pin_fault) begin
      pin_cnt_q       <= 16'b0;
      pin_tog_q_state <= 1'b0;                 // healthy toggling stops
    end else if (pin_cnt_q >= pin_div_q) begin
      pin_cnt_q       <= 16'b0;
      pin_tog_q_state <= ~pin_tog_q_state;
    end else begin
      pin_cnt_q <= pin_cnt_q + 16'd1;
    end
  end

  logic pin_value;
  assign pin_value = pin_tog_q ? pin_tog_q_state : pin_fault;
  assign err_pin_o = pin_value ^ pin_inv_q;

  // ------------------------------------------------------------------
  // Self test outputs
  // ------------------------------------------------------------------
  // Bit 0 of a code word is flipped for a correctable error; bits 0 and
  // 1 for an uncorrectable one.  The enable goes to one TCM only, so a
  // test corrupts the memory it means to and leaves the other alone.
  logic inj_tcm_any;
  assign inj_tcm_any    = selftest_q[1] || selftest_q[2];
  assign inj_lockstep_o = selftest_q[0];
  assign inj_itcm_en_o  = inj_tcm_any &&  selftest_q[3];
  assign inj_dtcm_en_o  = inj_tcm_any && !selftest_q[3];
  assign inj_tcm_mask_o = selftest_q[2] ? 39'h3 : 39'h1;

  // ------------------------------------------------------------------
  // Read back
  // ------------------------------------------------------------------
  always_comb begin
    prdata_o = 32'b0;
    if (rd) begin
      unique case (paddr_i[7:0])
        8'h00:   prdata_o = status_q;
        8'h04:   prdata_o = enable_q;
        8'h08:   prdata_o = react_irq_q;
        8'h0c:   prdata_o = react_rst_q;
        8'h10:   prdata_o = react_pin_q;
        8'h14:   prdata_o = {28'b0, lock_q, pin_tog_q, pin_inv_q, ctrl_en_q};
        8'h1c:   prdata_o = {16'b0, pin_div_q};
        8'h20:   prdata_o = fault_raw;
        8'h28:   prdata_o = {25'b0, cfg_src_q};
        default: prdata_o = 32'b0;
      endcase
    end
  end

  assign pready_o  = 1'b1;
  assign pslverr_o = 1'b0;

endmodule
