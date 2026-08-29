// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-10 -- tightly coupled memory with SEC-DED protection.
//
// Single port, one word (32 data + 7 check bits) per location:
//
//   read          1 cycle latency, corrects single bit errors
//   full write    1 cycle, code word written directly
//   partial write 2 cycles (read-modify-write), because the check bits
//                 cover the whole word
//
// A test port (bist_*) bypasses the ECC logic and gives the memory BIST
// controller raw access to all 39 bits.  A fault injection input lets
// software corrupt a code word on purpose to prove that the detection
// path works (a latent fault metric argument needs this).
//
// The storage is described behaviourally so that the synthesis flow can
// either infer a RAM macro or map it to flip-flops.
//
// STATUS: verified to the O1-O7 gate of doc/verification_plan.md
//         (2026-08-24) -- may be used in a project.  O8-O9 and the
//         FMEDA are open: NOT qualified for safety-critical use.

`default_nettype none

module cdriscv_tcm
  import cdriscv_pkg::*;
#(
    parameter int unsigned Depth    = 4096,          // words
    parameter string       InitFile = ""             // simulation preload
)(
    input  logic        clk_i,
    input  logic        rst_ni,

    // OBI-like slave port
    input  logic        req_i,
    output logic        gnt_o,
    output logic        rvalid_o,
    input  logic        we_i,
    input  logic [3:0]  be_i,
    input  logic [31:0] addr_i,
    input  logic [31:0] wdata_i,
    output logic [31:0] rdata_o,
    output logic        err_o,

    // ECC status (single cycle pulses, aligned with rvalid_o)
    output logic        ecc_cor_o,
    output logic        ecc_unc_o,

    // Fault injection.  inj_en_i is a one cycle pulse that *arms* the
    // injection; the mask is then applied to the next functional write
    // and the arming clears.  It has to work that way: the pulse comes
    // from an APB write to the safety controller and the store it is
    // meant to corrupt is necessarily several cycles later, so a
    // same-cycle scheme can never be triggered by software (V4-F1).
    input  logic        inj_en_i,
    input  logic [38:0] inj_mask_i,

    // raw test port (memory BIST)
    input  logic        bist_en_i,
    input  logic        bist_we_i,
    input  logic [31:0] bist_addr_i,
    input  logic [38:0] bist_wdata_i,
    output logic [38:0] bist_rdata_o
);

  localparam int unsigned AW = (Depth > 1) ? $clog2(Depth) : 1;

  logic [38:0] mem [Depth];

  // ------------------------------------------------------------------
  // Optional simulation preload
  // ------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin
    if (InitFile != "") begin
      $readmemh(InitFile, mem);
    end
  end
`endif

  // ------------------------------------------------------------------
  // Request handling
  // ------------------------------------------------------------------
  logic        phase2_q;      // read-modify-write completion cycle
  logic        rvalid_q;
  logic        we_q;
  logic [3:0]  be_q;
  logic [31:0] wdata_q;
  logic [AW-1:0] addr_q;
  logic        inj_armed_q;
  logic [38:0] inj_arm_mask_q;

  logic full_word, partial_write, accept;

  assign full_word     = (be_i == 4'b1111);
  assign partial_write = we_i && !full_word;
  assign gnt_o         = req_i && !phase2_q && !bist_en_i;
  assign accept        = gnt_o;

  // ------------------------------------------------------------------
  // ECC encode / decode
  // ------------------------------------------------------------------
  logic [38:0] enc_cw;
  cdriscv_ecc_enc u_enc (
      .data_i (wdata_i),
      .cw_o   (enc_cw)
  );

  logic [38:0] rd_cw;          // code word read out of the array
  logic [31:0] dec_data;
  logic [6:0]  dec_syndrome;
  logic        dec_cor, dec_unc;

  cdriscv_ecc_dec u_dec (
      .cw_i         (rd_cw),
      .data_o       (dec_data),
      .syndrome_o   (dec_syndrome),
      .err_single_o (dec_cor),
      .err_double_o (dec_unc)
  );

  // merged word for the read-modify-write phase
  logic [31:0] merged_data;
  always_comb begin
    merged_data = dec_data;
    for (int unsigned b = 0; b < 4; b++) begin
      if (be_q[b]) merged_data[8*b +: 8] = wdata_q[8*b +: 8];
    end
  end

  logic [38:0] merged_cw;
  cdriscv_ecc_enc u_enc_merge (
      .data_i (merged_data),
      .cw_o   (merged_cw)
  );

  // ------------------------------------------------------------------
  // Memory port multiplexing
  // ------------------------------------------------------------------
  logic [AW-1:0] mem_addr;
  logic          mem_we, mem_re;
  logic [38:0]   mem_wdata;

  logic [AW-1:0] addr_word;
  assign addr_word = addr_i[AW+1:2];

  always_comb begin
    if (bist_en_i) begin
      mem_addr  = bist_addr_i[AW+1:2];
      mem_we    = bist_we_i;
      mem_re    = !bist_we_i;
      mem_wdata = bist_wdata_i;
    end else if (phase2_q) begin
      mem_addr  = addr_q;
      mem_we    = 1'b1;
      mem_re    = 1'b0;
      mem_wdata = inj_armed_q ? (merged_cw ^ inj_arm_mask_q) : merged_cw;
    end else begin
      mem_addr  = addr_word;
      mem_we    = accept && we_i && full_word;
      mem_re    = accept && (!we_i || partial_write);
      mem_wdata = inj_armed_q ? (enc_cw ^ inj_arm_mask_q) : enc_cw;
    end
  end

  always_ff @(posedge clk_i) begin
    if (mem_we) begin
      mem[mem_addr] <= mem_wdata;
    end
    if (mem_re) begin
      rd_cw <= mem[mem_addr];
    end
  end

  assign bist_rdata_o = rd_cw;

  // ------------------------------------------------------------------
  // Control registers
  // ------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      phase2_q   <= 1'b0;
      rvalid_q   <= 1'b0;
      we_q       <= 1'b0;
      be_q       <= 4'b0;
      wdata_q    <= 32'b0;
      addr_q     <= '0;
      inj_armed_q    <= 1'b0;
      inj_arm_mask_q <= 39'b0;
    end else begin
      phase2_q <= accept && partial_write;
      rvalid_q <= accept;

      // arm on the pulse, clear when a functional write consumes it
      if (inj_en_i) begin
        inj_armed_q    <= 1'b1;
        inj_arm_mask_q <= inj_mask_i;
      end else if (mem_we && !bist_en_i) begin
        inj_armed_q    <= 1'b0;
      end

      if (accept) begin
        we_q       <= we_i;
        be_q       <= be_i;
        wdata_q    <= wdata_i;
        addr_q     <= addr_word;

      end
    end
  end

  // ------------------------------------------------------------------
  // Response
  // ------------------------------------------------------------------
  // A read (and the read half of a read-modify-write) has its data one
  // cycle after acceptance, which is exactly when rvalid_q is set.
  logic checked;
  assign checked = rvalid_q && (!we_q || (we_q && (be_q != 4'b1111)));

  assign rvalid_o  = rvalid_q;
  assign rdata_o   = dec_data;
  assign ecc_cor_o = checked && dec_cor;
  assign ecc_unc_o = checked && dec_unc;
  assign err_o     = checked && dec_unc;

  // Unused bits of the byte address / upper address bits.
  logic unused_addr;
  assign unused_addr = |{addr_i[31:AW+2], addr_i[1:0], bist_addr_i[31:AW+2], bist_addr_i[1:0], dec_syndrome};

endmodule
