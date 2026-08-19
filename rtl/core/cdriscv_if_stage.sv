// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s -- instruction fetch stage.
//
// Sequential prefetcher with a single outstanding bus transaction and a
// one-entry instruction buffer.  A redirect (branch, jump, trap, MRET,
// FENCE.I) empties the buffer and marks an in-flight response to be
// dropped, so no stale instruction can ever reach the execute stage.
//
// Bus rule: instr_rvalid_i must not be asserted in the same cycle as
// instr_gnt_i (standard OBI response phase, one cycle or more after the
// address phase).
//
// STATUS: NOT VERIFIED YET -- DO NOT USE YET.

`default_nettype none

module cdriscv_if_stage (
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic [31:0] boot_addr_i,
    input  logic        fetch_en_i,     // gate new fetches (sleep / halt)

    // redirect from the execute stage
    input  logic        redirect_i,
    input  logic [31:0] redirect_pc_i,

    // instruction handed to the execute stage
    output logic        instr_valid_o,
    output logic [31:0] instr_rdata_o,
    output logic [31:0] instr_pc_o,
    output logic        instr_err_o,    // fetch bus error
    input  logic        instr_ready_i,

    // instruction memory interface
    output logic        instr_req_o,
    input  logic        instr_gnt_i,
    input  logic        instr_rvalid_i,
    output logic [31:0] instr_addr_o,
    input  logic [31:0] instr_rdata_i,
    input  logic        instr_err_i
);

  logic [31:0] fetch_pc_q;
  logic [31:0] pending_pc_q;
  logic        outstanding_q;
  logic        discard_q;

  logic        valid_q;
  logic [31:0] rdata_q;
  logic [31:0] pc_q;
  logic        err_q;

  // The buffer is (or becomes) free this cycle.
  logic buf_free;
  assign buf_free = !valid_q || instr_ready_i;

  assign instr_req_o  = fetch_en_i && !outstanding_q && buf_free;
  assign instr_addr_o = {fetch_pc_q[31:2], 2'b00};

  logic req_accepted, resp_accepted;
  assign req_accepted  = instr_req_o && instr_gnt_i;
  assign resp_accepted = outstanding_q && instr_rvalid_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fetch_pc_q    <= boot_addr_i;
      pending_pc_q  <= '0;
      outstanding_q <= 1'b0;
      discard_q     <= 1'b0;
      valid_q       <= 1'b0;
      rdata_q       <= '0;
      pc_q          <= '0;
      err_q         <= 1'b0;
    end else if (redirect_i) begin
      // Drop the buffer and everything still in flight.
      fetch_pc_q <= redirect_pc_i;
      valid_q    <= 1'b0;
      if (req_accepted) begin
        // The address phase completed this cycle with the stale PC.
        pending_pc_q  <= fetch_pc_q;
        outstanding_q <= 1'b1;
        discard_q     <= 1'b1;
      end else if (resp_accepted) begin
        outstanding_q <= 1'b0;
        discard_q     <= 1'b0;
      end else if (outstanding_q) begin
        discard_q     <= 1'b1;
      end
    end else begin
      if (req_accepted) begin
        pending_pc_q  <= fetch_pc_q;
        fetch_pc_q    <= fetch_pc_q + 32'd4;
        outstanding_q <= 1'b1;
      end

      // consumption of the buffered instruction
      if (valid_q && instr_ready_i) begin
        valid_q <= 1'b0;
      end

      // response: fill the buffer, or swallow a discarded response
      if (resp_accepted) begin
        outstanding_q <= 1'b0;
        discard_q     <= 1'b0;
        if (!discard_q) begin
          valid_q <= 1'b1;
          rdata_q <= instr_rdata_i;
          pc_q    <= pending_pc_q;
          err_q   <= instr_err_i;
        end
      end
    end
  end

  assign instr_valid_o = valid_q;
  assign instr_rdata_o = rdata_q;
  assign instr_pc_o    = pc_q;
  assign instr_err_o   = err_q;

endmodule
