// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-10 -- RV32IM_Zicsr_Zifencei core, machine mode only.
//
// Two stages: fetch (cdriscv_if_stage) and a combined
// decode/execute/memory/writeback stage driven by the small FSM below.
// Exactly one instruction is in the execute stage at any time, so there
// are no hazards to forward and no speculative state to unwind -- the
// structure a safety analysis (FMEDA) has to reason about stays small
// and every instruction has a bounded, statically known latency.
//
// STATUS: verified to the O1-O7 gate of doc/verification_plan.md
//         (2026-08-24) -- may be used in a project.  O8-O9 and the
//         FMEDA are open: NOT qualified for safety-critical use.

`default_nettype none

module cdriscv_core
  import cdriscv_pkg::*;
#(
    parameter bit          RV32M     = 1'b1,
    parameter bit          RfParity  = 1'b1,
    parameter logic [31:0] HartId    = 32'h0000_0000,
    parameter logic [31:0] MVendorId = 32'h0000_0000,
    parameter logic [31:0] MArchId   = 32'h0000_0000,
    parameter logic [31:0] MImpId    = 32'h0000_0001
)(
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic [31:0] boot_addr_i,
    input  logic        fetch_enable_i,

    // instruction memory interface (OBI-like)
    output logic        instr_req_o,
    input  logic        instr_gnt_i,
    input  logic        instr_rvalid_i,
    output logic [31:0] instr_addr_o,
    input  logic [31:0] instr_rdata_i,
    input  logic        instr_err_i,

    // data memory interface (OBI-like)
    output logic        data_req_o,
    input  logic        data_gnt_i,
    input  logic        data_rvalid_i,
    output logic        data_we_o,
    output logic [3:0]  data_be_o,
    output logic [31:0] data_addr_o,
    output logic [31:0] data_wdata_o,
    input  logic [31:0] data_rdata_i,
    input  logic        data_err_i,

    // interrupts (level sensitive, synchronous to clk_i)
    input  logic        irq_soft_i,
    input  logic        irq_timer_i,
    input  logic        irq_ext_i,

    // safety
    output logic        fault_rf_par_o,
    output logic        fault_illegal_o,
    output logic        fault_bus_err_o,
    output logic        fault_sw_o,
    output logic        fault_out_en_o,
    output logic        fault_cfg_par_o,

    // status / trace (also used by the lockstep comparator)
    output logic        core_sleep_o,
    output logic        retire_valid_o,
    output logic [31:0] retire_pc_o,
    output logic [31:0] retire_instr_o
);

  // ------------------------------------------------------------------
  // Fetch stage
  // ------------------------------------------------------------------
  logic        instr_valid;
  logic [31:0] instr_rdata;
  logic [31:0] instr_pc;
  logic        instr_err;
  logic        instr_ready;

  logic        redirect;
  logic [31:0] redirect_pc;

  cdriscv_if_stage u_if (
      .clk_i          (clk_i),
      .rst_ni         (rst_ni),
      .boot_addr_i    (boot_addr_i),
      .fetch_en_i     (fetch_enable_i),
      .redirect_i     (redirect),
      .redirect_pc_i  (redirect_pc),
      .instr_valid_o  (instr_valid),
      .instr_rdata_o  (instr_rdata),
      .instr_pc_o     (instr_pc),
      .instr_err_o    (instr_err),
      .instr_ready_i  (instr_ready),
      .instr_req_o    (instr_req_o),
      .instr_gnt_i    (instr_gnt_i),
      .instr_rvalid_i (instr_rvalid_i),
      .instr_addr_o   (instr_addr_o),
      .instr_rdata_i  (instr_rdata_i),
      .instr_err_i    (instr_err_i)
  );

  // ------------------------------------------------------------------
  // Decode
  // ------------------------------------------------------------------
  logic [4:0]  rs1_addr, rs2_addr, rd_addr;
  logic        rf_we_dec, rs1_used, rs2_used;
  alu_op_e     alu_op;
  op_a_sel_e   op_a_sel;
  op_b_sel_e   op_b_sel;
  logic [31:0] imm;
  wb_sel_e     wb_sel;
  logic        md_req_dec;
  md_op_e      md_op;
  logic        lsu_req_dec, lsu_we, lsu_sign_ext;
  logic [1:0]  lsu_size;
  logic        branch_dec, jump_dec, jalr_dec;
  logic        csr_access_dec, csr_imm_sel;
  csr_op_e     csr_op;
  logic [11:0] csr_addr;
  logic        ecall, ebreak, mret, wfi, fence, fencei;
  logic        illegal_instr_dec;

  cdriscv_decoder #(
      .RV32M (RV32M)
  ) u_decoder (
      .instr_i         (instr_rdata),
      .rs1_addr_o      (rs1_addr),
      .rs2_addr_o      (rs2_addr),
      .rd_addr_o       (rd_addr),
      .rf_we_o         (rf_we_dec),
      .rs1_used_o      (rs1_used),
      .rs2_used_o      (rs2_used),
      .alu_op_o        (alu_op),
      .op_a_sel_o      (op_a_sel),
      .op_b_sel_o      (op_b_sel),
      .imm_o           (imm),
      .wb_sel_o        (wb_sel),
      .md_req_o        (md_req_dec),
      .md_op_o         (md_op),
      .lsu_req_o       (lsu_req_dec),
      .lsu_we_o        (lsu_we),
      .lsu_size_o      (lsu_size),
      .lsu_sign_ext_o  (lsu_sign_ext),
      .branch_o        (branch_dec),
      .jump_o          (jump_dec),
      .jalr_o          (jalr_dec),
      .csr_access_o    (csr_access_dec),
      .csr_op_o        (csr_op),
      .csr_addr_o      (csr_addr),
      .csr_imm_o       (csr_imm_sel),
      .ecall_o         (ecall),
      .ebreak_o        (ebreak),
      .mret_o          (mret),
      .wfi_o           (wfi),
      .fence_o         (fence),
      .fencei_o        (fencei),
      .illegal_instr_o (illegal_instr_dec)
  );

  // ------------------------------------------------------------------
  // Register file
  // ------------------------------------------------------------------
  logic [31:0] rs1_data, rs2_data;
  logic [31:0] rf_wdata;
  logic        rf_we;
  logic        rf_par_err;

  cdriscv_regfile #(
      .ParityEn (RfParity)
  ) u_regfile (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .raddr_a_i (rs1_addr),
      .ren_a_i   (rs1_used & instr_valid),
      .rdata_a_o (rs1_data),
      .raddr_b_i (rs2_addr),
      .ren_b_i   (rs2_used & instr_valid),
      .rdata_b_o (rs2_data),
      .waddr_i   (rd_addr),
      .wdata_i   (rf_wdata),
      .we_i      (rf_we),
      .par_err_o (rf_par_err)
  );

  // ------------------------------------------------------------------
  // ALU
  // ------------------------------------------------------------------
  logic [31:0] operand_a, operand_b, alu_result;

  always_comb begin
    unique case (op_a_sel)
      OP_A_RS1:  operand_a = rs1_data;
      OP_A_PC:   operand_a = instr_pc;
      OP_A_ZERO: operand_a = 32'b0;
      default:   operand_a = rs1_data;
    endcase
  end

  always_comb begin
    unique case (op_b_sel)
      OP_B_RS2:  operand_b = rs2_data;
      OP_B_IMM:  operand_b = imm;
      OP_B_FOUR: operand_b = 32'd4;
      default:   operand_b = imm;
    endcase
  end

  cdriscv_alu u_alu (
      .operator_i  (alu_op),
      .operand_a_i (operand_a),
      .operand_b_i (operand_b),
      .result_o    (alu_result)
  );

  // Address adder for loads/stores (rs1 + imm); the ALU is busy with
  // PC + 4 for jumps and with the compare for branches.
  logic [31:0] lsu_addr;
  assign lsu_addr = rs1_data + imm;

  // ------------------------------------------------------------------
  // Multiply / divide
  // ------------------------------------------------------------------
  logic        md_req, md_busy, md_valid;
  logic [31:0] md_result;

  if (RV32M) begin : g_multdiv
    cdriscv_multdiv u_multdiv (
        .clk_i       (clk_i),
        .rst_ni      (rst_ni),
        .req_i       (md_req),
        .operator_i  (md_op),
        .operand_a_i (rs1_data),
        .operand_b_i (rs2_data),
        .kill_i      (1'b0),
        .busy_o      (md_busy),
        .valid_o     (md_valid),
        .result_o    (md_result)
    );
  end else begin : g_no_multdiv
    assign md_busy   = 1'b0;
    assign md_valid  = 1'b0;
    assign md_result = 32'b0;
  end

  // ------------------------------------------------------------------
  // Load / store unit
  // ------------------------------------------------------------------
  logic        lsu_req, lsu_busy, lsu_valid, lsu_err;
  logic [31:0] lsu_rdata;

  cdriscv_lsu u_lsu (
      .clk_i         (clk_i),
      .rst_ni        (rst_ni),
      .req_i         (lsu_req),
      .we_i          (lsu_we),
      .size_i        (lsu_size),
      .sign_ext_i    (lsu_sign_ext),
      .addr_i        (lsu_addr),
      .wdata_i       (rs2_data),
      .kill_i        (1'b0),
      .busy_o        (lsu_busy),
      .valid_o       (lsu_valid),
      .rdata_o       (lsu_rdata),
      .err_o         (lsu_err),
      .data_req_o    (data_req_o),
      .data_gnt_i    (data_gnt_i),
      .data_rvalid_i (data_rvalid_i),
      .data_we_o     (data_we_o),
      .data_be_o     (data_be_o),
      .data_addr_o   (data_addr_o),
      .data_wdata_o  (data_wdata_o),
      .data_rdata_i  (data_rdata_i),
      .data_err_i    (data_err_i)
  );

  // ------------------------------------------------------------------
  // Control FSM
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {
    ST_RUN,
    ST_WAIT_LSU,
    ST_WAIT_MD,
    ST_SLEEP
  } state_e;

  state_e state_q, state_d;

  logic instr_exec;
  assign instr_exec = instr_valid && fetch_enable_i && (state_q == ST_RUN);

  // ---- control transfer ---------------------------------------------
  logic        branch_taken, ctrl_transfer;
  logic [31:0] jump_target, branch_target, target_pc;

  assign branch_taken  = branch_dec && alu_result[0];
  assign ctrl_transfer = jump_dec || branch_taken;
  assign branch_target = instr_pc + imm;
  assign jump_target   = (rs1_data + imm) & 32'hffff_fffe;   // JALR clears bit 0
  assign target_pc     = jalr_dec ? jump_target : branch_target;

  // ---- misalignment --------------------------------------------------
  logic lsu_misalign;
  always_comb begin
    unique case (lsu_size)
      LS_WORD: lsu_misalign = (lsu_addr[1:0] != 2'b00);
      LS_HALF: lsu_misalign = (lsu_addr[0]   != 1'b0);
      default: lsu_misalign = 1'b0;
    endcase
  end

  logic instr_misalign;
  assign instr_misalign = ctrl_transfer && (target_pc[1:0] != 2'b00);

  // ---- CSR -----------------------------------------------------------
  logic [31:0] csr_rdata, csr_wdata;
  logic        csr_illegal;
  logic        csr_access;
  logic        retire;

  assign csr_access = instr_exec && csr_access_dec;
  assign csr_wdata  = csr_imm_sel ? imm : rs1_data;

  logic [31:0] mtvec, mepc;
  logic        irq_pending, irq_wake, mstatus_mie;
  logic [4:0]  irq_cause;

  // ---- exceptions ----------------------------------------------------
  logic        exc_valid;
  logic [4:0]  exc_cause;
  logic [31:0] exc_tval;

  always_comb begin
    exc_valid = 1'b0;
    exc_cause = EXC_ILLEGAL_INSTR;
    exc_tval  = 32'b0;

    if (instr_exec) begin
      if (instr_err) begin
        exc_valid = 1'b1;
        exc_cause = EXC_INSTR_FAULT;
        exc_tval  = instr_pc;
      end else if (illegal_instr_dec || csr_illegal) begin
        exc_valid = 1'b1;
        exc_cause = EXC_ILLEGAL_INSTR;
        exc_tval  = instr_rdata;
      end else if (ecall) begin
        exc_valid = 1'b1;
        exc_cause = EXC_ECALL_M;
        exc_tval  = 32'b0;
      end else if (ebreak) begin
        exc_valid = 1'b1;
        exc_cause = EXC_BREAKPOINT;
        exc_tval  = instr_pc;
      end else if (instr_misalign) begin
        exc_valid = 1'b1;
        exc_cause = EXC_INSTR_MISALIGN;
        exc_tval  = target_pc;
      end else if (lsu_req_dec && lsu_misalign) begin
        exc_valid = 1'b1;
        exc_cause = lsu_we ? EXC_STORE_MISALIGN : EXC_LOAD_MISALIGN;
        exc_tval  = lsu_addr;
      end
    end
  end

  // A bus error on a data access is reported when the response arrives.
  logic lsu_exc;
  assign lsu_exc = (state_q == ST_WAIT_LSU) && lsu_valid && lsu_err;

  // ---- trap arbitration ----------------------------------------------
  logic        take_irq, take_exc, trap_taken;
  logic [4:0]  trap_cause;
  logic        trap_is_irq;
  logic [31:0] trap_tval;

  assign take_irq = instr_exec && irq_pending;
  assign take_exc = (instr_exec && !take_irq && exc_valid) || lsu_exc;

  assign trap_taken  = take_irq || take_exc;
  assign trap_is_irq = take_irq;

  always_comb begin
    if (take_irq) begin
      trap_cause = irq_cause;
      trap_tval  = 32'b0;
    end else if (lsu_exc) begin
      trap_cause = lsu_we ? EXC_STORE_FAULT : EXC_LOAD_FAULT;
      trap_tval  = lsu_addr;
    end else begin
      trap_cause = exc_cause;
      trap_tval  = exc_tval;
    end
  end

  logic [31:0] trap_vector;
  always_comb begin
    trap_vector = {mtvec[31:2], 2'b00};
    if (mtvec[0] && trap_is_irq) begin
      trap_vector = {mtvec[31:2], 2'b00} + ({27'b0, trap_cause} << 2);
    end
  end

  // ---- start / completion of multi-cycle operations -------------------
  logic start_lsu, start_md;
  assign start_lsu = instr_exec && !take_irq && !take_exc && lsu_req_dec;
  assign start_md  = instr_exec && !take_irq && !take_exc && md_req_dec;

  assign lsu_req = start_lsu;
  assign md_req  = start_md;

  always_comb begin
    retire = 1'b0;
    unique case (state_q)
      ST_RUN:      retire = instr_exec && !take_irq && !take_exc && !start_lsu && !start_md;
      ST_WAIT_LSU: retire = lsu_valid && !lsu_err;
      ST_WAIT_MD:  retire = md_valid;
      default:     retire = 1'b0;
    endcase
  end

  // ---- FSM ------------------------------------------------------------
  always_comb begin
    state_d = state_q;
    unique case (state_q)
      ST_RUN: begin
        if (trap_taken)      state_d = ST_RUN;
        else if (start_lsu)  state_d = ST_WAIT_LSU;
        else if (start_md)   state_d = ST_WAIT_MD;
        else if (retire && wfi) state_d = ST_SLEEP;
      end
      ST_WAIT_LSU: if (lsu_valid) state_d = ST_RUN;   // error is trapped in ST_RUN terms
      ST_WAIT_MD:  if (md_valid)  state_d = ST_RUN;
      ST_SLEEP:    if (irq_wake || !fetch_enable_i) state_d = ST_RUN;
      default:     state_d = ST_RUN;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) state_q <= ST_RUN;
    else         state_q <= state_d;
  end

  // ---- redirect --------------------------------------------------------
  always_comb begin
    redirect    = 1'b0;
    redirect_pc = instr_pc + 32'd4;

    if (trap_taken) begin
      redirect    = 1'b1;
      redirect_pc = trap_vector;
    end else if (retire && (state_q == ST_RUN)) begin
      if (mret) begin
        redirect    = 1'b1;
        redirect_pc = mepc;
      end else if (ctrl_transfer) begin
        redirect    = 1'b1;
        redirect_pc = target_pc;
      end else if (fence || fencei || wfi) begin
        // FENCE.I must discard the prefetched instruction; FENCE and WFI
        // reuse the same path, which costs one refetch and keeps the
        // control logic uniform.
        redirect    = 1'b1;
        redirect_pc = instr_pc + 32'd4;
      end
    end
  end

  assign instr_ready = retire;

  // ---- write back -------------------------------------------------------
  always_comb begin
    unique case (wb_sel)
      WB_ALU: rf_wdata = alu_result;
      WB_LSU: rf_wdata = lsu_rdata;
      WB_CSR: rf_wdata = csr_rdata;
      WB_MD:  rf_wdata = md_result;
      default:rf_wdata = alu_result;
    endcase
  end

  assign rf_we = retire && rf_we_dec;

  // ------------------------------------------------------------------
  // CSR file
  // ------------------------------------------------------------------
  cdriscv_csr #(
      .HartId    (HartId),
      .MVendorId (MVendorId),
      .MArchId   (MArchId),
      .MImpId    (MImpId)
  ) u_csr (
      .clk_i            (clk_i),
      .rst_ni           (rst_ni),
      .access_i         (csr_access),
      .op_i             (csr_op),
      .addr_i           (csr_addr),
      .wdata_i          (csr_wdata),
      .rd_is_x0_i       (rd_addr  == 5'd0),
      .rs1_is_x0_i      (rs1_addr == 5'd0),
      .rdata_o          (csr_rdata),
      .illegal_o        (csr_illegal),
      .commit_i         (retire),
      .trap_i           (trap_taken),
      .trap_is_irq_i    (trap_is_irq),
      .trap_cause_i     (trap_cause),
      .trap_pc_i        (instr_pc),
      .trap_val_i       (trap_tval),
      .mret_i           (retire && mret),
      .irq_soft_i       (irq_soft_i),
      .irq_timer_i      (irq_timer_i),
      .irq_ext_i        (irq_ext_i),
      .evt_rf_par_err_i (rf_par_err),
      .evt_illegal_i    (take_exc && (trap_cause == EXC_ILLEGAL_INSTR)),
      .evt_bus_err_i    (take_exc && ((trap_cause == EXC_INSTR_FAULT) ||
                                      (trap_cause == EXC_LOAD_FAULT)  ||
                                      (trap_cause == EXC_STORE_FAULT))),
      .evt_lockstep_i   (1'b0),
      .instr_retired_i  (retire),
      .mtvec_o          (mtvec),
      .cfg_err_o        (fault_cfg_par_o),
      .mepc_o           (mepc),
      .irq_pending_o    (irq_pending),
      .irq_wake_o       (irq_wake),
      .irq_cause_o      (irq_cause),
      .mstatus_mie_o    (mstatus_mie),
      .sw_fault_o       (fault_sw_o),
      .fault_out_en_o   (fault_out_en_o)
  );

  // ------------------------------------------------------------------
  // Safety and trace outputs
  // ------------------------------------------------------------------
  assign fault_rf_par_o  = rf_par_err;
  assign fault_illegal_o = take_exc && (trap_cause == EXC_ILLEGAL_INSTR);
  assign fault_bus_err_o = take_exc && ((trap_cause == EXC_INSTR_FAULT) ||
                                        (trap_cause == EXC_LOAD_FAULT)  ||
                                        (trap_cause == EXC_STORE_FAULT));

  assign core_sleep_o   = (state_q == ST_SLEEP);
  assign retire_valid_o = retire;
  assign retire_pc_o    = instr_pc;
  assign retire_instr_o = instr_rdata;

  logic unused_ok;
  assign unused_ok = |{mstatus_mie, lsu_busy, md_busy, rf_we_dec};

endmodule
