// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// Formal properties for cdriscv_if_stage.
//
// The fetch stage is the riskiest block in the design: three concurrent
// state updates -- request accepted, response accepted, redirect --
// share one always block, and the interesting cases are the ones where
// they coincide.  Simulation can only sample that space; bounded model
// checking covers it.
//
// The central property is simple to state and hard to satisfy by
// accident: **the stage delivers exactly the sequential instruction
// stream that starts at the most recent redirect target**.  A stale
// instruction surviving a redirect, a discarded response surfacing, or
// a PC that skips or repeats all violate it.
//
// The RTL is not modified: this wrapper instantiates it and carries the
// properties, together with the bus protocol assumptions the stage is
// entitled to rely on.

`default_nettype none

module if_stage_fv (
    input  logic        clk_i,
    input  logic        fetch_en_i,
    input  logic        redirect_i,
    input  logic [31:0] redirect_pc_i,
    input  logic        instr_ready_i,
    input  logic        instr_gnt_i,
    input  logic        instr_rvalid_i,
    input  logic        instr_err_i
);

  // ------------------------------------------------------------------
  // Abstractions.  Both narrow what is proven, so both are stated.
  //
  // 1. instr_rdata_i is tied off.  No property here reads the
  //    instruction word -- they are all about which address is fetched
  //    and which PC is delivered -- so leaving 32 bits free per step
  //    only costs solver time.
  //
  // 2. redirect targets are confined to the low 1 KiB.  The PC
  //    datapath is uniform in width, so any bug in the *control* --
  //    a stale instruction surviving a redirect, a discarded response
  //    surfacing, two transactions in flight -- still has a
  //    counterexample inside that range.  What this would miss is a
  //    bug that only appears at a particular high address, a carry
  //    chain error for instance.  That class is left to simulation.
  // ------------------------------------------------------------------
  logic [31:0] instr_rdata_i;
  assign instr_rdata_i = 32'h0000_0013;   // nop, arbitrary

  logic        instr_valid, instr_err_out;
  logic [31:0] instr_rdata_out, instr_pc;
  logic        instr_req;
  logic [31:0] instr_addr;

  cdriscv_if_stage u_dut (
      .clk_i          (clk_i),
      .rst_ni         (rst_ni),
      .boot_addr_i    (boot_addr),
      .fetch_en_i     (fetch_en_i),
      .redirect_i     (redirect_i),
      .redirect_pc_i  (redirect_pc_i),
      .instr_valid_o  (instr_valid),
      .instr_rdata_o  (instr_rdata_out),
      .instr_pc_o     (instr_pc),
      .instr_err_o    (instr_err_out),
      .instr_ready_i  (instr_ready_i),
      .instr_req_o    (instr_req),
      .instr_gnt_i    (instr_gnt_i),
      .instr_rvalid_i (instr_rvalid_i),
      .instr_addr_o   (instr_addr),
      .instr_rdata_i  (instr_rdata_i),
      .instr_err_i    (instr_err_i)
  );

  // ------------------------------------------------------------------
  // Environment: the bus protocol the stage is entitled to assume
  // ------------------------------------------------------------------
  // The boot address is a static input; tie it so the reference model
  // and the DUT start from the same place.
  logic [31:0] boot_addr;
  assign boot_addr = 32'h0000_0000;

  // Reset is generated here rather than left free.  Bounded model
  // checking starts from an arbitrary state, so without this the very
  // first step can have reset already released while the registers hold
  // nonsense -- which produces counterexamples about the model, not
  // about the design.  Held low for three cycles, then released.
  logic [1:0] rst_cnt = 2'b00;
  logic       rst_ni;

  always @(posedge clk_i) begin
    if (rst_cnt != 2'b11) rst_cnt <= rst_cnt + 2'd1;
  end

  assign rst_ni = (rst_cnt == 2'b11);

  logic env_outstanding;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      env_outstanding <= 1'b0;
    end else if (instr_req && instr_gnt_i) begin
      env_outstanding <= 1'b1;
    end else if (instr_rvalid_i) begin
      env_outstanding <= 1'b0;
    end
  end

  // ------------------------------------------------------------------
  // Reference stream: the PC of the next instruction that the stage
  // owes the execute stage.  It starts at the boot address, restarts at
  // every redirect target, and advances by four each time an
  // instruction is consumed.  That is the whole contract of the block.
  // ------------------------------------------------------------------
  logic [31:0] exp_pc;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      exp_pc <= boot_addr;
    end else if (redirect_i) begin
      exp_pc <= redirect_pc_i;
    end else if (instr_valid && instr_ready_i) begin
      exp_pc <= instr_pc + 32'd4;
    end
  end

  // Properties are written as immediate assertions inside clocked
  // blocks, which is the form yosys' formal flow accepts; the
  // concurrent `assert property (@(posedge clk) ...)` syntax is not
  // supported by its Verilog front end.

  always @(posedge clk_i) begin
    if (rst_ni) begin
      // ---- environment: the bus protocol the stage may rely on ----

      // grant only in answer to a request
      a_gnt_needs_req: assume (!instr_gnt_i || instr_req);

      // a response only for an accepted request
      a_rvalid_needs_outstanding: assume (!instr_rvalid_i || env_outstanding);

      // the response phase never coincides with the address phase --
      // the OBI rule the stage's header documents and relies on
      a_no_gnt_with_rvalid: assume (!(instr_gnt_i && instr_rvalid_i));

      // redirect targets are word aligned, as the execute stage
      // guarantees for IALIGN=32
      a_redirect_aligned: assume (redirect_pc_i[1:0] == 2'b00);

      // The execute stage only redirects in a cycle where it holds a
      // valid instruction: every redirect in cdriscv_core comes from a
      // trap or a retire, and both require instr_valid.  Without this
      // the block is checked against an input space wider than its
      // actual use -- which is worth doing too, and is what showed the
      // redirect path's remaining branches are reachable in general.
      a_redirect_needs_valid: assume (!redirect_i || instr_valid);

      // ...and confined to the low 1 KiB, see the abstraction note
      a_redirect_range: assume (redirect_pc_i[31:10] == 22'b0);

      // ---- the properties ----

      // The one that matters: every instruction handed to the execute
      // stage is the next one of the stream that began at the last
      // redirect.  A stale instruction surviving a redirect, a
      // discarded response surfacing, or a PC that skips or repeats
      // all violate this.
      p_pc_stream: assert (!instr_valid || (instr_pc == exp_pc));

      // Never two transactions in flight.  A request may be issued in
      // the same cycle as the response to the previous one -- that is
      // the OBI pipelining the fetch stage relies on since V2-P1 -- so
      // the exclusion is against an outstanding transaction that is
      // *not* completing this cycle.
      p_single_outstanding: assert (!instr_req || !env_outstanding ||
                                    instr_rvalid_i);

      // Fetch addresses are word aligned.
      p_addr_aligned: assert (instr_addr[1:0] == 2'b00);

      // Fetching stops when it is disabled.
      p_fetch_en: assert (fetch_en_i || !instr_req);

      // p_no_outstanding_at_redirect used to live here: with a
      // one-deep buffer no fetch could be in flight at a redirect, and
      // that made three lines of the redirect path unreachable
      // (waiver W1).  The assertion was written down precisely so that
      // deepening the prefetch would break it rather than silently
      // invalidating the waiver.
      //
      // V2-P1 deepened the prefetch, the assertion did its job, and the
      // property is now false by design: the fetcher runs ahead, so a
      // redirect routinely finds a transaction in flight.  Removed
      // here, and W1 withdrawn in verif/coverage_waivers.md.

      // A redirect empties the buffer: nothing can be presented in the
      // cycle after one, because the new stream has not arrived yet.
      if ($past(rst_ni) && $past(redirect_i)) begin
        p_redirect_flushes: assert (!instr_valid);
      end
    end
  end

endmodule
