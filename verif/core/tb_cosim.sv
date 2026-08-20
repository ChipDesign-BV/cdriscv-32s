// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// Co-simulation bench: runs a program out of the I-TCM and prints one
// machine readable line per retired instruction, for comparison with
// the Spike commit log (verif/core/cosim.py).
//
// The I-TCM is relocated to 0x80000000 so that the same ELF runs on
// Spike, which keeps its debug module at [0, 0x1000).  Everything --
// code, data and stack -- lives in that one region, so the data master
// also competes with the fetcher for the I-TCM, which is the arbitration
// case worth exercising.
//
// The trace carries the register write of each retired instruction as
// well as its PC, taken from the core's internal signals through a
// hierarchical reference.  This is the "bind" of the verification plan
// in its simplest form: nothing is added to the RTL, so the synthesised
// design and the lockstep compare vector are untouched.  The path
// assumes the lockstep configuration; CORE_PATH selects the main core.
//
//   +HEX=<file>       39 bit per line image (required)
//   +STOPPC=<hex>     stop when this PC retires (the program's end
//   +STOPPC2=<hex>    label).  Without it the bench goes on simulating
//                     the program's final spin loop up to the retire
//                     limit, which dominated the random regression run
//                     time -- about a minute per program.
//   +MAXRETIRE=<n>    stop after n retired instructions (default 5000)
//   +MAXCYCLES=<n>    give up after n cycles (default 200000)
//   +QUIET            do not print the trace (for timing runs)

`default_nettype none
`timescale 1ns/1ps

