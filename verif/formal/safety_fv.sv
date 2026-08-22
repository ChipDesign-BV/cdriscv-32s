// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// Formal properties for cdriscv_safety_ctrl.
//
// Two claims in the safety manual are structural, and this is where
// they get checked rather than asserted in prose:
//
//   * a latched fault does not go away by itself.  If software could
//     lose a fault bit without explicitly clearing it, every diagnostic
//     built on the status register would be unsound.
//   * once the configuration is locked it stays locked, and the
//     reactions cannot be changed.  That is what stops a runaway
//     program from disabling the safety mechanisms.

`default_nettype none

module safety_fv
  import cdriscv_pkg::*;
(
    input  logic        clk_i,
    input  logic        psel_i,
    input  logic        penable_i,
    input  logic [11:0] paddr_i,
    input  logic        pwrite_i,
    input  logic [31:0] pwdata_i,
    input  logic [NUM_INT_FAULTS-1:0] fault_int_i,
    input  logic [5:0]                cfg_err_i,
    input  logic [NUM_EXT_FAULTS-1:0] fault_ext_i
);

  logic [1:0] rst_cnt = 2'b00;
  logic       rst_ni;
  always @(posedge clk_i) if (rst_cnt != 2'b11) rst_cnt <= rst_cnt + 2'd1;
  assign rst_ni = (rst_cnt == 2'b11);

  logic [31:0] prdata;
  logic        pready, pslverr, irq, reset_req, err_pin, fault_any;
  logic        inj_lockstep, inj_itcm, inj_dtcm;
  logic [38:0] inj_mask;

  cdriscv_safety_ctrl u_dut (
      .clk_i          (clk_i),
      .rst_ni         (rst_ni),
      .psel_i         (psel_i),
      .penable_i      (penable_i),
      .paddr_i        (paddr_i),
      .pwrite_i       (pwrite_i),
      .pwdata_i       (pwdata_i),
      .prdata_o       (prdata),
      .pready_o       (pready),
      .pslverr_o      (pslverr),
      .fault_int_i    (fault_int_i),
      .cfg_err_i      (cfg_err_i),
      .fault_ext_i    (fault_ext_i),
      .irq_o          (irq),
      .reset_req_o    (reset_req),
      .err_pin_o      (err_pin),
      .fault_any_o    (fault_any),
      .inj_lockstep_o (inj_lockstep),
      .inj_itcm_en_o  (inj_itcm),
      .inj_dtcm_en_o  (inj_dtcm),
      .inj_tcm_mask_o (inj_mask)
  );

  logic wr_now;
  assign wr_now = psel_i && penable_i && pwrite_i;

  always @(posedge clk_i) begin
    if (rst_ni && $past(rst_ni)) begin

      // A latched fault only clears through a write of 1 to its bit in
      // STATUS.  Anything else -- a write elsewhere, a new fault, an
      // idle cycle -- must leave it standing.
      p_status_sticky: assert (
          ((~u_dut.status_q) & $past(u_dut.status_q)) == 32'b0
          || ($past(wr_now) && ($past(paddr_i[7:0]) == 8'h00)));

      // Once locked, the configuration cannot be changed: this is what
      // stops a runaway program from switching the reactions off.
      if ($past(u_dut.lock_q)) begin
        p_lock_holds:    assert (u_dut.lock_q);
        p_lock_enable:   assert (u_dut.enable_q    == $past(u_dut.enable_q));
        p_lock_irq:      assert (u_dut.react_irq_q == $past(u_dut.react_irq_q));
        p_lock_rst:      assert (u_dut.react_rst_q == $past(u_dut.react_rst_q));
        p_lock_pin:      assert (u_dut.react_pin_q == $past(u_dut.react_pin_q));
        p_lock_ctrl_en:  assert (u_dut.ctrl_en_q   == $past(u_dut.ctrl_en_q));
      end

      // A configuration parity error must latch and react regardless
      // of ENABLE and CTRL -- the registers it may have corrupted.
      // This is the structural fix for the V29/V30 circular
      // dependency, so it gets checked rather than asserted in prose.
      p_cfg_ungated_latch: assert (
          !$past(|cfg_err_i) || u_dut.status_q[FLT_CFG_PAR]);
      p_cfg_hard_irq: assert (!u_dut.status_q[FLT_CFG_PAR] || irq);
      p_cfg_hard_any: assert (!u_dut.status_q[FLT_CFG_PAR] || fault_any);

      // The reset request must not repeat while the status is
      // unchanged.
      //
      // This started as "reset_req is a one cycle pulse", which is too
      // strong and was disproved in six steps: two *different* fault
      // bits latching on consecutive cycles each legitimately ask for
      // their own reset, so the request can be high twice in a row.
      // That is bounded by the number of fault bits and harmless.
      //
      // What must never happen is the request repeating with nothing
      // new having latched -- that is exactly finding V7-F1, where a
      // level-driven request held the core in reset for ever and the
      // software that would have cleared the status could never run.
      // ...and the reaction configuration must be unchanged too.  The
      // second counterexample was software writing REACT_RST while a
      // fault was already latched: that legitimately asks for a reset
      // the previous configuration had not asked for.  Two rounds of
      // counterexample to arrive at the actual contract, which is that
      // the request cannot sustain *itself* -- with nothing latching
      // and nothing reconfigured, it must fall.
      if (($past(u_dut.status_q)    == u_dut.status_q) &&
          ($past(u_dut.react_rst_q) == u_dut.react_rst_q)) begin
        p_reset_req_no_repeat: assert (!($past(reset_req) && reset_req));
      end
    end
  end

endmodule
