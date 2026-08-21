// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s -- smoke test bench for the subsystem.
//
// This bench is a starting point, not a verification environment: it
// boots the subsystem out of the I-TCM, prints the retire trace and
// ends when the program writes to the exit register in the SoC
// expansion slot.  See doc/verification_plan.md for what still has to
// be built before the IP may be used.
//
//   +ITCM_HEX=<file>   39 bit per line image, see scripts/mkimage.py
//   +DTCM_HEX=<file>   optional data image
//   +TRACE=1           print every retired instruction
//   +MAX_CYCLES=<n>    give up after n cycles (default 100000)
//
// Exit protocol: a store of 0 to 0x2000_0f00 ends the run as a pass,
// any other value as a fail.
//
// STATUS: NOT VERIFIED YET -- DO NOT USE YET.

`default_nettype none
`timescale 1ns/1ps

module tb_cdriscv_subsys;

  localparam time ClkPeriod    = 10ns;    // 100 MHz system clock
  localparam time RefClkPeriod = 1000ns;  // 1 MHz reference clock

  logic clk, rst_n;
  logic ref_clk, ref_rst_n;

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
  // Device under test
  // ------------------------------------------------------------------
  logic        fetch_enable;
  logic [13:0] irq;
  logic [15:0] fault_ext;

  logic        err_pin, reset_req, fault_any;

  logic        adc_start;
  logic [2:0]  adc_ch;
  logic        adc_valid;
  logic [11:0] adc_data;
  logic [11:0] dac_data;
  logic        dac_we;
  logic        atest_en;
  logic [3:0]  atest_sel;
  logic [3:0]  ana_flag;

  logic        ext_psel, ext_penable, ext_pwrite, ext_pready, ext_pslverr;
  logic [11:0] ext_paddr;
  logic [31:0] ext_pwdata, ext_prdata;
  logic [3:0]  ext_pstrb;

  logic        core_sleep, retire_valid;
  logic [31:0] retire_pc, retire_instr;

  // A gate level netlist is one *configuration*, not a parameterisable
  // module -- synthesis has already resolved the parameters -- so the
  // overrides have to go away for that build.  They are the RTL
  // defaults in any case, which is what makes the two runs comparable;
  // if they ever diverge, the gate flow must pass matching -G options
  // to synthesis rather than the testbench overriding here.
`ifdef GATE_LEVEL
  cdriscv_subsys dut (
`else
  cdriscv_subsys #(
      .Lockstep  (1'b1),
      .ItcmWords (4096),
      .DtcmWords (4096),
      .MbistAuto (1'b0)
  ) dut (
`endif
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
  // Very small ADC model: answers a conversion after 20 cycles with a
  // value that depends on the channel.
  // ------------------------------------------------------------------
  int unsigned adc_delay;

  always_ff @(posedge clk or negedge rst_n) begin
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
  // SoC expansion APB slave: register 0x00 ends the simulation
  // ------------------------------------------------------------------
  logic        exit_seen;
  logic [31:0] exit_code;

  assign ext_pready  = 1'b1;
  assign ext_pslverr = 1'b0;
  assign ext_prdata  = 32'h0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      exit_seen <= 1'b0;
      exit_code <= 32'b0;
    end else if (ext_psel && ext_penable && ext_pwrite && (ext_paddr[7:0] == 8'h00)) begin
      exit_seen <= 1'b1;
      exit_code <= ext_pwdata;
    end
  end

  // ------------------------------------------------------------------
  // Stimulus
  // ------------------------------------------------------------------
  string       itcm_hex, dtcm_hex;
  int unsigned max_cycles, cycle;
  bit          trace_en;

  initial begin
    fetch_enable = 1'b0;
    irq          = '0;
    fault_ext    = '0;
    ana_flag     = '0;

    if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 100000;
    trace_en = $test$plusargs("TRACE");

    if ($value$plusargs("ITCM_HEX=%s", itcm_hex)) begin
      $display("[TB] loading I-TCM from %s", itcm_hex);
      $readmemh(itcm_hex, dut.u_itcm.mem);
    end
    if ($value$plusargs("DTCM_HEX=%s", dtcm_hex)) begin
      $display("[TB] loading D-TCM from %s", dtcm_hex);
      $readmemh(dtcm_hex, dut.u_dtcm.mem);
    end

    @(posedge rst_n);
    repeat (5) @(posedge clk);
    fetch_enable = 1'b1;
  end

  always_ff @(posedge clk) begin
    if (trace_en && retire_valid) begin
      $display("[TRACE] %8t pc=%08x instr=%08x", $time, retire_pc, retire_instr);
    end
    if (fault_any) begin
`ifdef GATE_LEVEL
      // The safety status register is inside the flattened netlist and
      // has no hierarchical path any more.  The memories still do --
      // they are black boxes, so the real module is bound in their
      // place and the program preload above works unchanged.
      $display("[TB] fault reported (safety status not reachable at gate level)");
`else
      $display("[TB] fault reported, safety status = %08x", dut.u_safety.status_q);
`endif
    end
  end

  initial begin
    cycle = 0;
    forever begin
      @(posedge clk);
      cycle++;
      if (exit_seen) begin
        if (exit_code == 32'b0) $display("[TB] PASS after %0d cycles", cycle);
        else                    $display("[TB] FAIL, exit code %08x", exit_code);
        $finish;
      end
      if (cycle >= max_cycles) begin
        $display("[TB] TIMEOUT after %0d cycles", cycle);
        $finish;
      end
    end
  end

  initial begin
    if ($test$plusargs("VCD")) begin
      $dumpfile("tb_cdriscv_subsys.vcd");
      $dumpvars(0, tb_cdriscv_subsys);
    end
  end

endmodule
