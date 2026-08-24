// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s -- instruction fetch stage.
//
// Sequential prefetcher with a two-entry instruction buffer and a
// single outstanding bus transaction.  A redirect (branch, jump, trap,
// MRET, FENCE.I) empties the buffer and marks an in-flight response to
// be dropped, so no stale instruction can ever reach the execute stage.
//
// Why two entries and a same-cycle re-request (finding V2-P1).  The
// first version buffered one instruction and only issued the next fetch
// when that buffer was being emptied.  With a one cycle memory that
// costs a bubble on every instruction -- request at T, data at T+1,
// execute at T+2 -- so CPI could not go below 2 whatever the program
// did.  Two things fix it:
//
//   * a request may be issued in the same cycle as the response to the
//     previous one arrives, which is the ordinary OBI pipelining of an
//     address phase against a response phase.  There is still never
//     more than one transaction in flight, which is what the bus's
//     one-owner-bit-per-slave routing requires.
//   * the buffer holds two instructions, so a response always has
//     somewhere to land.  With one entry the fetcher could not issue
//     ahead safely: if the execute stage stalled on a multi-cycle
//     instruction, the arriving word would overwrite the one waiting.
//
// Bus rule: instr_rvalid_i must not be asserted in the same cycle as
// instr_gnt_i *for the same transaction* (standard OBI response phase,
// one cycle or more after its address phase).  A grant for the next
// transaction in the same cycle as a response for the previous one is
// allowed and is what makes back-to-back fetching work.
//
// STATUS: verified to the O1-O7 gate of doc/verification_plan.md
//         (2026-08-24) -- may be used in a project.  O8-O9 and the
//         FMEDA are open: NOT qualified for safety-critical use.

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

  // ------------------------------------------------------------------
  // Two-entry instruction buffer
  // ------------------------------------------------------------------
  logic [31:0] buf_rdata_q [2];
  logic [31:0] buf_pc_q    [2];
  logic        buf_err_q   [2];
  logic        wr_ptr_q, rd_ptr_q;
  logic [1:0]  count_q;

  logic [31:0] fetch_pc_q, pending_pc_q;
  logic        outstanding_q, discard_q;

  // ------------------------------------------------------------------
  // Flow control
  // ------------------------------------------------------------------
  logic resp_now, fill, consume;
  logic [1:0] occupancy, occupancy_next;

  // the outstanding transaction is completing this cycle
  assign resp_now = outstanding_q && instr_rvalid_i;

  // ...and its data belongs to the current instruction stream
  assign fill = resp_now && !discard_q;

  assign consume = instr_valid_o && instr_ready_i;

  // instructions accounted for: buffered plus in flight
  assign occupancy = count_q + {1'b0, outstanding_q};

  // what that becomes after this cycle's departures, before any new
  // request is counted
  assign occupancy_next = occupancy
                        - (consume ? 2'd1 : 2'd0)
                        - ((resp_now && discard_q) ? 2'd1 : 2'd0);

  // A request needs a free slot, and either no transaction in flight or
  // one that is completing right now.
  assign instr_req_o  = fetch_en_i && (!outstanding_q || resp_now)
                        && (occupancy_next <= 2'd1);
  assign instr_addr_o = {fetch_pc_q[31:2], 2'b00};

  logic req_accepted;
  assign req_accepted = instr_req_o && instr_gnt_i;

  // ------------------------------------------------------------------
  // State
  // ------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fetch_pc_q    <= boot_addr_i;
      pending_pc_q  <= '0;
      outstanding_q <= 1'b0;
      discard_q     <= 1'b0;
      wr_ptr_q      <= 1'b0;
      rd_ptr_q      <= 1'b0;
      count_q       <= 2'd0;
      for (int unsigned i = 0; i < 2; i++) begin
        buf_rdata_q[i] <= '0;
        buf_pc_q[i]    <= '0;
        buf_err_q[i]   <= 1'b0;
      end
    end else if (redirect_i) begin
      // Drop the buffer and everything still in flight.
      fetch_pc_q <= redirect_pc_i;
      count_q    <= 2'd0;
      wr_ptr_q   <= 1'b0;
      rd_ptr_q   <= 1'b0;

      if (req_accepted) begin
        // The address phase completed this cycle with the stale PC.
        pending_pc_q  <= fetch_pc_q;
        outstanding_q <= 1'b1;
        discard_q     <= 1'b1;
      end else if (resp_now) begin
        // The in-flight fetch completed in this very cycle; swallow it.
        outstanding_q <= 1'b0;
        discard_q     <= 1'b0;
      end else if (outstanding_q) begin
        discard_q     <= 1'b1;
      end
    end else begin
      // A grant for the next fetch and a response for the previous one
      // can land in the same cycle; the order of these two blocks makes
      // the grant win the outstanding flag, which is correct because
      // the new transaction is the one still in flight afterwards.
      if (resp_now) begin
        discard_q <= 1'b0;
        if (!req_accepted) outstanding_q <= 1'b0;

        if (!discard_q) begin
          buf_rdata_q[wr_ptr_q] <= instr_rdata_i;
          buf_pc_q[wr_ptr_q]    <= pending_pc_q;
          buf_err_q[wr_ptr_q]   <= instr_err_i;
          wr_ptr_q              <= ~wr_ptr_q;
        end
      end

      if (req_accepted) begin
        pending_pc_q  <= fetch_pc_q;
        fetch_pc_q    <= fetch_pc_q + 32'd4;
        outstanding_q <= 1'b1;
      end

      if (consume) rd_ptr_q <= ~rd_ptr_q;

      count_q <= count_q + (fill ? 2'd1 : 2'd0) - (consume ? 2'd1 : 2'd0);
    end
  end

  assign instr_valid_o = (count_q != 2'd0);
  assign instr_rdata_o = buf_rdata_q[rd_ptr_q];
  assign instr_pc_o    = buf_pc_q[rd_ptr_q];
  assign instr_err_o   = buf_err_q[rd_ptr_q];

endmodule
