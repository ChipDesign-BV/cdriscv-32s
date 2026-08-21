// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// Functional coverage model (objective O7).
//
// Line and toggle coverage say which of the RTL ran.  They cannot say
// which *situations* were reached, and that is the question a
// verification plan is actually asking.  A design can be at 100 % line
// coverage having never taken an interrupt, never seen a bus error and
// never run a division by zero.
//
// The points below are the situations this plan claims to cover.  They
// are `cover` statements rather than covergroups because Verilator
// implements those and merges them into the same report as line and
// toggle coverage, so one flow measures all three.
//
// Everything is attached with `bind`, which is what makes the internal
// signals reachable: a bind port expression is elaborated in the scope
// of the target module, so `retire` and `trap_cause` can be sampled
// without adding a single port to the RTL.
//
// A point that stays at zero is a hole in the tests, not a defect.  The
// report in verification_findings.md lists which ones are which.

`default_nettype none

// ----------------------------------------------------------------- core
module cdriscv_core_cover (
    input logic       clk, rst_n,
    input logic       retire, instr_exec,
    input logic       branch_dec, jump_dec, jalr_dec,
    input logic       lsu_req_dec, lsu_we, lsu_sign_ext,
    input logic [1:0] lsu_size,
    input logic       md_req_dec,
    input logic       csr_access_dec,
    input logic       ecall, ebreak, mret, wfi, fence, fencei,
    input logic       illegal_instr_dec,
    input logic       trap_taken, take_irq, take_exc,
    input logic [4:0] trap_cause,
    input logic       ctrl_transfer
);
  always @(posedge clk) if (rst_n) begin
    // instruction classes actually retired
    cp_retire_branch:   cover (retire && branch_dec);
    cp_branch_taken:    cover (retire && branch_dec &&  ctrl_transfer);
    cp_branch_nottaken: cover (retire && branch_dec && !ctrl_transfer);
    cp_jal:             cover (retire && jump_dec && !jalr_dec);
    cp_jalr:            cover (retire && jalr_dec);
    cp_load:            cover (retire && lsu_req_dec && !lsu_we);
    cp_store:           cover (retire && lsu_req_dec &&  lsu_we);
    cp_muldiv:          cover (retire && md_req_dec);
    cp_csr:             cover (retire && csr_access_dec);

    // load and store at every width, and sign extension on the narrow ones
    cp_lsu_byte:        cover (retire && lsu_req_dec && lsu_size == 2'd0);
    cp_lsu_half:        cover (retire && lsu_req_dec && lsu_size == 2'd1);
    cp_lsu_word:        cover (retire && lsu_req_dec && lsu_size == 2'd2);
    cp_lsu_signed:      cover (retire && lsu_req_dec && !lsu_we && lsu_sign_ext);
    cp_lsu_unsigned:    cover (retire && lsu_req_dec && !lsu_we && !lsu_sign_ext);

    // the system instructions
    cp_ecall:           cover (instr_exec && ecall);
    cp_ebreak:          cover (instr_exec && ebreak);
    cp_mret:            cover (retire && mret);
    cp_wfi:             cover (retire && wfi);
    cp_fence:           cover (retire && fence);
    cp_fencei:          cover (retire && fencei);
    cp_illegal:         cover (instr_exec && illegal_instr_dec);

    // traps, by kind and by cause
    cp_trap:            cover (trap_taken);
    cp_trap_exc:        cover (take_exc);
    cp_trap_irq:        cover (take_irq);
    cp_cause_illegal:   cover (take_exc && trap_cause == 5'd2);
    cp_cause_break:     cover (take_exc && trap_cause == 5'd3);
    cp_cause_ld_fault:  cover (take_exc && trap_cause == 5'd5);
    cp_cause_st_fault:  cover (take_exc && trap_cause == 5'd7);
    cp_cause_ecall_m:   cover (take_exc && trap_cause == 5'd11);
    cp_irq_soft:        cover (take_irq && trap_cause == 5'd3);
    cp_irq_timer:       cover (take_irq && trap_cause == 5'd7);
    cp_irq_ext:         cover (take_irq && trap_cause == 5'd11);
  end
endmodule

bind cdriscv_core cdriscv_core_cover u_cover (
    .clk (clk_i), .rst_n (rst_ni),
    .retire (retire), .instr_exec (instr_exec),
    .branch_dec (branch_dec), .jump_dec (jump_dec), .jalr_dec (jalr_dec),
    .lsu_req_dec (lsu_req_dec), .lsu_we (lsu_we), .lsu_sign_ext (lsu_sign_ext),
    .lsu_size (lsu_size), .md_req_dec (md_req_dec),
    .csr_access_dec (csr_access_dec),
    .ecall (ecall), .ebreak (ebreak), .mret (mret), .wfi (wfi),
    .fence (fence), .fencei (fencei),
    .illegal_instr_dec (illegal_instr_dec),
    .trap_taken (trap_taken), .take_irq (take_irq), .take_exc (take_exc),
    .trap_cause (trap_cause), .ctrl_transfer (ctrl_transfer)
);

// ------------------------------------------------------------ fetch stage
module cdriscv_if_cover (
    input logic       clk, rst_n,
    input logic [1:0] occupancy,
    input logic       outstanding_q, discard_q,
    input logic       redirect_i, instr_req_o, instr_gnt_i
);
  always @(posedge clk) if (rst_n) begin
    // the fetch buffer at each depth: the deepened prefetch (V2-P1) is
    // only doing its job if the full state is actually reached
    cp_occ_empty:       cover (occupancy == 2'd0);
    cp_occ_one:         cover (occupancy == 2'd1);
    cp_occ_two:         cover (occupancy == 2'd2);
    // a redirect arriving while a fetch is in flight -- the case that
    // withdrew waiver W1
    cp_redirect_inflight: cover (redirect_i && outstanding_q);
    cp_discard_pending:   cover (discard_q);
    // memory refusing a fetch
    cp_fetch_stalled:     cover (instr_req_o && !instr_gnt_i);
  end
endmodule

bind cdriscv_if_stage cdriscv_if_cover u_cover (
    .clk (clk_i), .rst_n (rst_ni),
    .occupancy (occupancy), .outstanding_q (outstanding_q),
    .discard_q (discard_q), .redirect_i (redirect_i),
    .instr_req_o (instr_req_o), .instr_gnt_i (instr_gnt_i)
);

// ------------------------------------------------------------------ TCM
module cdriscv_tcm_cover (
    input logic clk, rst_n,
    input logic ecc_cor_o, ecc_unc_o, err_o, req_i, gnt_o, we_i
);
  always @(posedge clk) if (rst_n) begin
    cp_ecc_corrected:   cover (ecc_cor_o);
    cp_ecc_uncorrected: cover (ecc_unc_o);
    cp_tcm_error:       cover (err_o);
    cp_tcm_backpressure: cover (req_i && !gnt_o);
    cp_tcm_write:       cover (req_i && gnt_o &&  we_i);
    cp_tcm_read:        cover (req_i && gnt_o && !we_i);
  end
endmodule

bind cdriscv_tcm cdriscv_tcm_cover u_cover (
    .clk (clk_i), .rst_n (rst_ni),
    .ecc_cor_o (ecc_cor_o), .ecc_unc_o (ecc_unc_o), .err_o (err_o),
    .req_i (req_i), .gnt_o (gnt_o), .we_i (we_i)
);

// ------------------------------------------------------- safety controller
module cdriscv_safety_cover (
    input logic        clk, rst_n,
    input logic [31:0] status_q, fault_latched,
    input logic        irq_o, reset_req_o, err_pin_o
);
  always @(posedge clk) if (rst_n) begin
    // each fault source latching, one point per source, so a source
    // that no test ever provokes shows up as a hole rather than
    // hiding inside an "any fault" point
    cp_flt_lockstep:  cover (fault_latched[0]);
    cp_flt_itcm_cor:  cover (fault_latched[1]);
    cp_flt_itcm_unc:  cover (fault_latched[2]);
    cp_flt_dtcm_cor:  cover (fault_latched[3]);
    cp_flt_dtcm_unc:  cover (fault_latched[4]);
    cp_flt_rf_parity: cover (fault_latched[5]);
    cp_flt_wdog:      cover (fault_latched[6]);
    cp_flt_clkmon:    cover (fault_latched[7]);
    cp_flt_bus:       cover (fault_latched[8]);
    cp_flt_bist:      cover (fault_latched[9]);
    cp_flt_ams:       cover (fault_latched[10]);
    cp_flt_sw:        cover (fault_latched[11]);
    cp_flt_trap:      cover (fault_latched[12]);
    // and each configured reaction actually firing
    cp_react_irq:     cover (irq_o);
    cp_react_reset:   cover (reset_req_o);
    cp_react_pin:     cover (err_pin_o);
    cp_multi_fault:   cover ($countones(status_q) > 1);
  end
endmodule

bind cdriscv_safety_ctrl cdriscv_safety_cover u_cover (
    .clk (clk_i), .rst_n (rst_ni),
    .status_q (status_q), .fault_latched (fault_latched),
    .irq_o (irq_o), .reset_req_o (reset_req_o), .err_pin_o (err_pin_o)
);

// ------------------------------------------------------------- watchdog
module cdriscv_wdog_cover (
    input logic clk, rst_n,
    input logic sts_timeout_q, sts_badsvc_q, fault_o, reset_req_o
);
  always @(posedge clk) if (rst_n) begin
    cp_wdog_timeout:  cover (sts_timeout_q);
    cp_wdog_badsvc:   cover (sts_badsvc_q);
    cp_wdog_fault:    cover (fault_o);
    cp_wdog_reset:    cover (reset_req_o);
  end
endmodule

bind cdriscv_wdog cdriscv_wdog_cover u_cover (
    .clk (clk_i), .rst_n (rst_ni),
    .sts_timeout_q (sts_timeout_q), .sts_badsvc_q (sts_badsvc_q),
    .fault_o (fault_o), .reset_req_o (reset_req_o)
);

`default_nettype wire
