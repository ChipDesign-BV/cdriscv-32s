// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s -- clock monitor, APB slave.
//
// The system clock is measured against an independent reference clock
// (typically a slow, always-on oscillator).  The system domain toggles
// a heartbeat every HbDiv cycles; the reference domain counts its own
// cycles between two heartbeat edges and compares the result against a
// window:
//
//   count < MIN   system clock too fast
//   count > MAX   system clock too slow
//   no edge       system clock stopped (the counter saturates at MAX)
//
// Detection lives in the reference domain on purpose: a monitor clocked
// by the clock it watches cannot report that clock's failure.
//
//   0x00  CTRL    RW  [0] enable
//   0x04  MIN     RW  lower bound, in reference clock cycles
//   0x08  MAX     RW  upper bound, in reference clock cycles
//   0x0c  STATUS  RW  [0] out of range (W1C, sticky)
//   0x10  COUNT   RO  last measured value
//
// MIN and MAX are quasi-static: write them while CTRL.enable is 0.  The
// only signals that cross between the two domains are single bits
// through the synchronisers in cdriscv_sync.sv, plus the measurement
// result, which is captured in the system domain two cycles after the
// toggle that announces it and is stable by then.
//
// STATUS: NOT VERIFIED YET -- DO NOT USE YET.

`default_nettype none

module cdriscv_clkmon #(
    parameter int unsigned HbDiv = 256,
    parameter int unsigned CntW  = 24
)(
    // system domain
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

    output logic        fault_o,        // level, system domain

    // reference domain
    input  logic        ref_clk_i,
    input  logic        ref_rst_ni
);

  localparam int unsigned HbW = (HbDiv > 1) ? $clog2(HbDiv) : 1;

  // ------------------------------------------------------------------
  // System domain: registers and heartbeat
  // ------------------------------------------------------------------
  logic            enable_q;
  logic [CntW-1:0] min_q, max_q;
  logic            sts_range_q;
  logic [CntW-1:0] last_count_q;

  logic wr, rd;
  assign wr = psel_i && penable_i &&  pwrite_i;
  assign rd = psel_i && !pwrite_i;

  logic [HbW-1:0] hb_cnt_q;
  logic           hb_toggle_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      hb_cnt_q    <= '0;
      hb_toggle_q <= 1'b0;
    end else if (enable_q) begin
      if (hb_cnt_q == HbW'(HbDiv - 1)) begin
        hb_cnt_q    <= '0;
        hb_toggle_q <= ~hb_toggle_q;
      end else begin
        hb_cnt_q <= hb_cnt_q + 1'b1;
      end
    end
  end

  // enable crosses as a level; it is quasi-static
  logic ref_enable;
  cdriscv_sync_lvl #(.Stages(2)) u_sync_en (
      .clk_i  (ref_clk_i),
      .rst_ni (ref_rst_ni),
      .d_i    (enable_q),
      .q_o    (ref_enable)
  );

  // ------------------------------------------------------------------
  // Reference domain: measurement
  // ------------------------------------------------------------------
  logic ref_hb, ref_hb_q, ref_hb_edge;

  cdriscv_sync_lvl #(.Stages(2)) u_sync_hb (
      .clk_i  (ref_clk_i),
      .rst_ni (ref_rst_ni),
      .d_i    (hb_toggle_q),
      .q_o    (ref_hb)
  );

  logic [CntW-1:0] ref_cnt_q, ref_meas_q;
  logic            ref_fault_q, ref_result_toggle_q;
  logic            ref_saturate;

  assign ref_hb_edge  = ref_hb ^ ref_hb_q;
  assign ref_saturate = (ref_cnt_q >= max_q);

  logic ref_clear;   // sticky status clear request from the system side

  always_ff @(posedge ref_clk_i or negedge ref_rst_ni) begin
    if (!ref_rst_ni) begin
      ref_hb_q            <= 1'b0;
      ref_cnt_q           <= '0;
      ref_meas_q          <= '0;
      ref_fault_q         <= 1'b0;
      ref_result_toggle_q <= 1'b0;
    end else begin
      ref_hb_q <= ref_hb;

      if (!ref_enable) begin
        ref_cnt_q <= '0;
      end else if (ref_hb_edge) begin
        // one heartbeat period measured
        ref_cnt_q           <= '0;
        ref_meas_q          <= ref_cnt_q;
        ref_result_toggle_q <= ~ref_result_toggle_q;
        if ((ref_cnt_q < min_q) || (ref_cnt_q > max_q)) begin
          ref_fault_q <= 1'b1;
        end
      end else if (ref_saturate) begin
        // no heartbeat within the allowed window: clock lost
        ref_cnt_q           <= '0;
        ref_meas_q          <= ref_cnt_q;
        ref_result_toggle_q <= ~ref_result_toggle_q;
        ref_fault_q         <= 1'b1;
      end else begin
        ref_cnt_q <= ref_cnt_q + 1'b1;
      end

      if (ref_clear) ref_fault_q <= 1'b0;
    end
  end

  cdriscv_pulse_sync #(.Stages(2)) u_clear_sync (
      .src_clk_i   (clk_i),
      .src_rst_ni  (rst_ni),
      .src_pulse_i (wr && (paddr_i[7:0] == 8'h0c) && pwdata_i[0]),
      .dst_clk_i   (ref_clk_i),
      .dst_rst_ni  (ref_rst_ni),
      .dst_pulse_o (ref_clear)
  );

  // ------------------------------------------------------------------
  // Back into the system domain
  // ------------------------------------------------------------------
  logic sys_fault;
  cdriscv_sync_lvl #(.Stages(2)) u_sync_fault (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .d_i    (ref_fault_q),
      .q_o    (sys_fault)
  );

  logic sys_result_toggle, sys_result_toggle_q, sys_result_edge;
  cdriscv_sync_lvl #(.Stages(2)) u_sync_result (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .d_i    (ref_result_toggle_q),
      .q_o    (sys_result_toggle)
  );
  assign sys_result_edge = sys_result_toggle ^ sys_result_toggle_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      enable_q            <= 1'b0;
      min_q               <= '0;
      max_q               <= {CntW{1'b1}};
      sts_range_q         <= 1'b0;
      last_count_q        <= '0;
      sys_result_toggle_q <= 1'b0;
    end else begin
      sys_result_toggle_q <= sys_result_toggle;
      if (sys_result_edge) last_count_q <= ref_meas_q;
      if (sys_fault)       sts_range_q  <= 1'b1;

      if (wr) begin
        unique case (paddr_i[7:0])
          8'h00:   enable_q <= pwdata_i[0];
          8'h04:   min_q    <= pwdata_i[CntW-1:0];
          8'h08:   max_q    <= pwdata_i[CntW-1:0];
          8'h0c:   if (pwdata_i[0]) sts_range_q <= 1'b0;
          default: ;
        endcase
      end
    end
  end

  always_comb begin
    prdata_o = 32'b0;
    if (rd) begin
      unique case (paddr_i[7:0])
        8'h00:   prdata_o = {31'b0, enable_q};
        8'h04:   prdata_o = {{(32-CntW){1'b0}}, min_q};
        8'h08:   prdata_o = {{(32-CntW){1'b0}}, max_q};
        8'h0c:   prdata_o = {31'b0, sts_range_q};
        8'h10:   prdata_o = {{(32-CntW){1'b0}}, last_count_q};
        default: prdata_o = 32'b0;
      endcase
    end
  end

  assign pready_o  = 1'b1;
  assign pslverr_o = 1'b0;
  assign fault_o   = sys_fault;

endmodule
