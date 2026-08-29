// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-10 -- OBI-like slave to APB3 master bridge.
//
// The peripheral window is 4 KiB, split into sixteen 256-byte slots
// selected by paddr[11:8].  Slot 15 is exported so that the SoC can
// attach its own registers (analog trim, mixed-signal control, ...)
// without touching this IP.
//
// Peripherals are word registers only: byte enables are passed through
// on PSTRB but a peripheral is free to ignore them.
//
// STATUS: verified to the O1-O7 gate of doc/verification_plan.md
//         (2026-08-24) -- may be used in a project.  O8-O9 and the
//         FMEDA are open: NOT qualified for safety-critical use.

`default_nettype none

module cdriscv_apb_bridge #(
    parameter int unsigned NumSlaves = 16
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

    // APB3 master
    output logic [NumSlaves-1:0] psel_o,
    output logic                 penable_o,
    output logic [11:0]          paddr_o,
    output logic                 pwrite_o,
    output logic [31:0]          pwdata_o,
    output logic [3:0]           pstrb_o,
    input  logic [31:0]          prdata_i,
    input  logic                 pready_i,
    input  logic                 pslverr_i
);

  typedef enum logic [1:0] {
    APB_IDLE,
    APB_SETUP,
    APB_ACCESS,
    APB_RESP
  } state_e;

  state_e      state_q, state_d;
  logic [11:0] addr_q;
  logic        we_q;
  logic [31:0] wdata_q;
  logic [3:0]  be_q;
  logic [31:0] rdata_q;
  logic        err_q;

  assign gnt_o = req_i && (state_q == APB_IDLE);

  always_comb begin
    state_d = state_q;
    unique case (state_q)
      APB_IDLE:   if (req_i)    state_d = APB_SETUP;
      APB_SETUP:                state_d = APB_ACCESS;
      APB_ACCESS: if (pready_i) state_d = APB_RESP;
      APB_RESP:                 state_d = APB_IDLE;
      default:                  state_d = APB_IDLE;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= APB_IDLE;
      addr_q  <= 12'b0;
      we_q    <= 1'b0;
      wdata_q <= 32'b0;
      be_q    <= 4'b0;
      rdata_q <= 32'b0;
      err_q   <= 1'b0;
    end else begin
      state_q <= state_d;
      if ((state_q == APB_IDLE) && req_i) begin
        addr_q  <= addr_i[11:0];
        we_q    <= we_i;
        wdata_q <= wdata_i;
        be_q    <= be_i;
      end
      if ((state_q == APB_ACCESS) && pready_i) begin
        rdata_q <= prdata_i;
        err_q   <= pslverr_i;
      end
    end
  end

  // APB signalling
  always_comb begin
    psel_o = '0;
    if ((state_q == APB_SETUP) || (state_q == APB_ACCESS)) begin
      psel_o[addr_q[11:8]] = 1'b1;
    end
  end

  assign penable_o = (state_q == APB_ACCESS);
  assign paddr_o   = {addr_q[11:2], 2'b00};
  assign pwrite_o  = we_q;
  assign pwdata_o  = wdata_q;
  assign pstrb_o   = be_q;

  assign rvalid_o = (state_q == APB_RESP);
  assign rdata_o  = rdata_q;
  assign err_o    = err_q;

endmodule
