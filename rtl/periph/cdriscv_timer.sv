// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-10 -- machine timer (mtime / mtimecmp), APB slave.
//
//   0x00  MTIME_LO     RW  free running counter, low word
//   0x04  MTIME_HI     RW  free running counter, high word
//   0x08  MTIMECMP_LO  RW  compare value, low word
//   0x0c  MTIMECMP_HI  RW  compare value, high word
//   0x10  CTRL         RW  bit 0: counter enable
//   0x14  PRESCALER    RW  [15:0] divider, tick every (PRESCALER+1) cycles
//
// irq_o follows mtime >= mtimecmp, exactly as the privileged
// specification requires (level, cleared by writing mtimecmp).
//
// STATUS: verified to the O1-O7 gate of doc/verification_plan.md
//         (2026-08-24) -- may be used in a project.  O8-O9 and the
//         FMEDA are open: NOT qualified for safety-critical use.

`default_nettype none

module cdriscv_timer (
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

    output logic        irq_o,
    output logic        cfg_err_o    // level: configuration parity mismatch
);

  logic [63:0] mtime_q, mtimecmp_q;
  logic        enable_q;
  logic [15:0] prescaler_q;
  logic [15:0] presc_cnt_q;

  logic wr, rd;
  assign wr = psel_i && penable_i &&  pwrite_i;
  assign rd = psel_i && !pwrite_i;

  logic tick;
  assign tick = enable_q && (presc_cnt_q == 16'b0);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mtime_q     <= 64'b0;
      mtimecmp_q  <= 64'hffff_ffff_ffff_ffff;
      enable_q    <= 1'b1;
      prescaler_q <= 16'b0;
      presc_cnt_q <= 16'b0;
    end else begin
      if (enable_q) begin
        if (presc_cnt_q == 16'b0) presc_cnt_q <= prescaler_q;
        else                      presc_cnt_q <= presc_cnt_q - 16'd1;
      end
      if (tick) mtime_q <= mtime_q + 64'd1;

      if (wr) begin
        unique case (paddr_i[7:0])
          8'h00:   mtime_q[31:0]     <= pwdata_i;
          8'h04:   mtime_q[63:32]    <= pwdata_i;
          8'h08:   mtimecmp_q[31:0]  <= pwdata_i;
          8'h0c:   mtimecmp_q[63:32] <= pwdata_i;
          8'h10:   enable_q          <= pwdata_i[0];
          8'h14:   prescaler_q       <= pwdata_i[15:0];
          default: ;
        endcase
      end
    end
  end

  always_comb begin
    prdata_o = 32'b0;
    if (rd) begin
      unique case (paddr_i[7:0])
        8'h00:   prdata_o = mtime_q[31:0];
        8'h04:   prdata_o = mtime_q[63:32];
        8'h08:   prdata_o = mtimecmp_q[31:0];
        8'h0c:   prdata_o = mtimecmp_q[63:32];
        8'h10:   prdata_o = {31'b0, enable_q};
        8'h14:   prdata_o = {16'b0, prescaler_q};
        default: prdata_o = 32'b0;
      endcase
    end
  end

  assign pready_o  = 1'b1;
  assign pslverr_o = 1'b0;
  assign irq_o     = (mtime_q >= mtimecmp_q);

  // ------------------------------------------------------------------
  // Configuration parity (V29): MTIMECMP, ENABLE, PRESCALER.  mtime_q
  // counts on its own and is excluded.  An upset in MTIMECMP moves the
  // one deadline the software relies on; V29 measured it 97/97 latent.
  // ------------------------------------------------------------------
  cdriscv_cfg_parity #(.Width(64 + 1 + 16)) u_cfg_par (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .cfg_i  ({mtimecmp_q, enable_q, prescaler_q}),
      .wr_i   (wr && ((paddr_i[7:0] == 8'h08) ||
                      (paddr_i[7:0] == 8'h0c) ||
                      (paddr_i[7:0] == 8'h10) ||
                      (paddr_i[7:0] == 8'h14))),
      .err_o  (cfg_err_o)
  );

endmodule
