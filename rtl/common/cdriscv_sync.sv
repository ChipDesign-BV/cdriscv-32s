// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s -- clock-domain-crossing primitives.
//
// These are the only places in the IP where an asynchronous signal is
// sampled.  Keep the flip-flop chains intact when constraining the
// design (set_false_path / ASYNC_REG equivalents apply to the *_q
// chains inside this file).
//
// STATUS: verified to the O1-O7 gate of doc/verification_plan.md
//         (2026-08-24) -- may be used in a project.  O8-O9 and the
//         FMEDA are open: NOT qualified for safety-critical use.

`default_nettype none

// ---------------------------------------------------------------------
// Level synchroniser
// ---------------------------------------------------------------------
module cdriscv_sync_lvl #(
    parameter int unsigned Stages   = 2,
    parameter bit          ResetVal = 1'b0
)(
    input  logic clk_i,
    input  logic rst_ni,
    input  logic d_i,
    output logic q_o
);

  logic [Stages-1:0] sync_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) sync_q <= {Stages{ResetVal}};
    else         sync_q <= {sync_q[Stages-2:0], d_i};
  end

  assign q_o = sync_q[Stages-1];

endmodule

// ---------------------------------------------------------------------
// Reset synchroniser: asynchronous assert, synchronous de-assert
// ---------------------------------------------------------------------
module cdriscv_rst_sync #(
    parameter int unsigned Stages = 3
)(
    input  logic clk_i,
    input  logic rst_ni,
    output logic rst_no
);

  logic [Stages-1:0] sync_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) sync_q <= '0;
    else         sync_q <= {sync_q[Stages-2:0], 1'b1};
  end

  assign rst_no = sync_q[Stages-1];

endmodule

// ---------------------------------------------------------------------
// Pulse synchroniser (source pulse -> destination pulse), toggle based
// ---------------------------------------------------------------------
module cdriscv_pulse_sync #(
    parameter int unsigned Stages = 2
)(
    input  logic src_clk_i,
    input  logic src_rst_ni,
    input  logic src_pulse_i,

    input  logic dst_clk_i,
    input  logic dst_rst_ni,
    output logic dst_pulse_o
);

  logic toggle_q;

  always_ff @(posedge src_clk_i or negedge src_rst_ni) begin
    if (!src_rst_ni) toggle_q <= 1'b0;
    else if (src_pulse_i) toggle_q <= ~toggle_q;
  end

  logic sync_out, sync_out_q;

  cdriscv_sync_lvl #(.Stages(Stages)) u_sync (
      .clk_i  (dst_clk_i),
      .rst_ni (dst_rst_ni),
      .d_i    (toggle_q),
      .q_o    (sync_out)
  );

  always_ff @(posedge dst_clk_i or negedge dst_rst_ni) begin
    if (!dst_rst_ni) sync_out_q <= 1'b0;
    else             sync_out_q <= sync_out;
  end

  assign dst_pulse_o = sync_out ^ sync_out_q;

endmodule
