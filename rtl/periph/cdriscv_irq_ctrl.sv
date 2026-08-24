// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s -- interrupt controller, APB slave.
//
// Collects up to NumSrc SoC interrupt lines into the single external
// machine interrupt of the core, and provides the software interrupt
// (msip).  Sources are individually configurable as level or rising
// edge; edge sources are latched in PENDING until software clears them.
//
//   0x00  PENDING  RW  sticky pending bits, write 1 to clear
//   0x04  ENABLE   RW  per source enable
//   0x08  CLAIM    RO  index of the lowest numbered pending source,
//                      0x1f when nothing is pending
//   0x0c  MSIP     RW  [0] software interrupt to the core
//   0x10  MODE     RW  0 = level sensitive, 1 = rising edge
//
// STATUS: verified to the O1-O7 gate of doc/verification_plan.md
//         (2026-08-24) -- may be used in a project.  O8-O9 and the
//         FMEDA are open: NOT qualified for safety-critical use.

`default_nettype none

module cdriscv_irq_ctrl #(
    parameter int unsigned NumSrc = 16
)(
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

    input  logic [NumSrc-1:0] src_i,      // asynchronous SoC interrupt lines

    output logic        irq_ext_o,
    output logic        irq_soft_o,
    output logic        cfg_err_o    // level: configuration parity mismatch
);

  logic [NumSrc-1:0] enable_q, mode_q, pending_q, src_sync, src_sync_q;
  logic              msip_q;

  logic wr, rd;
  assign wr = psel_i && penable_i &&  pwrite_i;
  assign rd = psel_i && !pwrite_i;

  for (genvar i = 0; i < NumSrc; i++) begin : g_src_sync
    cdriscv_sync_lvl #(.Stages(2)) u_sync (
        .clk_i  (clk_i),
        .rst_ni (rst_ni),
        .d_i    (src_i[i]),
        .q_o    (src_sync[i])
    );
  end

  logic [NumSrc-1:0] edge_detect, set_bits;
  assign edge_detect = src_sync & ~src_sync_q;
  assign set_bits    = (mode_q & edge_detect) | (~mode_q & src_sync);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      enable_q   <= '0;
      mode_q     <= '0;
      pending_q  <= '0;
      src_sync_q <= '0;
      msip_q     <= 1'b0;
    end else begin
      src_sync_q <= src_sync;

      // level sources follow their input, edge sources stay set
      pending_q <= (pending_q & mode_q) | set_bits;

      if (wr) begin
        unique case (paddr_i[7:0])
          8'h00:   pending_q <= ((pending_q & ~pwdata_i[NumSrc-1:0]) & mode_q) | set_bits;
          8'h04:   enable_q  <= pwdata_i[NumSrc-1:0];
          8'h0c:   msip_q    <= pwdata_i[0];
          8'h10:   mode_q    <= pwdata_i[NumSrc-1:0];
          default: ;
        endcase
      end
    end
  end

  logic [NumSrc-1:0] active;
  assign active = pending_q & enable_q;

  logic [4:0] claim;
  always_comb begin
    claim = 5'd31;
    for (int unsigned i = NumSrc; i > 0; i--) begin
      if (active[i-1]) claim = 5'(i - 1);
    end
  end

  always_comb begin
    prdata_o = 32'b0;
    if (rd) begin
      unique case (paddr_i[7:0])
        8'h00:   prdata_o = {{(32-NumSrc){1'b0}}, pending_q};
        8'h04:   prdata_o = {{(32-NumSrc){1'b0}}, enable_q};
        8'h08:   prdata_o = {27'b0, claim};
        8'h0c:   prdata_o = {31'b0, msip_q};
        8'h10:   prdata_o = {{(32-NumSrc){1'b0}}, mode_q};
        default: prdata_o = 32'b0;
      endcase
    end
  end

  assign pready_o   = 1'b1;
  assign pslverr_o  = 1'b0;
  assign irq_ext_o  = |active;
  assign irq_soft_o = msip_q;

  // ------------------------------------------------------------------
  // Configuration parity (V29): ENABLE and MODE.  pending_q follows
  // the sources and msip_q is a software doorbell; both are dynamic
  // by design and excluded.
  // ------------------------------------------------------------------
  cdriscv_cfg_parity #(.Width(2*NumSrc)) u_cfg_par (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .cfg_i  ({enable_q, mode_q}),
      .wr_i   (wr && ((paddr_i[7:0] == 8'h04) ||
                      (paddr_i[7:0] == 8'h10))),
      .err_o  (cfg_err_o)
  );

endmodule
