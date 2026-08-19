// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s -- load/store unit.
//
// One outstanding transaction on a req/gnt/rvalid bus (OBI-like).
// Misaligned accesses are not split: the core raises an address
// misaligned exception instead, which keeps every data access single
// beat and therefore bounded in time.
//
// STATUS: NOT VERIFIED YET -- DO NOT USE YET.

`default_nettype none

module cdriscv_lsu
  import cdriscv_pkg::*;
(
    input  logic        clk_i,
    input  logic        rst_ni,

    // request from the core
    input  logic        req_i,
    input  logic        we_i,
    input  logic [1:0]  size_i,
    input  logic        sign_ext_i,
    input  logic [31:0] addr_i,
    input  logic [31:0] wdata_i,
    input  logic        kill_i,

    output logic        busy_o,
    output logic        valid_o,       // one-cycle pulse: access finished
    output logic [31:0] rdata_o,
    output logic        err_o,         // bus error on the finished access

    // data memory interface
    output logic        data_req_o,
    input  logic        data_gnt_i,
    input  logic        data_rvalid_i,
    output logic        data_we_o,
    output logic [3:0]  data_be_o,
    output logic [31:0] data_addr_o,
    output logic [31:0] data_wdata_o,
    input  logic [31:0] data_rdata_i,
    input  logic        data_err_i
);

  typedef enum logic [1:0] {
    LSU_IDLE,
    LSU_ADDR,      // request issued, waiting for grant
    LSU_DATA       // granted, waiting for the response
  } state_e;

  state_e      state_q, state_d;
  logic [1:0]  size_q;
  logic        sign_ext_q;
  logic [1:0]  addr_lsb_q;

  // ------------------------------------------------------------------
  // Byte enables and write data alignment
  // ------------------------------------------------------------------
  logic [3:0]  be;
  logic [31:0] wdata_aligned;

  always_comb begin
    unique case (size_i)
      LS_BYTE: be = 4'b0001 << addr_i[1:0];
      LS_HALF: be = 4'b0011 << addr_i[1:0];
      LS_WORD: be = 4'b1111;
      default: be = 4'b0000;
    endcase
  end

  always_comb begin
    unique case (addr_i[1:0])
      2'b00:   wdata_aligned = wdata_i;
      2'b01:   wdata_aligned = {wdata_i[23:0], 8'b0};
      2'b10:   wdata_aligned = {wdata_i[15:0], 16'b0};
      2'b11:   wdata_aligned = {wdata_i[7:0],  24'b0};
      default: wdata_aligned = wdata_i;
    endcase
  end

  // The address phase is driven directly from the core request, which
  // is held stable by the core until the access completes.
  assign data_req_o   = (state_q == LSU_IDLE) ? req_i : (state_q == LSU_ADDR);
  assign data_we_o    = we_i;
  assign data_be_o    = be;
  assign data_addr_o  = {addr_i[31:2], 2'b00};
  assign data_wdata_o = wdata_aligned;

  // ------------------------------------------------------------------
  // Control
  // ------------------------------------------------------------------
  always_comb begin
    state_d = state_q;
    unique case (state_q)
      LSU_IDLE: if (req_i)       state_d = data_gnt_i ? LSU_DATA : LSU_ADDR;
      LSU_ADDR: if (data_gnt_i)  state_d = LSU_DATA;
      LSU_DATA: if (data_rvalid_i) state_d = LSU_IDLE;
      default:                   state_d = LSU_IDLE;
    endcase
    if (kill_i && (state_q != LSU_DATA)) state_d = LSU_IDLE;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q    <= LSU_IDLE;
      size_q     <= LS_WORD;
      sign_ext_q <= 1'b0;
      addr_lsb_q <= 2'b00;
    end else begin
      state_q <= state_d;
      if ((state_q == LSU_IDLE) && req_i) begin
        size_q     <= size_i;
        sign_ext_q <= sign_ext_i;
        addr_lsb_q <= addr_i[1:0];
      end
    end
  end

  assign busy_o  = (state_q != LSU_IDLE);
  assign valid_o = (state_q == LSU_DATA) && data_rvalid_i;
  assign err_o   = data_err_i;

  // ------------------------------------------------------------------
  // Read data extraction
  // ------------------------------------------------------------------
  logic [31:0] rdata_shifted;
  logic [7:0]  rdata_b;
  logic [15:0] rdata_h;

  always_comb begin
    unique case (addr_lsb_q)
      2'b00:   rdata_shifted = data_rdata_i;
      2'b01:   rdata_shifted = {8'b0,  data_rdata_i[31:8]};
      2'b10:   rdata_shifted = {16'b0, data_rdata_i[31:16]};
      2'b11:   rdata_shifted = {24'b0, data_rdata_i[31:24]};
      default: rdata_shifted = data_rdata_i;
    endcase
  end

  assign rdata_b = rdata_shifted[7:0];
  assign rdata_h = rdata_shifted[15:0];

  always_comb begin
    unique case (size_q)
      LS_BYTE: rdata_o = {{24{sign_ext_q & rdata_b[7]}},  rdata_b};
      LS_HALF: rdata_o = {{16{sign_ext_q & rdata_h[15]}}, rdata_h};
      default: rdata_o = rdata_shifted;
    endcase
  end

endmodule
