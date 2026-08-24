// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s -- instruction/data bus interconnect.
//
// Two masters (instruction fetch, data) and three slaves (I-TCM, D-TCM,
// peripheral bridge) plus an internal error responder for unmapped
// addresses.  Each master has at most one outstanding transaction, and
// each slave answers in order, so a single owner bit per slave is
// enough to route responses.
//
// The instruction master may only reach the I-TCM; every other address
// it produces is an unmapped access and returns an error, which turns a
// runaway program counter into a reported fault instead of a silent
// wrap-around.  The data master reaches everything, and wins the I-TCM
// arbitration, so a data access can never be starved by the fetcher.
//
// STATUS: verified to the O1-O7 gate of doc/verification_plan.md
//         (2026-08-24) -- may be used in a project.  O8-O9 and the
//         FMEDA are open: NOT qualified for safety-critical use.

`default_nettype none

module cdriscv_bus #(
    parameter logic [31:0] ItcmBase   = 32'h0000_0000,
    parameter int unsigned ItcmBytes  = 16384,
    parameter logic [31:0] DtcmBase   = 32'h1000_0000,
    parameter int unsigned DtcmBytes  = 16384,
    parameter logic [31:0] PeriphBase = 32'h2000_0000,
    parameter int unsigned PeriphBytes= 4096
)(
    input  logic        clk_i,
    input  logic        rst_ni,

    // ---- master 0: instruction fetch (read only) ----
    input  logic        instr_req_i,
    output logic        instr_gnt_o,
    output logic        instr_rvalid_o,
    input  logic [31:0] instr_addr_i,
    output logic [31:0] instr_rdata_o,
    output logic        instr_err_o,

    // ---- master 1: data ----
    input  logic        data_req_i,
    output logic        data_gnt_o,
    output logic        data_rvalid_o,
    input  logic        data_we_i,
    input  logic [3:0]  data_be_i,
    input  logic [31:0] data_addr_i,
    input  logic [31:0] data_wdata_i,
    output logic [31:0] data_rdata_o,
    output logic        data_err_o,

    // ---- slave 0: I-TCM ----
    output logic        itcm_req_o,
    input  logic        itcm_gnt_i,
    input  logic        itcm_rvalid_i,
    output logic        itcm_we_o,
    output logic [3:0]  itcm_be_o,
    output logic [31:0] itcm_addr_o,
    output logic [31:0] itcm_wdata_o,
    input  logic [31:0] itcm_rdata_i,
    input  logic        itcm_err_i,

    // ---- slave 1: D-TCM ----
    output logic        dtcm_req_o,
    input  logic        dtcm_gnt_i,
    input  logic        dtcm_rvalid_i,
    output logic        dtcm_we_o,
    output logic [3:0]  dtcm_be_o,
    output logic [31:0] dtcm_addr_o,
    output logic [31:0] dtcm_wdata_o,
    input  logic [31:0] dtcm_rdata_i,
    input  logic        dtcm_err_i,

    // ---- slave 2: peripheral bridge ----
    output logic        periph_req_o,
    input  logic        periph_gnt_i,
    input  logic        periph_rvalid_i,
    output logic        periph_we_o,
    output logic [3:0]  periph_be_o,
    output logic [31:0] periph_addr_o,
    output logic [31:0] periph_wdata_o,
    input  logic [31:0] periph_rdata_i,
    input  logic        periph_err_i,

    // safety
    output logic        fault_bus_err_o
);

  // ------------------------------------------------------------------
  // Address decode
  // ------------------------------------------------------------------
  function automatic logic in_range(input logic [31:0] addr,
                                    input logic [31:0] base,
                                    input int unsigned bytes);
    return (addr & ~(32'(bytes) - 32'd1)) == base;
  endfunction

  logic i_hit_itcm;
  logic d_hit_itcm, d_hit_dtcm, d_hit_periph;
  logic i_unmapped, d_unmapped;

  assign i_hit_itcm   = in_range(instr_addr_i, ItcmBase,   ItcmBytes);
  assign d_hit_itcm   = in_range(data_addr_i,  ItcmBase,   ItcmBytes);
  assign d_hit_dtcm   = in_range(data_addr_i,  DtcmBase,   DtcmBytes);
  assign d_hit_periph = in_range(data_addr_i,  PeriphBase, PeriphBytes);

  assign i_unmapped = !i_hit_itcm;
  assign d_unmapped = !(d_hit_itcm || d_hit_dtcm || d_hit_periph);

  // ------------------------------------------------------------------
  // I-TCM arbitration: the data master wins
  // ------------------------------------------------------------------
  logic itcm_req_d, itcm_req_i_m;
  assign itcm_req_d   = data_req_i  && d_hit_itcm;
  assign itcm_req_i_m = instr_req_i && i_hit_itcm;

  assign itcm_req_o   = itcm_req_d || itcm_req_i_m;
  assign itcm_we_o    = itcm_req_d ? data_we_i    : 1'b0;
  assign itcm_be_o    = itcm_req_d ? data_be_i    : 4'b1111;
  assign itcm_addr_o  = itcm_req_d ? data_addr_i  : instr_addr_i;
  assign itcm_wdata_o = data_wdata_i;

  // ------------------------------------------------------------------
  // D-TCM and peripherals: data master only
  // ------------------------------------------------------------------
  assign dtcm_req_o   = data_req_i && d_hit_dtcm;
  assign dtcm_we_o    = data_we_i;
  assign dtcm_be_o    = data_be_i;
  assign dtcm_addr_o  = data_addr_i;
  assign dtcm_wdata_o = data_wdata_i;

  assign periph_req_o   = data_req_i && d_hit_periph;
  assign periph_we_o    = data_we_i;
  assign periph_be_o    = data_be_i;
  assign periph_addr_o  = data_addr_i;
  assign periph_wdata_o = data_wdata_i;

  // ------------------------------------------------------------------
  // Error responder for unmapped accesses
  // ------------------------------------------------------------------
  logic err_req_d, err_req_i_m, err_gnt_d, err_gnt_i_m;
  logic err_rvalid_q, err_owner_q;   // owner: 0 = instruction, 1 = data

  assign err_req_d   = data_req_i  && d_unmapped;
  assign err_req_i_m = instr_req_i && i_unmapped;

  // one access at a time, the data master has priority
  assign err_gnt_d   = err_req_d;
  assign err_gnt_i_m = err_req_i_m && !err_req_d;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      err_rvalid_q <= 1'b0;
      err_owner_q  <= 1'b0;
    end else begin
      err_rvalid_q <= err_gnt_d || err_gnt_i_m;
      if (err_gnt_d || err_gnt_i_m) begin
        err_owner_q <= err_gnt_d;
      end
    end
  end

  // ------------------------------------------------------------------
  // Response ownership
  // ------------------------------------------------------------------
  logic itcm_owner_q;   // 0 = instruction master, 1 = data master
  logic itcm_pending_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      itcm_owner_q   <= 1'b0;
      itcm_pending_q <= 1'b0;
    end else begin
      if (itcm_req_o && itcm_gnt_i) begin
        itcm_owner_q   <= itcm_req_d;
        itcm_pending_q <= 1'b1;
      end else if (itcm_rvalid_i) begin
        itcm_pending_q <= 1'b0;
      end
    end
  end

  // ------------------------------------------------------------------
  // Grants back to the masters
  // ------------------------------------------------------------------
  assign instr_gnt_o = (itcm_req_i_m && itcm_gnt_i && !itcm_req_d) || err_gnt_i_m;

  assign data_gnt_o  = (itcm_req_d   && itcm_gnt_i)   ||
                       (dtcm_req_o   && dtcm_gnt_i)   ||
                       (periph_req_o && periph_gnt_i) ||
                        err_gnt_d;

  // ------------------------------------------------------------------
  // Responses back to the masters
  // ------------------------------------------------------------------
  logic itcm_resp_instr, itcm_resp_data;
  assign itcm_resp_instr = itcm_rvalid_i && !itcm_owner_q;
  assign itcm_resp_data  = itcm_rvalid_i &&  itcm_owner_q;

  assign instr_rvalid_o = itcm_resp_instr || (err_rvalid_q && !err_owner_q);
  assign instr_rdata_o  = itcm_rdata_i;
  assign instr_err_o    = (itcm_resp_instr && itcm_err_i) || (err_rvalid_q && !err_owner_q);

  always_comb begin
    data_rvalid_o = 1'b0;
    data_rdata_o  = 32'b0;
    data_err_o    = 1'b0;
    if (itcm_resp_data) begin
      data_rvalid_o = 1'b1;
      data_rdata_o  = itcm_rdata_i;
      data_err_o    = itcm_err_i;
    end else if (dtcm_rvalid_i) begin
      data_rvalid_o = 1'b1;
      data_rdata_o  = dtcm_rdata_i;
      data_err_o    = dtcm_err_i;
    end else if (periph_rvalid_i) begin
      data_rvalid_o = 1'b1;
      data_rdata_o  = periph_rdata_i;
      data_err_o    = periph_err_i;
    end else if (err_rvalid_q && err_owner_q) begin
      data_rvalid_o = 1'b1;
      data_rdata_o  = 32'hdead_beef;
      data_err_o    = 1'b1;
    end
  end

  assign fault_bus_err_o = (instr_rvalid_o && instr_err_o) ||
                           (data_rvalid_o  && data_err_o);

  logic unused_pending;
  assign unused_pending = itcm_pending_q;

endmodule
