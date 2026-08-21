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

  // safety controller fault bit positions (see doc/register_map.md)
  localparam int FLT_RF_PARITY = 5;
  localparam int FLT_BIST      = 9;

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
    // This check has now been wrong twice in opposite directions, and
    // the second time is the more instructive.
    //
    // It first asserted that detection *did* happen, and passed at 2
    // cycles.  That was luck: V2-P1 moved the timing, the corrupted
    // register stopped being one the program went on to read, and the
    // same injection went undetected for 20 000 cycles.  So it was
    // rewritten to assert the opposite -- that detection does *not*
    // happen.  Then two checks were added to safety_test.S, the
    // injection landed on a register the program reads almost
    // immediately, and detection came back at 14 cycles.
    //
    // Both versions were asserting an accident.  What is actually
    // invariant is neither outcome but the *mechanism*: the register
    // write port is not in the compare vector, so detection can only be
    // indirect -- it waits for the wrong value to reach an address, a
    // branch or a store.  Sometimes that is fourteen cycles, sometimes
    // it is never, and which one you get depends on the program.
    //
    // So the assertion is that detection is not immediate.  A direct
    // comparison of the write port would flag the corruption in the
    // cycle it happens or the one after; anything slower is indirect by
    // definition, and a workload where it never happens at all is the
    // same finding in its worst form.
    //
    // If rd_addr and rf_wdata are added to the compare vector, latency
    // drops to 0 or 1 and this check fails -- correctly -- and should
    // then be rewritten to assert prompt detection instead.
    do_reset();
    // Inject during the workload's register initialisation, which is
    // the one stretch where the register file is written every cycle
    // and the software has not yet provoked any fault of its own.
    // Waiting 200 cycles instead put this on top of safety_test.S's own
    // lockstep self-test, whose mismatch re-set status[0] as fast as
    // the bench could clear it.
    repeat (40) @(posedge clk);
    // Start from a known-clean status.  Without this the measurement
    // silently depends on what the *software* happens to be doing 200
    // cycles in: adding two checks to safety_test.S moved its lockstep
    // self-test under this window, status[0] was already set before the
    // corruption was injected, and the check reported detection "after
    // 1 cycle" that had nothing to do with the corruption.  A
    // characterisation test that measures the previous test's leftovers
    // is worse than no measurement.
    dut.u_safety.status_q = 32'b0;
    @(posedge clk);
    if (dut.u_safety.status_q[0] !== 1'b0) begin
      $display("[tb_safety] FAIL: could not clear the safety status before injecting");
      errors++;
    end
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
    if (dut.u_safety.status_q[0] === 1'b1)
      $display("[tb_safety] characterisation: corrupted register write detected indirectly after %0d cycles (V4-F3)",
               latency);
    else
      $display("[tb_safety] characterisation: corrupted register write still undetected after %0d cycles (V4-F3)",
               latency);
    report("lockstep: corrupted register write is not detected directly (V4-F3)",
           (dut.u_safety.status_q[0] === 1'b0) || (latency >= 2),
           $sformatf("detected in %0d cycles -- that is direct comparison, so the write port must now be in the compare vector",
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

    // The three checks below exist because the functional coverage
    // model (objective O7) reported their cover points as never hit.
    // Each is a safety mechanism that no software test could provoke:
    // software cannot corrupt its own register file parity, cannot make
    // a passing BIST fail, and cannot watch the reset it is about to be
    // given.  They are mechanism tests -- does the fault reach the
    // safety controller at all -- not fault characterisations, which is
    // why they use a held `force` rather than the single cycle deposit
    // the injection campaign uses.

    // ---- 8: register file parity ------------------------------------
    do_reset();
    repeat (80) @(posedge clk);
    dut.u_safety.status_q = 32'b0;
    @(posedge clk);
    // t0 is written and read constantly by the workload.  The parity
    // bit is held wrong rather than flipped once, so that a rewrite of
    // the register cannot repair it before any read observes it.
    force dut.g_lockstep.u_core.u_core_main.u_regfile.par_q[5] =
          ~dut.g_lockstep.u_core.u_core_main.u_regfile.par_q[5];
    latency = 0;
    fork : wait_par
      begin
        while (dut.u_safety.status_q[FLT_RF_PARITY] !== 1'b1) begin
          @(posedge clk);
          latency++;
        end
      end
      begin repeat (2000) @(posedge clk); end
    join_any
    disable wait_par;
    release dut.g_lockstep.u_core.u_core_main.u_regfile.par_q[5];
    report("register file: a bad parity bit reaches the safety controller",
           (dut.u_safety.status_q[FLT_RF_PARITY] === 1'b1),
           $sformatf("no parity fault after %0d cycles", latency));

    // ---- 9: memory BIST reporting a failure -------------------------
    // The BIST compares what it reads against the pattern it wrote.
    // Holding its read data wrong is the one way to make a healthy
    // memory look faulty, and it is the only path by which fail_q and
    // the BIST fault bit can ever be exercised.
    do_reset();
    repeat (80) @(posedge clk);         // let the software arm the safety controller
    dut.u_safety.status_q = 32'b0;
    force dut.u_mbist_d.bist_rdata_i = 39'h55_5555_5555;
    @(negedge clk);
    dut.u_mbist_d.start_q = 1'b1;
    latency = 0;
    fork : wait_bist
      begin
        while (dut.u_mbist_d.fail_q !== 1'b1) begin
          @(posedge clk);
          latency++;
        end
      end
      begin repeat (5000) @(posedge clk); end
    join_any
    disable wait_bist;
    release dut.u_mbist_d.bist_rdata_i;
    report("memory BIST: a mismatch is latched and reported",
           (dut.u_mbist_d.fail_q === 1'b1),
           $sformatf("BIST did not fail after %0d cycles", latency));

    // V0-F1: the *whole* 39-bit code word has to be captured, not just
    // the data half, or the check bits the new FAILDATH register
    // returns would be meaningless.  The forced read data is
    // 39'h55_5555_5555, so the check bits are its top seven.
    report("memory BIST: the failing word is captured with its check bits",
           (dut.u_mbist_d.fail_data_q === 39'h55_5555_5555),
           $sformatf("fail_data_q = %010x", dut.u_mbist_d.fail_data_q));

    // The fault is `done && fail`, not `fail`: a failing BIST runs to
    // completion and reports at the end rather than stopping at the
    // first bad word.  So the wait here is for the whole march to
    // finish, which is why it is long.  The read data is released above
    // -- the rest of the memory is healthy and the sticky fail bit is
    // what carries the result to the end.
    fork : wait_bist_done
      begin while (dut.u_mbist_d.done_o !== 1'b1) @(posedge clk); end
      begin repeat (400000) @(posedge clk); end
    join_any
    disable wait_bist_done;
    // status_q latches on the edge *after* the fault input asserts, so
    // sampling it in the cycle the wait loop exits reads it one cycle
    // early -- which is how this check first reported a clean status
    // with done and fail both set.
    repeat (5) @(posedge clk);
    report("memory BIST: the failure reaches the safety controller",
           (dut.u_safety.status_q[FLT_BIST] === 1'b1),
           $sformatf("done=%0b fail=%0b safety status = %08x",
                     dut.u_mbist_d.done_o, dut.u_mbist_d.fail_q,
                     dut.u_safety.status_q));

    // ---- 10: watchdog requesting a reset ----------------------------
    // reset_req_o is a pulse and it resets the core that would
    // otherwise be observing it, which is exactly why software cannot
    // test this and the bench must.
    do_reset();
    repeat (20) @(posedge clk);
    force dut.u_wdog.period_q = 32'd40;
    force dut.u_wdog.rst_en_q = 1'b1;
    force dut.u_wdog.enable_q = 1'b1;
    // count_q resets to 0xffff_ffff, so enabling the watchdog and
    // waiting is a four billion cycle proposition.  Deposit a small
    // count and let it run down from there; the reload from period_q
    // only happens after the first time-out.
    @(negedge clk);
    dut.u_wdog.count_q = 32'd6;
    latency = 0;
    fork : wait_wdog
      begin
        while (dut.u_wdog.reset_req_o !== 1'b1) begin
          @(posedge clk);
          latency++;
        end
      end
      begin repeat (2000) @(posedge clk); end
    join_any
    disable wait_wdog;
    report("watchdog: a time-out with reset enabled requests a reset",
           (dut.u_wdog.reset_req_o === 1'b1),
           $sformatf("no reset request after %0d cycles", latency));
    release dut.u_wdog.period_q;
    release dut.u_wdog.rst_en_q;
    release dut.u_wdog.enable_q;

    if (errors == 0) $display("[tb_safety] PASS: %0d checks", checks);
    else             $display("[tb_safety] FAIL: %0d of %0d checks", errors, checks);
    $finish;
  end

endmodule