`define CORE_PATH dut.g_lockstep.u_core.u_core_main

module tb_cosim #(
    parameter bit Lockstep = 1'b1
);

  localparam time ClkPeriod    = 10ns;
  localparam time RefClkPeriod = 1000ns;

  logic clk, rst_n, ref_clk, ref_rst_n;

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
    rst_n     = 1'b1;
    ref_rst_n = 1'b1;
  end

  logic        fetch_enable;
  logic        retire_valid;
  logic [31:0] retire_pc, retire_instr;
  logic        fault_any, err_pin, reset_req;

  cdriscv_subsys #(
      .Lockstep  (Lockstep),
      .ItcmWords (4096),
      .DtcmWords (4096),
      .ItcmBase  (32'h8000_0000),
      .MbistAuto (1'b0)
  ) dut (
      .clk_i          (clk),
      .rst_ni         (rst_n),
      .ref_clk_i      (ref_clk),
      .ref_rst_ni     (ref_rst_n),
      .boot_addr_i    (32'h8000_0000),
      .fetch_enable_i (fetch_enable),
      .irq_i          ('0),
      .fault_ext_i    ('0),
      .err_pin_o      (err_pin),
      .reset_req_o    (reset_req),
      .fault_any_o    (fault_any),
      .adc_start_o    (),
      .adc_ch_o       (),
      .adc_valid_i    (1'b0),
      .adc_data_i     (12'b0),
      .dac_data_o     (),
      .dac_we_o       (),
      .atest_en_o     (),
      .atest_sel_o    (),
      .ana_flag_i     ('0),
      .ext_psel_o     (),
      .ext_penable_o  (),
      .ext_paddr_o    (),
      .ext_pwrite_o   (),
      .ext_pwdata_o   (),
      .ext_pstrb_o    (),
      .ext_prdata_i   (32'b0),
      .ext_pready_i   (1'b1),
      .ext_pslverr_i  (1'b0),
      .core_sleep_o   (),
      .retire_valid_o (retire_valid),
      .retire_pc_o    (retire_pc),
      .retire_instr_o (retire_instr)
  );

  string       hexfile;
  int unsigned maxretire, maxcycles, nretire, cycle;
  logic [31:0] stoppc, stoppc2;
  logic [31:0] store_data, st_addr;
  logic [3:0]  st_be;
  logic [1:0]  st_off;
  string       trace_line;
  bit          quiet, have_stop;

  initial begin
    fetch_enable = 1'b0;
    nretire      = 0;
    cycle        = 0;

    if (!$value$plusargs("HEX=%s", hexfile)) begin
      $display("[cosim] ERROR: +HEX=<file> is required");
      $fatal(1);
    end
    if (!$value$plusargs("MAXRETIRE=%d", maxretire)) maxretire = 5000;
    if (!$value$plusargs("MAXCYCLES=%d", maxcycles)) maxcycles = 200000;
    quiet = $test$plusargs("QUIET");

    have_stop = 1'b0;
    stoppc    = 32'hffff_ffff;
    stoppc2   = 32'hffff_ffff;
    if ($value$plusargs("STOPPC=%h", stoppc))   have_stop = 1'b1;
    if ($value$plusargs("STOPPC2=%h", stoppc2)) have_stop = 1'b1;

    $readmemh(hexfile, dut.u_itcm.mem);

    @(posedge rst_n);
    repeat (5) @(posedge clk);
    fetch_enable = 1'b1;
  end

  always @(posedge clk) begin
    if (rst_n) begin
      cycle <= cycle + 1;

      if (retire_valid) begin
        // The line mirrors Spike's commit log: the register write if
        // there is one (x0 is suppressed, as Spike suppresses it), then
        // the memory access if there is one -- address only for a load,
        // address and data for a store, with the data truncated to the
        // access width the way Spike reports it.
        if (!quiet) begin
          trace_line = $sformatf("TRACE %08x %08x", retire_pc, retire_instr);
          if (`CORE_PATH.rf_we && (`CORE_PATH.rd_addr != 5'd0)) begin
            trace_line = {trace_line, $sformatf(" x%0d %08x",
                          `CORE_PATH.rd_addr, `CORE_PATH.rf_wdata)};
          end
          // The memory access is reconstructed from the core's *bus*
          // outputs, not from the decoded address and rs2.  That is the
          // whole point: sampling upstream of the LSU would check the
          // address adder and the source register but not the byte
          // enable generation or the write data lane shifting, which is
          // where alignment bugs live.  Byte address and size-truncated
          // data are rebuilt from be and wdata so that the line matches
          // what Spike reports.
          if (`CORE_PATH.lsu_req_dec) begin
            st_be = `CORE_PATH.data_be_o;
            casez (st_be)
              4'b???1: st_off = 2'd0;
              4'b??10: st_off = 2'd1;
              4'b?100: st_off = 2'd2;
              default: st_off = 2'd3;
            endcase
            st_addr = {`CORE_PATH.data_addr_o[31:2], st_off};
            if (`CORE_PATH.data_we_o) begin
              store_data = `CORE_PATH.data_wdata_o >> (8 * st_off);
              case ($countones(st_be))
                1:       store_data = store_data & 32'h0000_00ff;
                2:       store_data = store_data & 32'h0000_ffff;
                default: ;
              endcase
              trace_line = {trace_line, $sformatf(" mem %08x %0x",
                            st_addr, store_data)};
            end else begin
              trace_line = {trace_line, $sformatf(" mem %08x", st_addr)};
            end
          end
          $display("%s", trace_line);
        end
        nretire <= nretire + 1;
        if (have_stop && ((retire_pc == stoppc) || (retire_pc == stoppc2))) begin
          $display("[cosim] reached the end label at %08x after %0d instructions, %0d cycles",
                   retire_pc, nretire + 1, cycle);
          $finish;
        end
        if (nretire + 1 >= maxretire) begin
          $display("[cosim] retired %0d instructions in %0d cycles", nretire + 1, cycle);
          $finish;
        end
      end

      if (fault_any) begin
        $display("[cosim] FAULT: safety status = %08x at cycle %0d",
                 dut.u_safety.status_q, cycle);
        $finish;
      end

      if (cycle >= maxcycles) begin
        $display("[cosim] TIMEOUT after %0d cycles, %0d retired", cycle, nretire);
        $finish;
      end
    end
  end

endmodule
