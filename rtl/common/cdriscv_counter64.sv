// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-10 -- 64-bit up counter in four 16-bit segments with
// predicted carries.
//
// A 64-bit `q <= q + 1` synthesises as one carry chain, and V38
// measured exactly that as the subsystem's critical path: 76 MHz
// placed and buffered, set by mcycle/minstret rather than by any
// datapath.  Splitting on `&low` does not help -- abc recognises the
// AND-reduce as the carry-out of the low increment, shares the chain,
// and rebuilds the ripple.
//
// Here each segment's carry-in is a flip-flop, computed one cycle
// early from *comparisons only*: after this cycle's update, segment k
// is all-ones iff (written with ffff) or (incremented from fffe) or
// (held at ffff).  No adder feeds a prediction, no prediction feeds an
// adder combinationally, so nothing gives synthesis a legal way to
// stitch the segments back together.  The longest path is one 16-bit
// incrementer.
//
// Semantics are bit-exact to
//     if (wr_lo_i) q[31:0]  <= wdata_i; else
//     if (wr_hi_i) q[63:32] <= wdata_i;      // writes win over the
//     q <= q + {63'b0, inc_i};               // increment, per half
// including a write and an increment in the same cycle (the written
// half takes the written value, the other half still counts) -- proven
// sequentially equivalent with yosys equiv_induct against the
// reference above, and V37's fault campaign re-run on top.
//
// STATUS: verified to the O1-O7 gate of doc/verification_plan.md
//         (2026-08-24) -- may be used in a project.  O8-O9 and the
//         FMEDA are open: NOT qualified for safety-critical use.

`default_nettype none

module cdriscv_counter64 (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        inc_i,
    input  logic        wr_lo_i,     // write q[31:0]  this cycle
    input  logic        wr_hi_i,     // write q[63:32] this cycle
    input  logic [31:0] wdata_i,
    output logic [63:0] q_o
);

  logic [15:0] s_q [4];
  logic [2:0]  carry_q;    // carry_q[k]: segments 0..k are all-ones now

  logic e0, e1, e2, e3;
  assign e0 = inc_i;
  assign e1 = inc_i && carry_q[0];
  assign e2 = inc_i && carry_q[1];
  assign e3 = inc_i && carry_q[2];

  // Will segment k read all-ones after this cycle's update?
  // Comparisons only -- this is the point of the whole module.
  logic n0, n1, n2;
  assign n0 = wr_lo_i ? (wdata_i[15:0]  == 16'hffff)
            : e0      ? (s_q[0] == 16'hfffe) : (s_q[0] == 16'hffff);
  assign n1 = wr_lo_i ? (wdata_i[31:16] == 16'hffff)
            : e1      ? (s_q[1] == 16'hfffe) : (s_q[1] == 16'hffff);
  assign n2 = wr_hi_i ? (wdata_i[15:0]  == 16'hffff)
            : e2      ? (s_q[2] == 16'hfffe) : (s_q[2] == 16'hffff);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s_q[0]  <= 16'b0;
      s_q[1]  <= 16'b0;
      s_q[2]  <= 16'b0;
      s_q[3]  <= 16'b0;
      carry_q <= 3'b0;
    end else begin
      s_q[0] <= wr_lo_i ? wdata_i[15:0]  : (s_q[0] + {15'b0, e0});
      s_q[1] <= wr_lo_i ? wdata_i[31:16] : (s_q[1] + {15'b0, e1});
      s_q[2] <= wr_hi_i ? wdata_i[15:0]  : (s_q[2] + {15'b0, e2});
      s_q[3] <= wr_hi_i ? wdata_i[31:16] : (s_q[3] + {15'b0, e3});
      carry_q[0] <= n0;
      carry_q[1] <= n0 && n1;
      carry_q[2] <= n0 && n1 && n2;
    end
  end

  assign q_o = {s_q[3], s_q[2], s_q[1], s_q[0]};

endmodule
