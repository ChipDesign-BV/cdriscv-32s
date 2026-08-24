// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s -- configuration register parity guard.
//
// V29 measured that every safety mechanism in this subsystem is armed
// by a register and not one of those registers was protected: an upset
// in any of them switched the mechanism off, or moved its threshold,
// and the design went on producing correct results with nothing to say
// it had been disarmed.  1 207 of 2 600 injections were latent, and
// twelve elements were latent every single time.
//
// This block closes that gap for one register group.  The enclosing
// module concatenates its configuration state into cfg_i and pulses
// wr_i on every architectural write to any register in the group.  One
// parity bit is captured the cycle after the write -- from the stored
// value, so the capture cannot disagree with the register it guards --
// and compared against the group continuously ever after.  A bit flip
// anywhere in the group raises err_o within a cycle and holds it until
// software rewrites the register.
//
// Two windows are accepted and documented rather than closed:
//  * the capture cycle itself (an upset landing in the one cycle
//    between a write and its parity capture is folded into the
//    baseline), and
//  * fields the hardware itself updates, which must not be in cfg_i at
//    all -- a self-clearing enable would otherwise raise a permanent
//    false error the first time it cleared itself.
//
// STATUS: verified to the O1-O7 gate of doc/verification_plan.md
//         (2026-08-24) -- may be used in a project.  O8-O9 and the
//         FMEDA are open: NOT qualified for safety-critical use.

`default_nettype none

module cdriscv_cfg_parity #(
    parameter int unsigned Width = 32
)(
    input  logic             clk_i,
    input  logic             rst_ni,
    input  logic [Width-1:0] cfg_i,
    input  logic             wr_i,    // any protected register written this cycle
    output logic             err_o
);

  logic par_q, wrote_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      // Coming out of reset the registers hold their reset values and
      // par_q holds nothing; pretending a write just happened makes the
      // first cycle capture the reset values' parity instead of keeping
      // a table of per-block reset constants in sync by hand.
      wrote_q <= 1'b1;
      par_q   <= 1'b0;
    end else begin
      wrote_q <= wr_i;
      if (wrote_q) par_q <= ^cfg_i;
    end
  end

  // Masked during the cycle after a write, when cfg_i is already new
  // and par_q is still old.  During the write cycle itself both are
  // still old and agree, so no mask is needed there.
  assign err_o = !wrote_q && ((^cfg_i) ^ par_q);

endmodule
