// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s -- dual core lockstep (DCLS) wrapper.
//
// Two identical cores run the same program.  The main core drives the
// buses; the checker core sees every input delayed by Delay cycles and
// is released from reset Delay cycles later, so it repeats the main
// core's behaviour with a constant time shift.  The main core's outputs
// are passed through the same delay before they are compared, which
// makes the two output vectors identical cycle by cycle unless a fault
// has occurred.
//
// The delay is what makes this diverse in time: a disturbance that hits
// both cores in the same cycle (supply dip, single event transient on a
// shared net) hits them in different parts of the program, so it is far
// less likely to produce the same wrong result twice.
//
// Comparison starts once the checker is out of reset.  A mismatch is
// reported for one cycle; the safety controller latches it.
//
// STATUS: NOT VERIFIED YET -- DO NOT USE YET.

`default_nettype none

module cdriscv_lockstep
  import cdriscv_pkg::*;
#(
    parameter bit          RV32M     = 1'b1,
    parameter bit          RfParity  = 1'b1,
    parameter int unsigned Delay     = 2,
    parameter logic [31:0] HartId    = 32'h0000_0000,
    parameter logic [31:0] MVendorId = 32'h0000_0000,
    parameter logic [31:0] MArchId   = 32'h0000_0000,
    parameter logic [31:0] MImpId    = 32'h0000_0001
)(
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic [31:0] boot_addr_i,
    input  logic        fetch_enable_i,

    // instruction memory interface
    output logic        instr_req_o,
    input  logic        instr_gnt_i,
    input  logic        instr_rvalid_i,
    output logic [31:0] instr_addr_o,
    input  logic [31:0] instr_rdata_i,
    input  logic        instr_err_i,

    // data memory interface
    output logic        data_req_o,
    input  logic        data_gnt_i,
    input  logic        data_rvalid_i,
    output logic        data_we_o,
    output logic [3:0]  data_be_o,
    output logic [31:0] data_addr_o,
    output logic [31:0] data_wdata_o,
    input  logic [31:0] data_rdata_i,
    input  logic        data_err_i,

    // interrupts
    input  logic        irq_soft_i,
    input  logic        irq_timer_i,
    input  logic        irq_ext_i,

    // comparator self test: flips one bit of the checker's output
    // vector so that the mismatch path can be exercised in the field
    input  logic        inj_en_i,

    // safety
    output logic        fault_rf_par_o,
    output logic        fault_illegal_o,
    output logic        fault_bus_err_o,
    output logic        fault_sw_o,
    output logic        fault_out_en_o,
    output logic        fault_cfg_par_o,
    output logic        fault_lockstep_o,

    // status / trace (main core)
    output logic        core_sleep_o,
    output logic        retire_valid_o,
    output logic [31:0] retire_pc_o,
    output logic [31:0] retire_instr_o
);

  localparam int unsigned DlyStages = (Delay == 0) ? 1 : Delay;

  // ------------------------------------------------------------------
  // Main core
  // ------------------------------------------------------------------
  logic        m_instr_req, m_data_req, m_data_we;
  logic [3:0]  m_data_be;
  logic [31:0] m_instr_addr, m_data_addr, m_data_wdata;
  logic        m_f_rf_par, m_f_cfg_par, m_f_illegal, m_f_bus_err, m_f_sw, m_f_out_en;
  logic        m_sleep, m_retire_valid;
  logic [31:0] m_retire_pc, m_retire_instr;

  cdriscv_core #(
      .RV32M     (RV32M),
      .RfParity  (RfParity),
      .HartId    (HartId),
      .MVendorId (MVendorId),
      .MArchId   (MArchId),
      .MImpId    (MImpId)
  ) u_core_main (
      .clk_i          (clk_i),
      .rst_ni         (rst_ni),
      .boot_addr_i    (boot_addr_i),
      .fetch_enable_i (fetch_enable_i),
      .instr_req_o    (m_instr_req),
      .instr_gnt_i    (instr_gnt_i),
      .instr_rvalid_i (instr_rvalid_i),
      .instr_addr_o   (m_instr_addr),
      .instr_rdata_i  (instr_rdata_i),
      .instr_err_i    (instr_err_i),
      .data_req_o     (m_data_req),
      .data_gnt_i     (data_gnt_i),
      .data_rvalid_i  (data_rvalid_i),
      .data_we_o      (m_data_we),
      .data_be_o      (m_data_be),
      .data_addr_o    (m_data_addr),
      .data_wdata_o   (m_data_wdata),
      .data_rdata_i   (data_rdata_i),
      .data_err_i     (data_err_i),
      .irq_soft_i     (irq_soft_i),
      .irq_timer_i    (irq_timer_i),
      .irq_ext_i      (irq_ext_i),
      .fault_rf_par_o (m_f_rf_par),
      .fault_illegal_o(m_f_illegal),
      .fault_bus_err_o(m_f_bus_err),
      .fault_sw_o     (m_f_sw),
      .fault_out_en_o (m_f_out_en),
      .fault_cfg_par_o(m_f_cfg_par),
      .core_sleep_o   (m_sleep),
      .retire_valid_o (m_retire_valid),
      .retire_pc_o    (m_retire_pc),
      .retire_instr_o (m_retire_instr)
  );

  assign instr_req_o      = m_instr_req;
  assign instr_addr_o     = m_instr_addr;
  assign data_req_o       = m_data_req;
  assign data_we_o        = m_data_we;
  assign data_be_o        = m_data_be;
  assign data_addr_o      = m_data_addr;
  assign data_wdata_o     = m_data_wdata;
  assign fault_rf_par_o   = m_f_rf_par;
  assign fault_illegal_o  = m_f_illegal;
  assign fault_bus_err_o  = m_f_bus_err;
  assign fault_sw_o       = m_f_sw;
  assign fault_out_en_o   = m_f_out_en;
  assign fault_cfg_par_o  = m_f_cfg_par;
  assign core_sleep_o     = m_sleep;
  assign retire_valid_o   = m_retire_valid;
  assign retire_pc_o      = m_retire_pc;
  assign retire_instr_o   = m_retire_instr;

  // ------------------------------------------------------------------
  // Delay lines
  // ------------------------------------------------------------------
  localparam int unsigned InW  = 74;
  localparam int unsigned OutW = 175;

  logic [InW-1:0]  in_vec, in_vec_dly;
  logic [OutW-1:0] out_vec_main, out_vec_main_dly, out_vec_check;

  assign in_vec = {instr_gnt_i, instr_rvalid_i, instr_rdata_i, instr_err_i,
                   data_gnt_i,  data_rvalid_i,  data_rdata_i,  data_err_i,
                   irq_soft_i,  irq_timer_i,    irq_ext_i,     fetch_enable_i};

  assign out_vec_main = {m_instr_req, m_instr_addr,
                         m_data_req, m_data_we, m_data_be, m_data_addr, m_data_wdata,
                         m_f_rf_par, m_f_cfg_par, m_f_illegal, m_f_bus_err, m_f_sw, m_f_out_en,
                         m_sleep, m_retire_valid, m_retire_pc, m_retire_instr};

  if (Delay == 0) begin : g_no_delay
    assign in_vec_dly       = in_vec;
    assign out_vec_main_dly = out_vec_main;
  end else begin : g_delay
    logic [DlyStages-1:0][InW-1:0]  in_pipe_q;
    logic [DlyStages-1:0][OutW-1:0] out_pipe_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        in_pipe_q  <= '0;
        out_pipe_q <= '0;
      end else begin
        in_pipe_q[0]  <= in_vec;
        out_pipe_q[0] <= out_vec_main;
        for (int unsigned s = 1; s < DlyStages; s++) begin
          in_pipe_q[s]  <= in_pipe_q[s-1];
          out_pipe_q[s] <= out_pipe_q[s-1];
        end
      end
    end

    assign in_vec_dly       = in_pipe_q[DlyStages-1];
    assign out_vec_main_dly = out_pipe_q[DlyStages-1];
  end

  // ------------------------------------------------------------------
  // Delayed reset release for the checker
  // ------------------------------------------------------------------
  logic check_rst_n;

  if (Delay == 0) begin : g_rst_direct
    assign check_rst_n = rst_ni;
  end else if (Delay == 1) begin : g_rst_delayed1
    logic rst_pipe_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) rst_pipe_q <= 1'b0;
      else         rst_pipe_q <= 1'b1;
    end
    assign check_rst_n = rst_ni && rst_pipe_q;
  end else begin : g_rst_delayed
    logic [Delay-1:0] rst_pipe_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) rst_pipe_q <= '0;
      else         rst_pipe_q <= {rst_pipe_q[Delay-2:0], 1'b1};
    end
    assign check_rst_n = rst_ni && rst_pipe_q[Delay-1];
  end

  // ------------------------------------------------------------------
  // Checker core
  // ------------------------------------------------------------------
  logic        c_instr_gnt, c_instr_rvalid, c_instr_err;
  logic [31:0] c_instr_rdata;
  logic        c_data_gnt, c_data_rvalid, c_data_err;
  logic [31:0] c_data_rdata;
  logic        c_irq_soft, c_irq_timer, c_irq_ext, c_fetch_enable;

  assign {c_instr_gnt, c_instr_rvalid, c_instr_rdata, c_instr_err,
          c_data_gnt,  c_data_rvalid,  c_data_rdata,  c_data_err,
          c_irq_soft,  c_irq_timer,    c_irq_ext,     c_fetch_enable} = in_vec_dly;

  logic        k_instr_req, k_data_req, k_data_we;
  logic [3:0]  k_data_be;
  logic [31:0] k_instr_addr, k_data_addr, k_data_wdata;
  logic        k_f_rf_par, k_f_cfg_par, k_f_illegal, k_f_bus_err, k_f_sw, k_f_out_en;
  logic        k_sleep, k_retire_valid;
  logic [31:0] k_retire_pc, k_retire_instr;

  cdriscv_core #(
      .RV32M     (RV32M),
      .RfParity  (RfParity),
      .HartId    (HartId),
      .MVendorId (MVendorId),
      .MArchId   (MArchId),
      .MImpId    (MImpId)
  ) u_core_check (
      .clk_i          (clk_i),
      .rst_ni         (check_rst_n),
      .boot_addr_i    (boot_addr_i),
      .fetch_enable_i (c_fetch_enable),
      .instr_req_o    (k_instr_req),
      .instr_gnt_i    (c_instr_gnt),
      .instr_rvalid_i (c_instr_rvalid),
      .instr_addr_o   (k_instr_addr),
      .instr_rdata_i  (c_instr_rdata),
      .instr_err_i    (c_instr_err),
      .data_req_o     (k_data_req),
      .data_gnt_i     (c_data_gnt),
      .data_rvalid_i  (c_data_rvalid),
      .data_we_o      (k_data_we),
      .data_be_o      (k_data_be),
      .data_addr_o    (k_data_addr),
      .data_wdata_o   (k_data_wdata),
      .data_rdata_i   (c_data_rdata),
      .data_err_i     (c_data_err),
      .irq_soft_i     (c_irq_soft),
      .irq_timer_i    (c_irq_timer),
      .irq_ext_i      (c_irq_ext),
      .fault_rf_par_o (k_f_rf_par),
      .fault_illegal_o(k_f_illegal),
      .fault_bus_err_o(k_f_bus_err),
      .fault_sw_o     (k_f_sw),
      .fault_out_en_o (k_f_out_en),
      .fault_cfg_par_o(k_f_cfg_par),
      .core_sleep_o   (k_sleep),
      .retire_valid_o (k_retire_valid),
      .retire_pc_o    (k_retire_pc),
      .retire_instr_o (k_retire_instr)
  );

  assign out_vec_check = {k_instr_req, k_instr_addr,
                          k_data_req, k_data_we, k_data_be, k_data_addr, k_data_wdata,
                          k_f_rf_par, k_f_cfg_par, k_f_illegal, k_f_bus_err, k_f_sw, k_f_out_en,
                          k_sleep, k_retire_valid, k_retire_pc, k_retire_instr};

  // ------------------------------------------------------------------
  // Comparator
  // ------------------------------------------------------------------
  logic [OutW-1:0] compare_vec;
  assign compare_vec = out_vec_check ^ {{(OutW-1){1'b0}}, inj_en_i};

  logic compare_en;
  assign compare_en = check_rst_n;

  assign fault_lockstep_o = compare_en && (compare_vec != out_vec_main_dly);

endmodule
