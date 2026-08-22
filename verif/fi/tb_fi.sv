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
// in the design.  It covers twenty of them, chosen to include the
// safety controller's own configuration registers: an upset there does
// not corrupt a result, it switches a detector off, and a campaign
// that injects only into datapath state cannot see that happening.  That is stated plainly in the results: a full
// flop-level campaign needs a harness that can enumerate the netlist,
// which this is not.
//
// The D-TCM must be preloaded as well as the I-TCM: the workload does
// sub-word stores, which are read-modify-write, and an unwritten word
// reads as X in simulation.  That is finding V4-F2 again, met from the
// other side.
//
// The I-TCM injection window is a plusarg because it is workload
// specific.  A fault dropped into an instruction that has already run
// -- register initialisation, say -- is invisible by construction and
// would pad the silent count with faults that never had a chance to do
// anything.  Each workload passes the word range of its live code.
//
// +MAXCYCLE is the give-up point for a workload that never finishes.
// It was 400 000, about ninety times the length of any of the
// workloads, which cost nothing until a run actually hung: at roughly
// three thousand cycles a second a hung run took two minutes of wall
// clock on its own, and several at once under a parallel campaign blew
// through the driver's subprocess timeout.  Ten times the workload
// length is ample -- a core that has not finished by then is not going
// to.
//
//   +HEX= +DHEX= +TARGET= +BIT= +CYCLE= +GOLDEN= +IBASE= +ISPAN= +MAXCYCLE=

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
  int unsigned target, bitpos, injcycle, cycle, ibase, ispan, maxcycle;
  logic [31:0] golden;
  bit          injected, arm;
  int unsigned idx, b32, b39;
  logic [31:0] status_at_end;
  logic [31:0] cfg_safety, cfg_wdog, cfg_csr;

  initial begin
    fetch_enable = 1'b0;
    cycle = 0;
    injected = 1'b0;
    if (!$value$plusargs("HEX=%s", hexfile)) $fatal(1);
    if (!$value$plusargs("TARGET=%d", target))   target   = 0;
    if (!$value$plusargs("BIT=%d", bitpos))      bitpos   = 0;
    if (!$value$plusargs("CYCLE=%d", injcycle))  injcycle = 500;
    if (!$value$plusargs("GOLDEN=%h", golden))   golden   = 32'b0;
    if (!$value$plusargs("MAXCYCLE=%d", maxcycle)) maxcycle = 50000;
    if (!$value$plusargs("IBASE=%d", ibase))     ibase    = 40;
    if (!$value$plusargs("ISPAN=%d", ispan))     ispan    = 45;
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

      if (exit_seen || (cycle > maxcycle)) begin
        status_at_end = dut.u_safety.status_q;
        // `inj` says whether the deposit actually happened.  An
        // injection scheduled past the end of the workload never
        // happens, and without this it would be indistinguishable from
        // a fault the design tolerated -- it would land in the silent
        // count and quietly flatter the result.
        // The configuration a fault can quietly destroy.  A workload
        // finishing with the right answer says nothing about whether
        // the safety controller is still armed, and "silent-ok" is a
        // badly wrong label for a run that ended with a detector
        // switched off.  These three words are compared against a
        // fault-free run so that case can be named.
        cfg_safety = dut.u_safety.enable_q ^ dut.u_safety.react_irq_q
                   ^ dut.u_safety.react_rst_q ^ {31'b0, dut.u_safety.ctrl_en_q};
        cfg_wdog   = {30'b0, dut.u_wdog.enable_q, dut.u_wdog.rst_en_q}
                   ^ dut.u_wdog.period_q;
        cfg_csr    = dut.g_lockstep.u_core.u_core_main.u_csr.mtvec_q;
        $display("FI target=%0d bit=%0d cycle=%0d exit=%08x golden=%08x exited=%0d status=%08x inj=%0d cfg=%08x_%08x_%08x",
                 target, bitpos, injcycle, exit_code, golden, exit_seen, status_at_end,
                 injected, cfg_safety, cfg_wdog, cfg_csr);
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
  // +TRACE prints the value either side of the deposit.  Without it
  // there is no way to tell a fault that was tolerated from a fault
  // that never landed, and those two look identical in the results.
  bit trace_on;
  initial trace_on = $test$plusargs("TRACE");

  always @(negedge clk) begin
    if (rst_n && arm && !injected) begin
      injected = 1'b1;
      arm      = 1'b0;
      if (trace_on && (target % 9) == 3)
        $display("TRACE mepc before=%08x", dut.g_lockstep.u_core.u_core_main.u_csr.mepc_q);
      if (trace_on && (target % 9) == 4)
        $display("TRACE mie before=%0d mpie=%0d",
                 dut.g_lockstep.u_core.u_core_main.u_csr.mstatus_mie_q,
                 dut.g_lockstep.u_core.u_core_main.u_csr.mstatus_mpie_q);
        // Deposits are written as a whole-word XOR with a computed
        // mask rather than a variable bit-select on the left hand
        // side, which not every simulator accepts as an lvalue.
        idx   = bitpos % 31;
        b32   = bitpos % 32;
        b39   = bitpos % 39;
        case (target % 20)
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
          // area the workload reads and writes at 0x10000800.  The
          // I-TCM window comes in as +IBASE/+ISPAN, see the header.
          6: dut.u_itcm.mem[ibase + ((bitpos * 7) % ispan)] =
             dut.u_itcm.mem[ibase + ((bitpos * 7) % ispan)] ^ (39'b1 << b39);
          7: dut.u_dtcm.mem[512 + (bitpos % 4)] =
             dut.u_dtcm.mem[512 + (bitpos % 4)] ^ (39'b1 << b39);
          8: dut.g_lockstep.u_core.u_core_main.u_regfile.par_q =
             dut.g_lockstep.u_core.u_core_main.u_regfile.par_q ^ (31'b1 << idx);

          // ---- the safety controller's own configuration -----------
          // The safety manual already lists these as unprotected, and
          // that entry was written from reading the RTL rather than
          // from measuring anything.  An upset in enable_q or ctrl_en_q
          // does not corrupt a result: it switches a detector off, and
          // the workload then finishes perfectly while the mechanism
          // that was meant to be watching is gone.  A campaign that
          // only injects into datapath state cannot see that at all.
          9:  dut.u_safety.status_q    = dut.u_safety.status_q    ^ (32'b1 << b32);
          10: dut.u_safety.enable_q    = dut.u_safety.enable_q    ^ (32'b1 << b32);
          11: dut.u_safety.react_irq_q = dut.u_safety.react_irq_q ^ (32'b1 << b32);
          12: dut.u_safety.react_rst_q = dut.u_safety.react_rst_q ^ (32'b1 << b32);
          13: dut.u_safety.ctrl_en_q   = ~dut.u_safety.ctrl_en_q;

          // ---- the watchdog -----------------------------------------
          14: dut.u_wdog.count_q  = dut.u_wdog.count_q ^ (32'b1 << b32);
          15: dut.u_wdog.enable_q = ~dut.u_wdog.enable_q;

          // ---- more core state -------------------------------------
          16: dut.g_lockstep.u_core.u_core_main.u_csr.mtvec_q =
              dut.g_lockstep.u_core.u_core_main.u_csr.mtvec_q ^ (32'b1 << b32);
          17: dut.g_lockstep.u_core.u_core_main.u_csr.mscratch_q =
              dut.g_lockstep.u_core.u_core_main.u_csr.mscratch_q ^ (32'b1 << b32);
          // A bit-select rather than a whole-word XOR: state_q is an
          // enum, and assigning an integer expression to it needs an
          // explicit cast that would have to name a type declared
          // inside the module.
          18: dut.g_lockstep.u_core.u_core_main.state_q[bitpos % 2] =
              ~dut.g_lockstep.u_core.u_core_main.state_q[bitpos % 2];

          // ---- the lockstep delay pipeline --------------------------
          // The comparator's own storage.  If an upset here is silent,
          // the comparison it feeds is worth less than it looks.
          // Stage 0 only: Icarus will not take a variable index on the
          // outer dimension of a packed array in an lvalue.  One stage
          // of the pipeline is representative of all of them.
          19: dut.g_lockstep.u_core.g_delay.out_pipe_q[0][b32] =
              ~dut.g_lockstep.u_core.g_delay.out_pipe_q[0][b32];

          default: ;
        endcase
      if (trace_on && (target % 9) == 3)
        $display("TRACE mepc after =%08x", dut.g_lockstep.u_core.u_core_main.u_csr.mepc_q);
      if (trace_on && (target % 9) == 4)
        $display("TRACE mie after =%0d",
                 dut.g_lockstep.u_core.u_core_main.u_csr.mstatus_mie_q);
    end
  end

endmodule