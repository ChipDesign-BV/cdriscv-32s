// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// Fault injection bench.
//
// Deposits a single flipped bit into one state element at one cycle --
// a single event upset -- then lets the workload run to completion and
// prints what happened.  The campaign driver (scripts/fi_campaign.py)
// classifies from that line.
//
// A *deposit* is used rather than force/release: the bit is written and
// then left, so the next clock edge may overwrite it exactly as it
// would in silicon.  A held force models a stuck-at, which is a
// different fault model and would flatter the detection numbers.
//
// The fault list is a **named set of state elements**, not every flop
// in the design.  That is stated plainly in the results: a full
// flop-level campaign needs a harness that can enumerate the netlist,
// which this is not.
//
// The D-TCM must be preloaded as well as the I-TCM: the workload does
// sub-word stores, which are read-modify-write, and an unwritten word
// reads as X in simulation.  That is finding V4-F2 again, met from the
// other side.
//
//   +HEX= +DHEX= +TARGET= +BIT= +CYCLE= +GOLDEN=

`default_nettype none
`timescale 1ns/1ps

module tb_fi;

  logic clk, rst_n, ref_clk, ref_rst_n;
  initial begin clk = 0; forever #5ns clk = ~clk; end
  initial begin ref_clk = 0; forever #500ns ref_clk = ~ref_clk; end
  initial begin
    rst_n = 0; ref_rst_n = 0;
    repeat (10) @(posedge clk);
    rst_n = 1; ref_rst_n = 1;
  end

  logic        fetch_enable, fault_any, err_pin, reset_req;
  logic        ext_psel, ext_penable, ext_pwrite;
  logic [11:0] ext_paddr;
  logic [31:0] ext_pwdata;

  cdriscv_subsys #(
      .Lockstep (1'b1), .ItcmWords (4096), .DtcmWords (4096), .MbistAuto (1'b0)
  ) dut (
      .clk_i (clk), .rst_ni (rst_n), .ref_clk_i (ref_clk), .ref_rst_ni (ref_rst_n),
      .boot_addr_i (32'h0), .fetch_enable_i (fetch_enable),
      .irq_i ('0), .fault_ext_i ('0),
      .err_pin_o (err_pin), .reset_req_o (reset_req), .fault_any_o (fault_any),
      .adc_start_o (), .adc_ch_o (), .adc_valid_i (1'b0), .adc_data_i (12'b0),
      .dac_data_o (), .dac_we_o (), .atest_en_o (), .atest_sel_o (), .ana_flag_i ('0),
      .ext_psel_o (ext_psel), .ext_penable_o (ext_penable), .ext_paddr_o (ext_paddr),
      .ext_pwrite_o (ext_pwrite), .ext_pwdata_o (ext_pwdata), .ext_pstrb_o (),
      .ext_prdata_i (32'b0), .ext_pready_i (1'b1), .ext_pslverr_i (1'b0),
      .core_sleep_o (), .retire_valid_o (), .retire_pc_o (), .retire_instr_o ()
  );

  // exit register in the SoC expansion slot
  logic        exit_seen;
  logic [31:0] exit_code;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      exit_seen <= 1'b0;
      exit_code <= 32'b0;
    end else if (ext_psel && ext_penable && ext_pwrite && (ext_paddr[7:0] == 8'h00)) begin
      exit_seen <= 1'b1;
      exit_code <= ext_pwdata;
    end
  end

  string       hexfile, dhexfile;
  int unsigned target, bitpos, injcycle, cycle;
  logic [31:0] golden;
  bit          injected, arm;
  int unsigned idx, b32, b39;
  logic [31:0] status_at_end;

  initial begin
    fetch_enable = 1'b0;
    cycle = 0;
    injected = 1'b0;
    if (!$value$plusargs("HEX=%s", hexfile)) $fatal(1);
    if (!$value$plusargs("TARGET=%d", target))   target   = 0;
    if (!$value$plusargs("BIT=%d", bitpos))      bitpos   = 0;
    if (!$value$plusargs("CYCLE=%d", injcycle))  injcycle = 500;
    if (!$value$plusargs("GOLDEN=%h", golden))   golden   = 32'b0;
    $readmemh(hexfile, dut.u_itcm.mem);
    if ($value$plusargs("DHEX=%s", dhexfile)) $readmemh(dhexfile, dut.u_dtcm.mem);
    @(posedge rst_n);
    repeat (5) @(posedge clk);
    fetch_enable = 1'b1;
  end

  // ------------------------------------------------------------------
  // The fault list.  Named state elements across the core, the
  // memories and the safety logic.
  // ------------------------------------------------------------------
  always @(posedge clk) begin
    if (rst_n) begin
      cycle <= cycle + 1;

      if (!injected && (cycle == injcycle)) arm <= 1'b1;

      if (exit_seen || (cycle > 400000)) begin
        status_at_end = dut.u_safety.status_q;
        $display("FI target=%0d bit=%0d cycle=%0d exit=%08x golden=%08x exited=%0d status=%08x",
                 target, bitpos, injcycle, exit_code, golden, exit_seen, status_at_end);
        $finish;
      end
    end
  end


  // The deposit happens on the falling edge.  On the rising edge the
  // DUT's own flops assign, and the order between that and a bench
  // deposit is undefined -- an earlier version injected there and the
  // corruption was simply overwritten, so every run looked clean.  A
  // fault injector that silently does nothing is the worst possible
  // outcome, because the campaign then reports perfect coverage.
  always @(negedge clk) begin
    if (rst_n && arm && !injected) begin
      injected = 1'b1;
      arm      = 1'b0;
        // Deposits are written as a whole-word XOR with a computed
        // mask rather than a variable bit-select on the left hand
        // side, which not every simulator accepts as an lvalue.
        idx   = bitpos % 31;
        b32   = bitpos % 32;
        b39   = bitpos % 39;
        case (target % 9)
          0: dut.g_lockstep.u_core.u_core_main.u_regfile.rf_q[idx + 1] =
             dut.g_lockstep.u_core.u_core_main.u_regfile.rf_q[idx + 1] ^ (32'b1 << b32);
          1: dut.g_lockstep.u_core.u_core_main.u_if.buf_rdata_q[bitpos % 2] =
             dut.g_lockstep.u_core.u_core_main.u_if.buf_rdata_q[bitpos % 2] ^ (32'b1 << b32);
          2: dut.g_lockstep.u_core.u_core_main.u_if.fetch_pc_q =
             dut.g_lockstep.u_core.u_core_main.u_if.fetch_pc_q ^ (32'b1 << b32);
          3: dut.g_lockstep.u_core.u_core_main.u_csr.mepc_q =
             dut.g_lockstep.u_core.u_core_main.u_csr.mepc_q ^ (32'b1 << b32);
          4: dut.g_lockstep.u_core.u_core_main.u_csr.mstatus_mie_q =
             ~dut.g_lockstep.u_core.u_core_main.u_csr.mstatus_mie_q;
          5: dut.g_lockstep.u_core.u_core_main.u_lsu.addr_lsb_q =
             dut.g_lockstep.u_core.u_core_main.u_lsu.addr_lsb_q ^ (2'b1 << (bitpos % 2));
          // Memory injections have to land on words the workload
          // actually touches, or they are guaranteed to be invisible
          // and would flatter the "undetected" count.  The I-TCM range
          // covers the loop body; the D-TCM range covers the scratch
          // area the workload reads and writes at 0x10000800.
          6: dut.u_itcm.mem[40 + ((bitpos * 7) % 45)] =
             dut.u_itcm.mem[40 + ((bitpos * 7) % 45)] ^ (39'b1 << b39);
          7: dut.u_dtcm.mem[512 + (bitpos % 4)] =
             dut.u_dtcm.mem[512 + (bitpos % 4)] ^ (39'b1 << b39);
          8: dut.g_lockstep.u_core.u_core_main.u_regfile.par_q =
             dut.g_lockstep.u_core.u_core_main.u_regfile.par_q ^ (31'b1 << idx);
          default: ;
        endcase
    end
  end

endmodule