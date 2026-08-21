// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// Safety mechanism test, bench half.
//
// Covers what software cannot reach: faults forced inside the checker
// core, and a system clock that misbehaves.  Configuration registers
// that software would normally write are forced instead, which is
// equivalent for quasi-static registers and keeps this bench
// independent of any program.
//
// Every mechanism gets a trigger case and a quiet case, because a
// mechanism wired to a constant passes a trigger-only test.
//
//   +ITCM_HEX=<file>   program image (required)

`default_nettype none
`timescale 1ns/1ps

module tb_safety;

  // ------------------------------------------------------------------
  // Clocks, with a runtime-variable system period so the clock monitor
  // can be given something to complain about
  // ------------------------------------------------------------------
  time  sys_half = 5ns;          // 10 ns period nominal
  bit   sys_run  = 1'b1;
  logic clk, rst_n, ref_clk, ref_rst_n;

  initial begin
    clk = 1'b0;
    forever begin
      #(sys_half);
      if (sys_run) clk = ~clk;
    end
  end

  initial begin
    ref_clk = 1'b0;
    forever #50ns ref_clk = ~ref_clk;   // 100 ns period
  end

  logic        fetch_enable, fault_any, err_pin, reset_req;
  logic        retire_valid;
  logic [31:0] retire_pc, retire_instr;

  cdriscv_subsys #(
      .Lockstep    (1'b1),
      .LockstepDly (2),
      .ItcmWords   (4096),
      .DtcmWords   (4096),
      .MbistAuto   (1'b0)
  ) dut (
      .clk_i          (clk),
      .rst_ni         (rst_n),
      .ref_clk_i      (ref_clk),
      .ref_rst_ni     (ref_rst_n),
      .boot_addr_i    (32'h0000_0000),
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

  int unsigned errors, checks;
  string       hexfile;

  task automatic report(input string name, input bit ok, input string detail);
    begin
      checks++;
      if (!ok) errors++;
      $display("[tb_safety] %-4s %-40s %s", ok ? "ok" : "FAIL", name, detail);
    end
  endtask

  task automatic do_reset;
    begin
      rst_n     = 1'b0;
      ref_rst_n = 1'b0;
      fetch_enable = 1'b0;
      repeat (10) @(posedge clk);
      rst_n     = 1'b1;
      ref_rst_n = 1'b1;
      repeat (5) @(posedge clk);
      fetch_enable = 1'b1;
    end
  endtask

  // ------------------------------------------------------------------
  // Scenarios
  // ------------------------------------------------------------------
  int unsigned latency;

  initial begin
    errors = 0;
    checks = 0;

    if (!$value$plusargs("ITCM_HEX=%s", hexfile)) begin
      $display("[tb_safety] ERROR: +ITCM_HEX=<file> is required");
      $fatal(1);
    end
    $readmemh(hexfile, dut.u_itcm.mem);

    do_reset();

    // ---- 1: quiet.  A healthy run must latch nothing. --------------
    repeat (2000) @(posedge clk);
    report("quiet: no fault during normal execution",
           (dut.u_safety.status_q == 32'b0),
           $sformatf("status=%08x", dut.u_safety.status_q));

    // ---- 2: a fault on a compared signal must be caught ------------
    // The fetch PC of the checker core reaches the compared instruction
    // address directly, so this is the fast path.
    @(posedge clk);
    force dut.g_lockstep.u_core.u_core_check.u_if.fetch_pc_q = 32'h0000_0abc;
    latency = 0;
    fork : wait_detect
      begin
        while (dut.u_safety.status_q[0] !== 1'b1) begin
          @(posedge clk);
          latency++;
        end
      end
      begin
        repeat (50) @(posedge clk);
      end
    join_any
    disable wait_detect;
    release dut.g_lockstep.u_core.u_core_check.u_if.fetch_pc_q;

    report("lockstep: fault on a compared signal detected",
           (dut.u_safety.status_q[0] === 1'b1),
           $sformatf("detected after %0d cycles", latency));

    // clear and let the cores resynchronise by resetting
    do_reset();
    repeat (200) @(posedge clk);

    // ---- 3: a fault on a signal that is not directly compared ------
    // CHARACTERISATION TEST.  This locks in a known weakness, and is
    // written to fail if the weakness is ever fixed.
    //
    // The compare vector carries the bus, the fault flags and the
    // retire information, but not the register file write port.  A
    // corrupted register write is therefore only detected if and when
    // the wrong value reaches an address, a branch or a store.  If the
    // register is dead, it is never detected at all.
    //
    // An earlier version of this check asserted that detection *did*
    // happen, and passed at 2 cycles.  That was luck: the fetch stage
    // change of V2-P1 moved the timing, the corrupted register stopped
    // being one the program went on to read, and the same injection now
    // goes undetected for at least 20 000 cycles.  See V4-F3.
    //
    // If rd_addr and rf_wdata are added to the lockstep compare vector,
    // this check will fail -- correctly -- and should then be rewritten
    // to assert prompt detection instead.
    do_reset();
    repeat (200) @(posedge clk);
    while (dut.g_lockstep.u_core.u_core_check.rf_we !== 1'b1) @(posedge clk);
    force dut.g_lockstep.u_core.u_core_check.rf_wdata = 32'hdead_beef;
    @(posedge clk);
    release dut.g_lockstep.u_core.u_core_check.rf_wdata;
    latency = 0;
    fork : wait_indirect
      begin
        while (dut.u_safety.status_q[0] !== 1'b1) begin
          @(posedge clk);
          latency++;
        end
      end
      begin
        repeat (20000) @(posedge clk);
      end
    join_any
    disable wait_indirect;
    report("lockstep: corrupted register write goes undetected (V4-F3)",
           (dut.u_safety.status_q[0] === 1'b0),
           $sformatf("still undetected after %0d cycles -- the register write port is not compared",
                     latency));

    // ---- 4: clock monitor, nominal ---------------------------------
    do_reset();
    // 10 ns system clock, 100 ns reference, heartbeat every 256 system
    // cycles: about 25.6 reference cycles between heartbeat edges.
    force dut.u_clkmon.min_q    = 24'd22;
    force dut.u_clkmon.max_q    = 24'd30;
    force dut.u_clkmon.enable_q = 1'b1;
    repeat (3000) @(posedge clk);
    report("clock monitor: quiet at the nominal ratio",
           (dut.u_clkmon.ref_fault_q === 1'b0),
           $sformatf("last count=%0d", dut.u_clkmon.ref_meas_q));

    // ---- 5: system clock stopped -----------------------------------
    // Detection has to happen in the reference domain: a monitor
    // clocked by the clock it watches cannot report that clock's
    // failure.  This is the case that proves it.
    sys_run = 1'b0;
    repeat (80) @(posedge ref_clk);
    report("clock monitor: stopped system clock detected",
           (dut.u_clkmon.ref_fault_q === 1'b1),
           "reference domain flagged it");
    sys_run = 1'b1;

    // ---- 6: system clock too slow ----------------------------------
    do_reset();
    force dut.u_clkmon.min_q    = 24'd22;
    force dut.u_clkmon.max_q    = 24'd30;
    force dut.u_clkmon.enable_q = 1'b1;
    sys_half = 15ns;                    // 1.5x slower
    repeat (2000) @(posedge clk);
    report("clock monitor: slow system clock detected",
           (dut.u_clkmon.ref_fault_q === 1'b1),
           $sformatf("last count=%0d", dut.u_clkmon.ref_meas_q));

    // ---- 7: system clock too fast ----------------------------------
    do_reset();
    force dut.u_clkmon.min_q    = 24'd22;
    force dut.u_clkmon.max_q    = 24'd30;
    force dut.u_clkmon.enable_q = 1'b1;
    sys_half = 2ns;                     // 2.5x faster
    repeat (3000) @(posedge clk);
    report("clock monitor: fast system clock detected",
           (dut.u_clkmon.ref_fault_q === 1'b1),
           $sformatf("last count=%0d", dut.u_clkmon.ref_meas_q));
    sys_half = 5ns;

    release dut.u_clkmon.min_q;
    release dut.u_clkmon.max_q;
    release dut.u_clkmon.enable_q;

    if (errors == 0) $display("[tb_safety] PASS: %0d checks", checks);
    else             $display("[tb_safety] FAIL: %0d of %0d checks", errors, checks);
    $finish;
  end

endmodule
