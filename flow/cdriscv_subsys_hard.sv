// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// Hardening top: cdriscv_subsys with the boot address fixed at the
// I-TCM base.  The soft IP takes boot_addr_i as a port, and the PC
// reset therefore loads a non-constant -- an async-load flop no
// standard cell implements (64 of them, finding V18).  A hard block
// has one boot address; fixing it here turns those into ordinary
// resettable flops and keeps the soft IP's flexibility out of the
// netlist rather than out of the product.
`default_nettype none
module cdriscv_subsys_hard (
    input  wire        clk_i,
    input  wire        rst_ni,
    input  wire        ref_clk_i,
    input  wire        ref_rst_ni,
    input  wire        fetch_enable_i,
    input  wire [13:0] irq_i,
    input  wire [15:0] fault_ext_i,
    output wire        err_pin_o,
    output wire        reset_req_o,
    output wire        fault_any_o,
    output wire        adc_start_o,
    output wire [2:0]  adc_ch_o,
    input  wire        adc_valid_i,
    input  wire [11:0] adc_data_i,
    output wire [11:0] dac_data_o,
    output wire        dac_we_o,
    output wire        atest_en_o,
    output wire [3:0]  atest_sel_o,
    input  wire [3:0]  ana_flag_i,
    output wire        ext_psel_o,
    output wire        ext_penable_o,
    output wire [11:0] ext_paddr_o,
    output wire        ext_pwrite_o,
    output wire [31:0] ext_pwdata_o,
    output wire [3:0]  ext_pstrb_o,
    input  wire [31:0] ext_prdata_i,
    input  wire        ext_pready_i,
    input  wire        ext_pslverr_i,
    output wire        core_sleep_o,
    output wire        retire_valid_o,
    output wire [31:0] retire_pc_o,
    output wire [31:0] retire_instr_o
);
  cdriscv_subsys u_sub (
      .clk_i          (clk_i),
      .rst_ni         (rst_ni),
      .ref_clk_i      (ref_clk_i),
      .ref_rst_ni     (ref_rst_ni),
      .boot_addr_i    (32'h0000_0000),
      .fetch_enable_i (fetch_enable_i),
      .irq_i          (irq_i),
      .fault_ext_i    (fault_ext_i),
      .err_pin_o      (err_pin_o),
      .reset_req_o    (reset_req_o),
      .fault_any_o    (fault_any_o),
      .adc_start_o    (adc_start_o),
      .adc_ch_o       (adc_ch_o),
      .adc_valid_i    (adc_valid_i),
      .adc_data_i     (adc_data_i),
      .dac_data_o     (dac_data_o),
      .dac_we_o       (dac_we_o),
      .atest_en_o     (atest_en_o),
      .atest_sel_o    (atest_sel_o),
      .ana_flag_i     (ana_flag_i),
      .ext_psel_o     (ext_psel_o),
      .ext_penable_o  (ext_penable_o),
      .ext_paddr_o    (ext_paddr_o),
      .ext_pwrite_o   (ext_pwrite_o),
      .ext_pwdata_o   (ext_pwdata_o),
      .ext_pstrb_o    (ext_pstrb_o),
      .ext_prdata_i   (ext_prdata_i),
      .ext_pready_i   (ext_pready_i),
      .ext_pslverr_i  (ext_pslverr_i),
      .core_sleep_o   (core_sleep_o),
      .retire_valid_o (retire_valid_o),
      .retire_pc_o    (retire_pc_o),
      .retire_instr_o (retire_instr_o)
  );
endmodule
