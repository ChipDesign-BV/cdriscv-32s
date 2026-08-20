// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s -- top level of the core subsystem.
//
//   core (single or dual core lockstep)
//   +-- bus  --+-- I-TCM (SEC-DED, BIST)
//              +-- D-TCM (SEC-DED, BIST)
//              +-- APB bridge --+-- safety controller   slot 0
//                               +-- watchdog            slot 1
//                               +-- machine timer       slot 2
//                               +-- clock monitor       slot 3
//                               +-- AMS interface       slot 4
//                               +-- memory BIST         slot 5
//                               +-- interrupt control   slot 6
//                               +-- SoC expansion       slot 15
//
// Reset handling: the external reset is synchronised once and drives
// everything.  A reset request from the watchdog or the safety
// controller pulls a warm reset that restarts the core but leaves the
// peripherals and their status registers standing, so the software can
// find out afterwards why it restarted.
//
// STATUS: NOT VERIFIED YET -- DO NOT USE YET.

`default_nettype none

module cdriscv_subsys
  import cdriscv_pkg::*;
#(
    parameter bit          Lockstep    = 1'b1,
    parameter int unsigned LockstepDly = 2,
    parameter bit          RV32M       = 1'b1,
    parameter bit          RfParity    = 1'b1,
    parameter int unsigned ItcmWords   = 4096,
    parameter int unsigned DtcmWords   = 4096,
    parameter bit          MbistAuto   = 1'b0,
    parameter logic [31:0] ItcmBase    = 32'h0000_0000,
    parameter logic [31:0] DtcmBase    = 32'h1000_0000,
    parameter logic [31:0] PeriphBase  = 32'h2000_0000,
    parameter logic [31:0] HartId      = 32'h0000_0000,
    parameter int unsigned WarmRstLen  = 16
)(
    // system domain
    input  logic        clk_i,
    input  logic        rst_ni,

    // independent reference clock for the clock monitor
    input  logic        ref_clk_i,
    input  logic        ref_rst_ni,

    input  logic [31:0] boot_addr_i,
    input  logic        fetch_enable_i,

    // SoC interrupts
    input  logic [13:0] irq_i,

    // safety
    input  logic [NUM_EXT_FAULTS-1:0] fault_ext_i,
    output logic        err_pin_o,
    output logic        reset_req_o,
    output logic        fault_any_o,

    // analog / mixed-signal
    output logic        adc_start_o,
    output logic [2:0]  adc_ch_o,
    input  logic        adc_valid_i,
    input  logic [11:0] adc_data_i,
    output logic [11:0] dac_data_o,
    output logic        dac_we_o,
    output logic        atest_en_o,
    output logic [3:0]  atest_sel_o,
    input  logic [3:0]  ana_flag_i,

    // SoC expansion APB (peripheral slot 15)
    output logic        ext_psel_o,
    output logic        ext_penable_o,
    output logic [11:0] ext_paddr_o,
    output logic        ext_pwrite_o,
    output logic [31:0] ext_pwdata_o,
    output logic [3:0]  ext_pstrb_o,
    input  logic [31:0] ext_prdata_i,
    input  logic        ext_pready_i,
    input  logic        ext_pslverr_i,

    // status and trace
    output logic        core_sleep_o,
    output logic        retire_valid_o,
    output logic [31:0] retire_pc_o,
    output logic [31:0] retire_instr_o
);

  localparam int unsigned ItcmBytes   = ItcmWords * 4;
  localparam int unsigned DtcmBytes   = DtcmWords * 4;
  localparam int unsigned PeriphBytes = 4096;

  // ------------------------------------------------------------------
  // Reset generation
  // ------------------------------------------------------------------
  logic rst_n_sync;

  cdriscv_rst_sync #(.Stages(3)) u_rst_sync (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .rst_no (rst_n_sync)
  );

  logic reset_req;                       // from the watchdog / safety controller
  logic [$clog2(WarmRstLen+1)-1:0] warm_cnt_q;
  logic core_rst_n;

  always_ff @(posedge clk_i or negedge rst_n_sync) begin
    if (!rst_n_sync) begin
      warm_cnt_q <= '0;
    end else if (reset_req) begin
      warm_cnt_q <= WarmRstLen[$clog2(WarmRstLen+1)-1:0];
    end else if (warm_cnt_q != '0) begin
      warm_cnt_q <= warm_cnt_q - 1'b1;
    end
  end

  assign core_rst_n  = rst_n_sync && (warm_cnt_q == '0);
  assign reset_req_o = (warm_cnt_q != '0);

  // ------------------------------------------------------------------
  // Core
  // ------------------------------------------------------------------
  logic        instr_req, instr_gnt, instr_rvalid, instr_err;
  logic [31:0] instr_addr, instr_rdata;

  logic        data_req, data_gnt, data_rvalid, data_we, data_err;
  logic [3:0]  data_be;
  logic [31:0] data_addr, data_wdata, data_rdata;

  logic        irq_soft, irq_timer, irq_ext;
  logic        f_rf_par, f_illegal, f_bus_err_core, f_sw, f_out_en, f_lockstep;
  logic        inj_lockstep;

  logic        mbist_busy_i_tcm, mbist_busy_d_tcm, mbist_busy;
  logic        core_fetch_enable;

  assign mbist_busy        = mbist_busy_i_tcm || mbist_busy_d_tcm;
  assign core_fetch_enable = fetch_enable_i && !mbist_busy;

  if (Lockstep) begin : g_lockstep
    cdriscv_lockstep #(
        .RV32M    (RV32M),
        .RfParity (RfParity),
        .Delay    (LockstepDly),
        .HartId   (HartId)
    ) u_core (
        .clk_i           (clk_i),
        .rst_ni          (core_rst_n),
        .boot_addr_i     (boot_addr_i),
        .fetch_enable_i  (core_fetch_enable),
        .instr_req_o     (instr_req),
        .instr_gnt_i     (instr_gnt),
        .instr_rvalid_i  (instr_rvalid),
        .instr_addr_o    (instr_addr),
        .instr_rdata_i   (instr_rdata),
        .instr_err_i     (instr_err),
        .data_req_o      (data_req),
        .data_gnt_i      (data_gnt),
        .data_rvalid_i   (data_rvalid),
        .data_we_o       (data_we),
        .data_be_o       (data_be),
        .data_addr_o     (data_addr),
        .data_wdata_o    (data_wdata),
        .data_rdata_i    (data_rdata),
        .data_err_i      (data_err),
        .irq_soft_i      (irq_soft),
        .irq_timer_i     (irq_timer),
        .irq_ext_i       (irq_ext),
        .inj_en_i        (inj_lockstep),
        .fault_rf_par_o  (f_rf_par),
        .fault_illegal_o (f_illegal),
        .fault_bus_err_o (f_bus_err_core),
        .fault_sw_o      (f_sw),
        .fault_out_en_o  (f_out_en),
        .fault_lockstep_o(f_lockstep),
        .core_sleep_o    (core_sleep_o),
        .retire_valid_o  (retire_valid_o),
        .retire_pc_o     (retire_pc_o),
        .retire_instr_o  (retire_instr_o)
    );
  end else begin : g_single_core
    assign f_lockstep = 1'b0;

    cdriscv_core #(
        .RV32M    (RV32M),
        .RfParity (RfParity),
        .HartId   (HartId)
    ) u_core (
        .clk_i           (clk_i),
        .rst_ni          (core_rst_n),
        .boot_addr_i     (boot_addr_i),
        .fetch_enable_i  (core_fetch_enable),
        .instr_req_o     (instr_req),
        .instr_gnt_i     (instr_gnt),
        .instr_rvalid_i  (instr_rvalid),
        .instr_addr_o    (instr_addr),
        .instr_rdata_i   (instr_rdata),
        .instr_err_i     (instr_err),
        .data_req_o      (data_req),
        .data_gnt_i      (data_gnt),
        .data_rvalid_i   (data_rvalid),
        .data_we_o       (data_we),
        .data_be_o       (data_be),
        .data_addr_o     (data_addr),
        .data_wdata_o    (data_wdata),
        .data_rdata_i    (data_rdata),
        .data_err_i      (data_err),
        .irq_soft_i      (irq_soft),
        .irq_timer_i     (irq_timer),
        .irq_ext_i       (irq_ext),
        .fault_rf_par_o  (f_rf_par),
        .fault_illegal_o (f_illegal),
        .fault_bus_err_o (f_bus_err_core),
        .fault_sw_o      (f_sw),
        .fault_out_en_o  (f_out_en),
        .core_sleep_o    (core_sleep_o),
        .retire_valid_o  (retire_valid_o),
        .retire_pc_o     (retire_pc_o),
        .retire_instr_o  (retire_instr_o)
    );
  end

  // ------------------------------------------------------------------
  // Interconnect
  // ------------------------------------------------------------------
  logic        itcm_req, itcm_gnt, itcm_rvalid, itcm_we, itcm_err;
  logic [3:0]  itcm_be;
  logic [31:0] itcm_addr, itcm_wdata, itcm_rdata;

  logic        dtcm_req, dtcm_gnt, dtcm_rvalid, dtcm_we, dtcm_err;
  logic [3:0]  dtcm_be;
  logic [31:0] dtcm_addr, dtcm_wdata, dtcm_rdata;

  logic        periph_req, periph_gnt, periph_rvalid, periph_we, periph_err;
  logic [3:0]  periph_be;
  logic [31:0] periph_addr, periph_wdata, periph_rdata;

  logic        f_bus_err_xbar;

  cdriscv_bus #(
      .ItcmBase   (ItcmBase),
      .ItcmBytes  (ItcmBytes),
      .DtcmBase   (DtcmBase),
      .DtcmBytes  (DtcmBytes),
      .PeriphBase (PeriphBase),
      .PeriphBytes(PeriphBytes)
  ) u_bus (
      .clk_i           (clk_i),
      .rst_ni          (core_rst_n),
      .instr_req_i     (instr_req),
      .instr_gnt_o     (instr_gnt),
      .instr_rvalid_o  (instr_rvalid),
      .instr_addr_i    (instr_addr),
      .instr_rdata_o   (instr_rdata),
      .instr_err_o     (instr_err),
      .data_req_i      (data_req),
      .data_gnt_o      (data_gnt),
      .data_rvalid_o   (data_rvalid),
      .data_we_i       (data_we),
      .data_be_i       (data_be),
      .data_addr_i     (data_addr),
      .data_wdata_i    (data_wdata),
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
      .periph_req_o    (periph_req),
      .periph_gnt_i    (periph_gnt),
      .periph_rvalid_i (periph_rvalid),
      .periph_we_o     (periph_we),
      .periph_be_o     (periph_be),
      .periph_addr_o   (periph_addr),
      .periph_wdata_o  (periph_wdata),
      .periph_rdata_i  (periph_rdata),
      .periph_err_i    (periph_err),
      .fault_bus_err_o (f_bus_err_xbar)
  );

  // ------------------------------------------------------------------
  // Tightly coupled memories
  // ------------------------------------------------------------------
  logic        inj_tcm_en;
  logic [38:0] inj_tcm_mask;

  logic        itcm_ecc_cor, itcm_ecc_unc, dtcm_ecc_cor, dtcm_ecc_unc;

  logic        ibist_en, ibist_we;
  logic [31:0] ibist_addr;
  logic [38:0] ibist_wdata, ibist_rdata;

  logic        dbist_en, dbist_we;
  logic [31:0] dbist_addr;
  logic [38:0] dbist_wdata, dbist_rdata;

  // The memory images are loaded by the bench (hierarchical $readmemh,
  // see tb/tb_cdriscv_subsys.sv) rather than through a parameter: not
  // every simulator binds a string parameter through a hierarchy, and
  // the bench needs to be able to reload between runs anyway.
  cdriscv_tcm #(
      .Depth (ItcmWords)
  ) u_itcm (
      .clk_i        (clk_i),
      .rst_ni       (rst_n_sync),
      .req_i        (itcm_req),
      .gnt_o        (itcm_gnt),
      .rvalid_o     (itcm_rvalid),
      .we_i         (itcm_we),
      .be_i         (itcm_be),
      .addr_i       (itcm_addr),
      .wdata_i      (itcm_wdata),
      .rdata_o      (itcm_rdata),
      .err_o        (itcm_err),
      .ecc_cor_o    (itcm_ecc_cor),
      .ecc_unc_o    (itcm_ecc_unc),
      .inj_en_i     (inj_tcm_en),
      .inj_mask_i   (inj_tcm_mask),
      .bist_en_i    (ibist_en),
      .bist_we_i    (ibist_we),
      .bist_addr_i  (ibist_addr),
      .bist_wdata_i (ibist_wdata),
      .bist_rdata_o (ibist_rdata)
  );

  cdriscv_tcm #(
      .Depth (DtcmWords)
  ) u_dtcm (
      .clk_i        (clk_i),
      .rst_ni       (rst_n_sync),
      .req_i        (dtcm_req),
      .gnt_o        (dtcm_gnt),
      .rvalid_o     (dtcm_rvalid),
      .we_i         (dtcm_we),
      .be_i         (dtcm_be),
      .addr_i       (dtcm_addr),
      .wdata_i      (dtcm_wdata),
      .rdata_o      (dtcm_rdata),
      .err_o        (dtcm_err),
      .ecc_cor_o    (dtcm_ecc_cor),
      .ecc_unc_o    (dtcm_ecc_unc),
      .inj_en_i     (inj_tcm_en),
      .inj_mask_i   (inj_tcm_mask),
      .bist_en_i    (dbist_en),
      .bist_we_i    (dbist_we),
      .bist_addr_i  (dbist_addr),
      .bist_wdata_i (dbist_wdata),
      .bist_rdata_o (dbist_rdata)
  );

  // ------------------------------------------------------------------
  // APB bridge and peripherals
  // ------------------------------------------------------------------
  logic [15:0] psel;
  logic        penable, pwrite;
  logic [11:0] paddr;
  logic [31:0] pwdata;
  logic [3:0]  pstrb;
  logic [31:0] prdata;
  logic        pready, pslverr;

  cdriscv_apb_bridge #(
      .NumSlaves (16)
  ) u_apb (
      .clk_i     (clk_i),
      .rst_ni    (rst_n_sync),
      .req_i     (periph_req),
      .gnt_o     (periph_gnt),
      .rvalid_o  (periph_rvalid),
      .we_i      (periph_we),
      .be_i      (periph_be),
      .addr_i    (periph_addr),
      .wdata_i   (periph_wdata),
      .rdata_o   (periph_rdata),
      .err_o     (periph_err),
      .psel_o    (psel),
      .penable_o (penable),
      .paddr_o   (paddr),
      .pwrite_o  (pwrite),
      .pwdata_o  (pwdata),
      .pstrb_o   (pstrb),
      .prdata_i  (prdata),
      .pready_i  (pready),
      .pslverr_i (pslverr)
  );

  // ---- slot 0: safety controller ----
  logic [31:0] sfty_prdata;
  logic        sfty_pready, sfty_pslverr;
  logic        sfty_irq, sfty_reset_req;
  logic [NUM_INT_FAULTS-1:0] fault_int;

  cdriscv_safety_ctrl u_safety (
      .clk_i          (clk_i),
      .rst_ni         (rst_n_sync),
      .psel_i         (psel[0]),
      .penable_i      (penable),
      .paddr_i        (paddr),
      .pwrite_i       (pwrite),
      .pwdata_i       (pwdata),
      .prdata_o       (sfty_prdata),
      .pready_o       (sfty_pready),
      .pslverr_o      (sfty_pslverr),
      .fault_int_i    (fault_int),
      .fault_ext_i    (fault_ext_i),
      .irq_o          (sfty_irq),
      .reset_req_o    (sfty_reset_req),
      .err_pin_o      (err_pin_o),
      .fault_any_o    (fault_any_o),
      .inj_lockstep_o (inj_lockstep),
      .inj_tcm_en_o   (inj_tcm_en),
      .inj_tcm_mask_o (inj_tcm_mask)
  );

  // ---- slot 1: watchdog ----
  logic [31:0] wdog_prdata;
  logic        wdog_pready, wdog_pslverr, wdog_fault, wdog_reset_req;

  cdriscv_wdog u_wdog (
      .clk_i       (clk_i),
      .rst_ni      (rst_n_sync),
      .psel_i      (psel[1]),
      .penable_i   (penable),
      .paddr_i     (paddr),
      .pwrite_i    (pwrite),
      .pwdata_i    (pwdata),
      .prdata_o    (wdog_prdata),
      .pready_o    (wdog_pready),
      .pslverr_o   (wdog_pslverr),
      .fault_o     (wdog_fault),
      .reset_req_o (wdog_reset_req)
  );

  // ---- slot 2: machine timer ----
  logic [31:0] tmr_prdata;
  logic        tmr_pready, tmr_pslverr;

  cdriscv_timer u_timer (
      .clk_i     (clk_i),
      .rst_ni    (rst_n_sync),
      .psel_i    (psel[2]),
      .penable_i (penable),
      .paddr_i   (paddr),
      .pwrite_i  (pwrite),
      .pwdata_i  (pwdata),
      .prdata_o  (tmr_prdata),
      .pready_o  (tmr_pready),
      .pslverr_o (tmr_pslverr),
      .irq_o     (irq_timer)
  );

  // ---- slot 3: clock monitor ----
  logic [31:0] clkm_prdata;
  logic        clkm_pready, clkm_pslverr, clkm_fault;

  cdriscv_clkmon u_clkmon (
      .clk_i      (clk_i),
      .rst_ni     (rst_n_sync),
      .psel_i     (psel[3]),
      .penable_i  (penable),
      .paddr_i    (paddr),
      .pwrite_i   (pwrite),
      .pwdata_i   (pwdata),
      .prdata_o   (clkm_prdata),
      .pready_o   (clkm_pready),
      .pslverr_o  (clkm_pslverr),
      .fault_o    (clkm_fault),
      .ref_clk_i  (ref_clk_i),
      .ref_rst_ni (ref_rst_ni)
  );

  // ---- slot 4: AMS interface ----
  logic [31:0] ams_prdata;
  logic        ams_pready, ams_pslverr, ams_irq, ams_fault;

  cdriscv_ams_if #(
      .NumCh (8),
      .AdcW  (12)
  ) u_ams (
      .clk_i       (clk_i),
      .rst_ni      (rst_n_sync),
      .psel_i      (psel[4]),
      .penable_i   (penable),
      .paddr_i     (paddr),
      .pwrite_i    (pwrite),
      .pwdata_i    (pwdata),
      .prdata_o    (ams_prdata),
      .pready_o    (ams_pready),
      .pslverr_o   (ams_pslverr),
      .adc_start_o (adc_start_o),
      .adc_ch_o    (adc_ch_o),
      .adc_valid_i (adc_valid_i),
      .adc_data_i  (adc_data_i),
      .dac_data_o  (dac_data_o),
      .dac_we_o    (dac_we_o),
      .atest_en_o  (atest_en_o),
      .atest_sel_o (atest_sel_o),
      .ana_flag_i  (ana_flag_i),
      .irq_o       (ams_irq),
      .fault_o     (ams_fault)
  );

  // ---- slot 5: memory BIST (two controllers in one slot) ----
  logic [31:0] ibist_prdata, dbist_prdata;
  logic        ibist_hit, dbist_hit;
  logic        ibist_done, ibist_fail, dbist_done, dbist_fail;
  logic        ibist_pready, ibist_pslverr, dbist_pready, dbist_pslverr;

  cdriscv_mbist #(
      .Depth     (ItcmWords),
      .RegBase   (8'h00),
      .AutoStart (MbistAuto)
  ) u_mbist_i (
      .clk_i        (clk_i),
      .rst_ni       (rst_n_sync),
      .psel_i       (psel[5]),
      .penable_i    (penable),
      .paddr_i      (paddr),
      .pwrite_i     (pwrite),
      .pwdata_i     (pwdata),
      .prdata_o     (ibist_prdata),
      .psel_hit_o   (ibist_hit),
      .pready_o     (ibist_pready),
      .pslverr_o    (ibist_pslverr),
      .busy_o       (mbist_busy_i_tcm),
      .done_o       (ibist_done),
      .fail_o       (ibist_fail),
      .bist_en_o    (ibist_en),
      .bist_we_o    (ibist_we),
      .bist_addr_o  (ibist_addr),
      .bist_wdata_o (ibist_wdata),
      .bist_rdata_i (ibist_rdata)
  );

  cdriscv_mbist #(
      .Depth     (DtcmWords),
      .RegBase   (8'h40),
      .AutoStart (MbistAuto)
  ) u_mbist_d (
      .clk_i        (clk_i),
      .rst_ni       (rst_n_sync),
      .psel_i       (psel[5]),
      .penable_i    (penable),
      .paddr_i      (paddr),
      .pwrite_i     (pwrite),
      .pwdata_i     (pwdata),
      .prdata_o     (dbist_prdata),
      .psel_hit_o   (dbist_hit),
      .pready_o     (dbist_pready),
      .pslverr_o    (dbist_pslverr),
      .busy_o       (mbist_busy_d_tcm),
      .done_o       (dbist_done),
      .fail_o       (dbist_fail),
      .bist_en_o    (dbist_en),
      .bist_we_o    (dbist_we),
      .bist_addr_o  (dbist_addr),
      .bist_wdata_o (dbist_wdata),
      .bist_rdata_i (dbist_rdata)
  );

  // ---- slot 6: interrupt controller ----
  logic [31:0] irqc_prdata;
  logic        irqc_pready, irqc_pslverr;
  logic [15:0] irq_src;

  assign irq_src = {irq_i, ams_irq, sfty_irq};

  cdriscv_irq_ctrl #(
      .NumSrc (16)
  ) u_irq_ctrl (
      .clk_i      (clk_i),
      .rst_ni     (rst_n_sync),
      .psel_i     (psel[6]),
      .penable_i  (penable),
      .paddr_i    (paddr),
      .pwrite_i   (pwrite),
      .pwdata_i   (pwdata),
      .prdata_o   (irqc_prdata),
      .pready_o   (irqc_pready),
      .pslverr_o  (irqc_pslverr),
      .src_i      (irq_src),
      .irq_ext_o  (irq_ext),
      .irq_soft_o (irq_soft)
  );

  // ---- slot 15: SoC expansion ----
  assign ext_psel_o    = psel[15];
  assign ext_penable_o = penable;
  assign ext_paddr_o   = paddr;
  assign ext_pwrite_o  = pwrite;
  assign ext_pwdata_o  = pwdata;
  assign ext_pstrb_o   = pstrb;

  // ---- APB read multiplexer ----
  always_comb begin
    prdata  = 32'b0;
    pready  = 1'b1;
    pslverr = 1'b0;
    case (1'b1)
      psel[0]: begin prdata = sfty_prdata; pready = sfty_pready; pslverr = sfty_pslverr; end
      psel[1]: begin prdata = wdog_prdata; pready = wdog_pready; pslverr = wdog_pslverr; end
      psel[2]: begin prdata = tmr_prdata;  pready = tmr_pready;  pslverr = tmr_pslverr;  end
      psel[3]: begin prdata = clkm_prdata; pready = clkm_pready; pslverr = clkm_pslverr; end
      psel[4]: begin prdata = ams_prdata;  pready = ams_pready;  pslverr = ams_pslverr;  end
      psel[5]: begin
        prdata  = (ibist_hit ? ibist_prdata : 32'b0) | (dbist_hit ? dbist_prdata : 32'b0);
        pready  = ibist_pready && dbist_pready;
        pslverr = ibist_pslverr || dbist_pslverr || !(ibist_hit || dbist_hit);
      end
      psel[6]: begin prdata = irqc_prdata; pready = irqc_pready; pslverr = irqc_pslverr; end
      psel[15]:begin prdata = ext_prdata_i;pready = ext_pready_i;pslverr = ext_pslverr_i;end
      default: begin
        // unmapped peripheral slot
        prdata  = 32'b0;
        pready  = 1'b1;
        pslverr = |psel;
      end
    endcase
  end

  // ------------------------------------------------------------------
  // Fault collection
  // ------------------------------------------------------------------
  always_comb begin
    fault_int                    = '0;
    fault_int[FLT_LOCKSTEP]      = f_lockstep;
    fault_int[FLT_ITCM_ECC_COR]  = itcm_ecc_cor;
    fault_int[FLT_ITCM_ECC_UNC]  = itcm_ecc_unc;
    fault_int[FLT_DTCM_ECC_COR]  = dtcm_ecc_cor;
    fault_int[FLT_DTCM_ECC_UNC]  = dtcm_ecc_unc;
    fault_int[FLT_REGFILE_PAR]   = f_rf_par;
    fault_int[FLT_WDOG]          = wdog_fault;
    fault_int[FLT_CLKMON]        = clkm_fault;
    fault_int[FLT_BUS_ERR]       = f_bus_err_xbar || f_bus_err_core;
    fault_int[FLT_MBIST]         = (ibist_done && ibist_fail) || (dbist_done && dbist_fail);
    fault_int[FLT_AMS]           = ams_fault;
    fault_int[FLT_SW]            = f_sw;
    fault_int[FLT_CORE_TRAP]     = f_illegal;
  end

  assign reset_req = sfty_reset_req || wdog_reset_req;

  logic unused_sigs;
  assign unused_sigs = |{f_out_en, pstrb};

endmodule
