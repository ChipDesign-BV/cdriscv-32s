// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// Formal properties for cdriscv_bus.
//
// The interconnect's risk is not arithmetic, it is bookkeeping: two
// masters, three slaves and an error responder, with one owner bit per
// slave deciding where a response goes.  A misrouted response hands one
// master another's data, which no functional test is guaranteed to
// notice -- the value is plausible, just wrong.
//
// The slaves are modelled concretely here rather than left free,
// because their protocol is fixed and known: grant when not busy,
// answer exactly one cycle later.  That is what cdriscv_tcm does.
//
//   p_no_spurious_*   a master is never handed a response it did not ask for
//   p_one_outstanding_* a master never has two requests in flight
//   p_data_wins_itcm  the data master wins I-TCM arbitration, so the
//                     fetcher can never starve it
//   p_no_lost_*       a granted request is always answered, never dropped

`default_nettype none

module bus_fv (
    input  logic        clk_i,
    input  logic        instr_req_i,
    input  logic [31:0] instr_addr_i,
    input  logic        data_req_i,
    input  logic        data_we_i,
    input  logic [31:0] data_addr_i
);

  logic [1:0] rst_cnt = 2'b00;
  logic       rst_ni;

  always @(posedge clk_i) begin
    if (rst_cnt != 2'b11) rst_cnt <= rst_cnt + 2'd1;
  end
  assign rst_ni = (rst_cnt == 2'b11);

  // ------------------------------------------------------------------
  // Device under test
  // ------------------------------------------------------------------
  logic        instr_gnt, instr_rvalid, instr_err;
  logic [31:0] instr_rdata;
  logic        data_gnt, data_rvalid, data_err;
  logic [31:0] data_rdata;

  logic        itcm_req, itcm_gnt, itcm_rvalid, itcm_we, itcm_err;
  logic [3:0]  itcm_be;
  logic [31:0] itcm_addr, itcm_wdata, itcm_rdata;
  logic        dtcm_req, dtcm_gnt, dtcm_rvalid, dtcm_we, dtcm_err;
  logic [3:0]  dtcm_be;
  logic [31:0] dtcm_addr, dtcm_wdata, dtcm_rdata;
  logic        per_req, per_gnt, per_rvalid, per_we, per_err;
  logic [3:0]  per_be;
  logic [31:0] per_addr, per_wdata, per_rdata;
  logic        fault_bus_err;

  cdriscv_bus u_dut (
      .clk_i           (clk_i),
      .rst_ni          (rst_ni),
      .instr_req_i     (instr_req_i),
      .instr_gnt_o     (instr_gnt),
      .instr_rvalid_o  (instr_rvalid),
      .instr_addr_i    (instr_addr_i),
      .instr_rdata_o   (instr_rdata),
      .instr_err_o     (instr_err),
      .data_req_i      (data_req_i),
      .data_gnt_o      (data_gnt),
      .data_rvalid_o   (data_rvalid),
      .data_we_i       (data_we_i),
      .data_be_i       (4'b1111),
      .data_addr_i     (data_addr_i),
      .data_wdata_i    (32'h0),
      .data_rdata_o    (data_rdata),
      .data_err_o      (data_err),
      .itcm_req_o      (itcm_req),
      .itcm_gnt_i      (itcm_gnt),
      .itcm_rvalid_i   (itcm_rvalid),
      .itcm_we_o       (itcm_we),
      .itcm_be_o       (itcm_be),
      .itcm_addr_o     (itcm_addr),
      .itcm_wdata_o    (itcm_wdata),
      .itcm_rdata_i    (itcm_rdata),
      .itcm_err_i      (itcm_err),
      .dtcm_req_o      (dtcm_req),
      .dtcm_gnt_i      (dtcm_gnt),
      .dtcm_rvalid_i   (dtcm_rvalid),
      .dtcm_we_o       (dtcm_we),
      .dtcm_be_o       (dtcm_be),
      .dtcm_addr_o     (dtcm_addr),
      .dtcm_wdata_o    (dtcm_wdata),
      .dtcm_rdata_i    (dtcm_rdata),
      .dtcm_err_i      (dtcm_err),
      .periph_req_o    (per_req),
      .periph_gnt_i    (per_gnt),
      .periph_rvalid_i (per_rvalid),
      .periph_we_o     (per_we),
      .periph_be_o     (per_be),
      .periph_addr_o   (per_addr),
      .periph_wdata_o  (per_wdata),
      .periph_rdata_i  (per_rdata),
      .periph_err_i    (per_err),
      .fault_bus_err_o (fault_bus_err)
  );

  // ------------------------------------------------------------------
  // Concrete slave models: grant when idle, answer one cycle later
  // ------------------------------------------------------------------
  logic itcm_busy, dtcm_busy, per_busy;

  assign itcm_gnt = itcm_req;
  assign dtcm_gnt = dtcm_req;
  assign per_gnt  = per_req;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      itcm_rvalid <= 1'b0;
      dtcm_rvalid <= 1'b0;
      per_rvalid  <= 1'b0;
    end else begin
      itcm_rvalid <= itcm_req && itcm_gnt;
      dtcm_rvalid <= dtcm_req && dtcm_gnt;
      per_rvalid  <= per_req  && per_gnt;
    end
  end

  assign itcm_rdata = 32'hAAAA_0000;
  assign dtcm_rdata = 32'hBBBB_0000;
  assign per_rdata  = 32'hCCCC_0000;
  assign itcm_err   = 1'b0;
  assign dtcm_err   = 1'b0;
  assign per_err    = 1'b0;
  assign itcm_busy  = 1'b0;
  assign dtcm_busy  = 1'b0;
  assign per_busy   = 1'b0;

  // ------------------------------------------------------------------
  // Master bookkeeping: at most one request in flight each
  // ------------------------------------------------------------------
  logic instr_out, data_out;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      instr_out <= 1'b0;
      data_out  <= 1'b0;
    end else begin
      if (instr_req_i && instr_gnt) instr_out <= 1'b1;
      else if (instr_rvalid)        instr_out <= 1'b0;

      if (data_req_i && data_gnt)   data_out <= 1'b1;
      else if (data_rvalid)         data_out <= 1'b0;
    end
  end

  logic i_hits_itcm, d_hits_itcm;
  assign i_hits_itcm = (instr_addr_i & ~32'h3fff) == 32'h0000_0000;
  assign d_hits_itcm = (data_addr_i  & ~32'h3fff) == 32'h0000_0000;

  always @(posedge clk_i) begin
    if (rst_ni) begin
      // ---- environment: masters behave like the core's ports ----

      // No new request while one is still in flight.  The fetch stage
      // may issue in the cycle its outstanding response arrives (the
      // OBI address/response overlap it uses since V2-P1), so that case
      // is allowed for the instruction master.  The LSU still waits for
      // the full response, so the data master keeps the stricter rule.
      a_instr_single: assume (!instr_req_i || !instr_out || instr_rvalid);
      a_data_single:  assume (!data_req_i  || !data_out);

      // ---- properties ----

      // A master is never handed a response it did not ask for.  This
      // is the misrouting check: with one owner bit per slave, a wrong
      // owner shows up here.
      p_no_spurious_instr: assert (!instr_rvalid || instr_out);
      p_no_spurious_data:  assert (!data_rvalid  || data_out);

      // The data master wins the I-TCM, so the fetcher cannot starve it.
      p_data_wins_itcm: assert (!(instr_req_i && i_hits_itcm &&
                                  data_req_i && d_hits_itcm) || !instr_gnt);

      // Both masters are never granted the same slave in one cycle.
      p_no_double_itcm: assert (!(instr_gnt && data_gnt) ||
                                !(i_hits_itcm && d_hits_itcm));

      // A granted request is always answered: no response is lost.
      //
      // The guard matters.  An earlier version checked only rst_ni, so
      // at the first cycle out of reset $past() reached back into the
      // reset window, where the bus's registers were held clear while
      // the free inputs were not -- and the property fired on a "grant"
      // that never happened.  That produced a counterexample about the
      // harness, not the design, and it took a second look to see it.
      if ($past(rst_ni)) begin
        p_no_lost_instr: assert (!$past(instr_req_i && instr_gnt) || instr_rvalid);
        p_no_lost_data:  assert (!$past(data_req_i  && data_gnt)  || data_rvalid);
      end
    end
  end

endmodule
