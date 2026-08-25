// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s -- gate-level smoke bench with SDF timing (plan O8).
//
// Runs the software image on the OpenROAD post-repair netlist
// (cdriscv_subsys_pd_final.v) with real cell and interconnect delays
// annotated from the SDF the same flow wrote.  This is the netlist
// with the SRAM macros, so the program image is split across the four
// banks here rather than loaded into one behavioural array.
//
//   +ITCM_HEX=<file>   39 bit per line image, see scripts/mkimage.py
//   +SDF=<file>        SDF file (required)
//   +MAX_CYCLES=<n>    give up after n cycles (default 200000)
//
// Exit protocol as in tb_cdriscv_subsys: a store of 0 to 0x2000_0f00
// is a pass.  The clock is the 20 ns integration target of V41; the
// SDF is the typical corner the flow currently writes.
//
// STATUS: verified to the O1-O7 gate of doc/verification_plan.md
//         (2026-08-24) -- may be used in a project.  O8-O9 and the
//         FMEDA are open: NOT qualified for safety-critical use.

`timescale 1ns/1ps

module tb_sdf_subsys;

  localparam ClkPeriod    = 20;     // ns -- the 50 MHz target
  localparam RefClkPeriod = 1000;   // ns

  reg clk, rst_n;
  reg ref_clk, ref_rst_n;

  initial begin
    clk = 1'b0;
    forever #(ClkPeriod/2) clk = ~clk;
  end

  initial begin
    ref_clk = 1'b0;
    forever #(RefClkPeriod/2) ref_clk = ~ref_clk;
  end

  initial begin
    rst_n     = 1'b0;
    ref_rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ref_clk);
    ref_rst_n = 1'b1;
  end

  // ------------------------------------------------------------------
  // Device under test: the placed-and-repaired netlist
  // ------------------------------------------------------------------
  reg         fetch_enable;
  reg  [13:0] irq;
  reg  [15:0] fault_ext;

  wire        err_pin, reset_req, fault_any;

  wire        adc_start;
  wire [2:0]  adc_ch;
  reg         adc_valid;
  reg  [11:0] adc_data;
  wire [11:0] dac_data;
  wire        dac_we;
  wire        atest_en;
  wire [3:0]  atest_sel;
  reg  [3:0]  ana_flag;

  wire        ext_psel, ext_penable, ext_pwrite;
  reg         ext_pready, ext_pslverr;
  wire [11:0] ext_paddr;
  wire [31:0] ext_pwdata;
  reg  [31:0] ext_prdata;
  wire [3:0]  ext_pstrb;

  wire        core_sleep, retire_valid;
  wire [31:0] retire_pc, retire_instr;

  cdriscv_subsys dut (
      .clk_i          (clk),
      .rst_ni         (rst_n),
      .ref_clk_i      (ref_clk),
      .ref_rst_ni     (ref_rst_n),
      .boot_addr_i    (32'h0000_0000),
      .fetch_enable_i (fetch_enable),
      .irq_i          (irq),
      .fault_ext_i    (fault_ext),
      .err_pin_o      (err_pin),
      .reset_req_o    (reset_req),
      .fault_any_o    (fault_any),
      .adc_start_o    (adc_start),
      .adc_ch_o       (adc_ch),
      .adc_valid_i    (adc_valid),
      .adc_data_i     (adc_data),
      .dac_data_o     (dac_data),
      .dac_we_o       (dac_we),
      .atest_en_o     (atest_en),
      .atest_sel_o    (atest_sel),
      .ana_flag_i     (ana_flag),
      .ext_psel_o     (ext_psel),
      .ext_penable_o  (ext_penable),
      .ext_paddr_o    (ext_paddr),
      .ext_pwrite_o   (ext_pwrite),
      .ext_pwdata_o   (ext_pwdata),
      .ext_pstrb_o    (ext_pstrb),
      .ext_prdata_i   (ext_prdata),
      .ext_pready_i   (ext_pready),
      .ext_pslverr_i  (ext_pslverr),
      .core_sleep_o   (core_sleep),
      .retire_valid_o (retire_valid),
      .retire_pc_o    (retire_pc),
      .retire_instr_o (retire_instr)
  );

  // ------------------------------------------------------------------
  // SDF annotation -- before time advances
  // ------------------------------------------------------------------
  reg [1023:0] sdf_file;
  initial begin
    if ($value$plusargs("SDF=%s", sdf_file)) begin
      $sdf_annotate(sdf_file, dut);
      $display("[TB-SDF] annotated %0s", sdf_file);
    end else begin
      $display("[TB-SDF] running WITHOUT SDF annotation (cell zero-delays)");
    end
  end

  // ------------------------------------------------------------------
  // Program preload: split the 39-bit image across the macro banks.
  // Word i lives in bank i[11], row i[10:0], zero-extended to 64 bits.
  // The netlist is flat, so the bank instances carry escaped names.
  // ------------------------------------------------------------------
  reg [38:0] img [0:4095];
  integer    i;
  reg [1023:0] itcm_hex, dtcm_hex;

  initial begin
    if ($value$plusargs("ITCM_HEX=%s", itcm_hex)) begin
      $display("[TB-SDF] loading I-TCM from %0s", itcm_hex);
      $readmemh(itcm_hex, img);
      for (i = 0; i < 2048; i = i + 1) begin
        dut.\u_itcm.g_bank[0].u_bank .i_SRAM_1P_behavioral_bm_bist.memory[i]
            = {25'b0, img[i]};
        dut.\u_itcm.g_bank[1].u_bank .i_SRAM_1P_behavioral_bm_bist.memory[i]
            = {25'b0, img[i + 2048]};
      end
    end
    if ($value$plusargs("DTCM_HEX=%s", dtcm_hex)) begin
      $display("[TB-SDF] loading D-TCM from %0s", dtcm_hex);
      $readmemh(dtcm_hex, img);
      for (i = 0; i < 2048; i = i + 1) begin
        dut.\u_dtcm.g_bank[0].u_bank .i_SRAM_1P_behavioral_bm_bist.memory[i]
            = {25'b0, img[i]};
        dut.\u_dtcm.g_bank[1].u_bank .i_SRAM_1P_behavioral_bm_bist.memory[i]
            = {25'b0, img[i + 2048]};
      end
    end
  end

  // ------------------------------------------------------------------
  // Minimal ADC model, as in the RTL smoke bench
  // ------------------------------------------------------------------
  integer adc_delay;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      adc_valid <= 1'b0;
      adc_data  <= 12'b0;
      adc_delay <= 0;
    end else begin
      adc_valid <= 1'b0;
      if (adc_start) begin
        adc_delay <= 20;
      end else if (adc_delay > 1) begin
        adc_delay <= adc_delay - 1;
      end else if (adc_delay == 1) begin
        adc_delay <= 0;
        adc_valid <= 1'b1;
        adc_data  <= 12'h100 + {9'b0, adc_ch};
      end
    end
  end

  // ------------------------------------------------------------------
  // Exit register in the SoC expansion slot
  // ------------------------------------------------------------------
  reg        exit_seen;
  reg [31:0] exit_code;

  initial begin
    ext_pready  = 1'b1;
    ext_pslverr = 1'b0;
    ext_prdata  = 32'h0;
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      exit_seen <= 1'b0;
      exit_code <= 32'b0;
    end else if (ext_psel && ext_penable && ext_pwrite && (ext_paddr[7:0] == 8'h00)) begin
      exit_seen <= 1'b1;
      exit_code <= ext_pwdata;
    end
  end

  // ------------------------------------------------------------------
  // Run control
  // ------------------------------------------------------------------
  integer max_cycles, cycle;

  initial begin
    fetch_enable = 1'b0;
    irq          = 14'b0;
    fault_ext    = 16'b0;
    ana_flag     = 4'b0;
    if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 200000;
    @(posedge rst_n);
    repeat (5) @(posedge clk);
    fetch_enable = 1'b1;
  end

  // Diagnostics: is the machine alive at all?
  integer retires;
  initial retires = 0;
  always @(posedge clk) if (retire_valid === 1'b1) begin
    retires = retires + 1;
    if (retires <= 5)
      $display("[TB-SDF] retire %0d: pc=%08x instr=%08x", retires, retire_pc, retire_instr);
  end

  initial begin
    cycle = 0;
    forever begin
      @(posedge clk);
      cycle = cycle + 1;
      if (cycle % 500 == 0)
        $display("[TB-SDF] cycle %0d: retires=%0d retire_valid=%b fault_any=%b core_sleep=%b",
                 cycle, retires, retire_valid, fault_any, core_sleep);
      if (exit_seen) begin
        if (exit_code == 32'b0) $display("[TB-SDF] PASS after %0d cycles", cycle);
        else                    $display("[TB-SDF] FAIL, exit code %08x", exit_code);
        dump_signature;
        $finish;
      end
      if (cycle >= max_cycles) begin
        $display("[TB-SDF] TIMEOUT after %0d cycles", cycle);
        $finish;
      end
    end
  end

  // ------------------------------------------------------------------
  // Signature dump for the arch-test subset (O8): read the D-TCM banks
  // back and write the data bits of each code word, one per line, the
  // format riscof compares.  +SIGBEGIN/+SIGEND are byte addresses in
  // the D-TCM window (0x1000_0000 base).
  // ------------------------------------------------------------------
  integer sig_begin, sig_end, sig_fd, w;
  reg [1023:0] sig_file;
  reg [63:0]   sig_word;

  task dump_signature;
    begin
      if ($value$plusargs("SIGFILE=%s", sig_file) &&
          $value$plusargs("SIGBEGIN=%h", sig_begin) &&
          $value$plusargs("SIGEND=%h", sig_end)) begin
        sig_fd = $fopen(sig_file, "w");
        for (w = (sig_begin - 'h10000000) >> 2;
             w < (sig_end - 'h10000000) >> 2; w = w + 1) begin
          if (w[11])
            sig_word = dut.\u_dtcm.g_bank[1].u_bank .i_SRAM_1P_behavioral_bm_bist.memory[w[10:0]];
          else
            sig_word = dut.\u_dtcm.g_bank[0].u_bank .i_SRAM_1P_behavioral_bm_bist.memory[w[10:0]];
          $fdisplay(sig_fd, "%08x", sig_word[31:0]);
        end
        $fclose(sig_fd);
        $display("[TB-SDF] signature written to %0s", sig_file);
      end
    end
  endtask

endmodule
