// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-10 -- TCM with the storage mapped to real SRAM macros, for
// physical timing runs only.
//
// The plain gate-level flow black-boxes the whole TCM
// (cdriscv_tcm_bb.sv), which keeps synthesis honest about the storage
// but silently removes the ECC encoders and decoders from the timing
// picture -- and core -> ECC encode -> array is a candidate critical
// path.  This variant keeps every piece of TCM logic synthesisable and
// replaces only the 4096 x 39 array itself with two banks of the IHP
// RM_IHPSG13_1P_2048x64_c2_bm_bist compiled SRAM (39 of 64 bits used),
// so OpenROAD sees real macro geometry and OpenSTA sees real macro
// timing arcs on the paths that matter.
//
// Behavioural differences from rtl/bus/cdriscv_tcm.sv, all irrelevant
// to timing: no InitFile preload, no X-checking, unused DIN bits tied
// low.  This file must never be used in simulation.
//
// STATUS: TIMING MODEL ONLY -- NOT FOR SIMULATION OR TAPE-OUT.

`default_nettype none

module cdriscv_tcm_mac
  import cdriscv_pkg::*;
#(
    parameter int unsigned Depth    = 4096,          // fixed at 4096 here
    parameter string       InitFile = ""             // ignored
)(
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic        req_i,
    output logic        gnt_o,
    output logic        rvalid_o,
    input  logic        we_i,
    input  logic [3:0]  be_i,
    input  logic [31:0] addr_i,
    input  logic [31:0] wdata_i,
    output logic [31:0] rdata_o,
    output logic        err_o,

    output logic        ecc_cor_o,
    output logic        ecc_unc_o,

    input  logic        inj_en_i,
    input  logic [38:0] inj_mask_i,

    input  logic        bist_en_i,
    input  logic        bist_we_i,
    input  logic [31:0] bist_addr_i,
    input  logic [38:0] bist_wdata_i,
    output logic [38:0] bist_rdata_o
);

  localparam int unsigned AW = 12;   // 4096 words: 2 banks x 2048

  // ------------------------------------------------------------------
  // Request handling -- identical to rtl/bus/cdriscv_tcm.sv
  // ------------------------------------------------------------------
  logic        phase2_q;
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

  logic [38:0] enc_cw;
  cdriscv_ecc_enc u_enc (
      .data_i (wdata_i),
      .cw_o   (enc_cw)
  );

  logic [38:0] rd_cw;
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

  // ------------------------------------------------------------------
  // The storage: data and check bits in separately sized macros, so no
  // array bit goes unused.  Before, one 2048x64 per bank held a 39-bit
  // code word and threw away 25 bits of every row -- 39.1 % of the
  // array (V47).
  //
  //   data   [31:0]  two 2048x32, bank select on address bit 11
  //   parity [38:32] one 4096x8 spanning both banks, so it needs no
  //                  bank select -- and no 2048x8 part, which the PDK
  //                  does not offer.  One of the eight bits is spare.
  //
  // 1.337 mm2 for both TCMs against 1.967 mm2 before, at identical
  // capacity and with the (39,32) code untouched.
  //
  // The macros' read registers replace the rd_cw flop of the RTL; the
  // bank select is registered alongside so the read mux follows the
  // data it selects.  The parity macro needs no such mux.
  // ------------------------------------------------------------------
  logic        bank_sel;
  logic        bank_sel_q;
  logic [31:0] dout0, dout1;
  logic [7:0]  par_dout;

  assign bank_sel = mem_addr[AW-1];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)     bank_sel_q <= 1'b0;
    else if (mem_re) bank_sel_q <= bank_sel;
  end

  logic [31:0] dout [2];
  assign dout0 = dout[0];
  assign dout1 = dout[1];

  for (genvar b = 0; b < 2; b++) begin : g_bank
    logic sel;
    assign sel = (bank_sel == b[0]);
    RM_IHPSG13_1P_2048x32_c2_bm_bist u_bank (
        .A_CLK       (clk_i),
        .A_MEN       ((mem_we || mem_re) && sel),
        .A_WEN       (mem_we && sel),
        .A_REN       (mem_re && sel),
        .A_ADDR      (mem_addr[10:0]),
        .A_DIN       (mem_wdata[31:0]),
        .A_DLY       (1'b1),
        .A_DOUT      (dout[b]),
        .A_BM        ({32{1'b1}}),
        .A_BIST_CLK  (1'b0),
        .A_BIST_EN   (1'b0),
        .A_BIST_MEN  (1'b0),
        .A_BIST_WEN  (1'b0),
        .A_BIST_REN  (1'b0),
        .A_BIST_ADDR (11'b0),
        .A_BIST_DIN  (32'b0),
        .A_BIST_BM   (32'b0)
    );
  end

  // Check bits.  4096 deep, so the full word address drives it and both
  // banks share it.
  RM_IHPSG13_1P_4096x8_c3_bm_bist u_par (
      .A_CLK       (clk_i),
      .A_MEN       (mem_we || mem_re),
      .A_WEN       (mem_we),
      .A_REN       (mem_re),
      .A_ADDR      (mem_addr[11:0]),
      .A_DIN       ({1'b0, mem_wdata[38:32]}),
      .A_DLY       (1'b1),
      .A_DOUT      (par_dout),
      .A_BM        ({8{1'b1}}),
      .A_BIST_CLK  (1'b0),
      .A_BIST_EN   (1'b0),
      .A_BIST_MEN  (1'b0),
      .A_BIST_WEN  (1'b0),
      .A_BIST_REN  (1'b0),
      .A_BIST_ADDR (12'b0),
      .A_BIST_DIN  (8'b0),
      .A_BIST_BM   (8'b0)
  );

  assign rd_cw = {par_dout[6:0], (bank_sel_q ? dout1 : dout0)};

  assign bist_rdata_o = rd_cw;

  // ------------------------------------------------------------------
  // Control registers -- identical to rtl/bus/cdriscv_tcm.sv
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

  logic checked;
  assign checked = rvalid_q && (!we_q || (we_q && (be_q != 4'b1111)));

  assign rvalid_o  = rvalid_q;
  assign rdata_o   = dec_data;
  assign ecc_cor_o = checked && dec_cor;
  assign ecc_unc_o = checked && dec_unc;
  assign err_o     = checked && dec_unc;

  logic unused;
  assign unused = |{addr_i[31:AW+2], addr_i[1:0], bist_addr_i[31:AW+2],
                    bist_addr_i[1:0], dec_syndrome, par_dout[7],
                    Depth, InitFile != ""};

endmodule
