// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s -- control and status registers (machine mode only).
//
// Implements the M-mode subset of the privileged specification that a
// bare-metal safety application needs, plus two custom safety CSRs:
//
//   mafestat (0x7c0)  sticky core-local fault status, write-1-to-clear
//   msafectrl(0x7c1)  core-local safety control
//
// STATUS: verified to the O1-O7 gate of doc/verification_plan.md
//         (2026-08-24) -- may be used in a project.  O8-O9 and the
//         FMEDA are open: NOT qualified for safety-critical use.

`default_nettype none

module cdriscv_csr
  import cdriscv_pkg::*;
#(
    parameter logic [31:0] HartId    = 32'h0000_0000,
    parameter logic [31:0] MVendorId = 32'h0000_0000,
    parameter logic [31:0] MArchId   = 32'h0000_0000,
    parameter logic [31:0] MImpId    = 32'h0000_0001
)(
    input  logic        clk_i,
    input  logic        rst_ni,

    // CSR access from the instruction stream
    input  logic        access_i,
    input  csr_op_e     op_i,
    input  logic [11:0] addr_i,
    input  logic [31:0] wdata_i,
    input  logic        rd_is_x0_i,      // CSRRW with rd == x0: no read side effect
    input  logic        rs1_is_x0_i,     // CSRRS/C with rs1 == x0: no write
    output logic [31:0] rdata_o,
    output logic        illegal_o,
    input  logic        commit_i,        // the access actually commits this cycle

    // trap interface
    input  logic        trap_i,          // take a trap this cycle
    input  logic        trap_is_irq_i,
    input  logic [4:0]  trap_cause_i,
    input  logic [31:0] trap_pc_i,       // PC to return to
    input  logic [31:0] trap_val_i,      // mtval payload
    input  logic        mret_i,

    // interrupt inputs (level, already synchronised)
    input  logic        irq_soft_i,
    input  logic        irq_timer_i,
    input  logic        irq_ext_i,

    // core-local safety events (single-cycle pulses)
    input  logic        evt_rf_par_err_i,
    input  logic        evt_illegal_i,
    input  logic        evt_bus_err_i,
    input  logic        evt_lockstep_i,

    // retire strobe for minstret
    input  logic        instr_retired_i,

    // outputs to the core
    output logic [31:0] mtvec_o,
    output logic        cfg_err_o,       // level: mtvec parity mismatch
    output logic [31:0] mepc_o,
    output logic        irq_pending_o,
    output logic        irq_wake_o,      // any enabled interrupt pending (ignores mstatus.MIE)
    output logic [4:0]  irq_cause_o,
    output logic        mstatus_mie_o,

    // outputs to the subsystem
    output logic        sw_fault_o,      // software-triggered safety fault
    output logic        fault_out_en_o
);

  // ------------------------------------------------------------------
  // Registers
  // ------------------------------------------------------------------
  logic        mstatus_mie_q, mstatus_mpie_q;
  logic [31:0] mie_q;
  logic [31:0] mtvec_q;
  logic [31:0] mscratch_q;
  logic [31:0] mepc_q;
  logic        mcause_irq_q;
  logic [4:0]  mcause_code_q;
  logic [31:0] mtval_q;
  logic [63:0] mcycle_q;
  logic [63:0] minstret_q;
  logic [31:0] msafestat_q;
  logic [31:0] msafectrl_q;

  // ------------------------------------------------------------------
  // Interrupt pending / enable
  // ------------------------------------------------------------------
  logic [31:0] mip;

  always_comb begin
    mip                  = 32'b0;
    mip[IRQ_M_SOFT]      = irq_soft_i;
    mip[IRQ_M_TIMER]     = irq_timer_i;
    mip[IRQ_M_EXT]       = irq_ext_i;
  end

  logic [31:0] irq_active;
  assign irq_active = mip & mie_q;

  // WFI wakes on any enabled interrupt, whether or not mstatus.MIE is set.
  assign irq_wake_o = |irq_active;

  // Priority per the privileged spec: external, software, timer.
  always_comb begin
    irq_pending_o = 1'b0;
    irq_cause_o   = IRQ_M_EXT;
    if (mstatus_mie_q) begin
      if (irq_active[IRQ_M_EXT]) begin
        irq_pending_o = 1'b1;
        irq_cause_o   = IRQ_M_EXT;
      end else if (irq_active[IRQ_M_SOFT]) begin
        irq_pending_o = 1'b1;
        irq_cause_o   = IRQ_M_SOFT;
      end else if (irq_active[IRQ_M_TIMER]) begin
        irq_pending_o = 1'b1;
        irq_cause_o   = IRQ_M_TIMER;
      end
    end
  end

  // ------------------------------------------------------------------
  // misa: RV32IM with Zicsr/Zifencei (not separately encoded)
  // ------------------------------------------------------------------
  // MXL = 1 (32 bit), extension bits I (bit 8) and M (bit 12)
  localparam logic [31:0] MISA_VALUE = {2'b01, 4'b0, 26'h000_1100};

  // ------------------------------------------------------------------
  // Read
  // ------------------------------------------------------------------
  logic [31:0] mstatus_rd;
  assign mstatus_rd = {19'b0, 2'b11 /*MPP*/, 3'b0, mstatus_mpie_q, 3'b0, mstatus_mie_q, 3'b0};

  logic read_illegal;

  always_comb begin
    rdata_o      = 32'b0;
    read_illegal = 1'b0;
    unique case (addr_i)
      CSR_MSTATUS:   rdata_o = mstatus_rd;
      CSR_MISA:      rdata_o = MISA_VALUE;
      CSR_MIE:       rdata_o = mie_q;
      CSR_MTVEC:     rdata_o = mtvec_q;
      CSR_MSCRATCH:  rdata_o = mscratch_q;
      CSR_MEPC:      rdata_o = mepc_q;
      CSR_MCAUSE:    rdata_o = {mcause_irq_q, 26'b0, mcause_code_q};
      CSR_MTVAL:     rdata_o = mtval_q;
      CSR_MIP:       rdata_o = mip;
      CSR_MCYCLE,
      CSR_CYCLE:     rdata_o = mcycle_q[31:0];
      CSR_MCYCLEH,
      CSR_CYCLEH:    rdata_o = mcycle_q[63:32];
      CSR_MINSTRET,
      CSR_INSTRET:   rdata_o = minstret_q[31:0];
      CSR_MINSTRETH,
      CSR_INSTRETH:  rdata_o = minstret_q[63:32];
      CSR_MVENDORID: rdata_o = MVendorId;
      CSR_MARCHID:   rdata_o = MArchId;
      CSR_MIMPID:    rdata_o = MImpId;
      CSR_MHARTID:   rdata_o = HartId;
      CSR_MSAFESTAT: rdata_o = msafestat_q;
      CSR_MSAFECTRL: rdata_o = msafectrl_q;
      default:       read_illegal = 1'b1;
    endcase
  end

  // ------------------------------------------------------------------
  // Write value and legality
  // ------------------------------------------------------------------
  logic        csr_we;
  logic [31:0] csr_wdata;

  always_comb begin
    unique case (op_i)
      CSR_RW:  csr_wdata = wdata_i;
      CSR_RS:  csr_wdata = rdata_o |  wdata_i;
      CSR_RC:  csr_wdata = rdata_o & ~wdata_i;
      default: csr_wdata = rdata_o;
    endcase
  end

  logic write_requested;
  always_comb begin
    unique case (op_i)
      CSR_RW:       write_requested = 1'b1;
      CSR_RS,
      CSR_RC:       write_requested = ~rs1_is_x0_i;
      default:      write_requested = 1'b0;
    endcase
  end

  // read-only CSRs have addr[11:10] == 11
  logic write_to_ro;
  assign write_to_ro = write_requested && (addr_i[11:10] == 2'b11);

  assign illegal_o = access_i && (read_illegal || write_to_ro);
  assign csr_we    = access_i && commit_i && write_requested && !illegal_o;

  // rd_is_x0_i is unused for legality (none of the implemented CSRs has
  // a read side effect) but is kept on the interface so that a future
  // CSR with one can use it.
  logic unused_rd_is_x0;
  assign unused_rd_is_x0 = rd_is_x0_i;

  // ------------------------------------------------------------------
  // Update
  // ------------------------------------------------------------------
  logic [31:0] safety_evt;
  always_comb begin
    safety_evt                 = 32'b0;
    safety_evt[0]              = evt_rf_par_err_i;
    safety_evt[1]              = evt_illegal_i;
    safety_evt[2]              = evt_bus_err_i;
    safety_evt[3]              = evt_lockstep_i;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mstatus_mie_q  <= 1'b0;
      mstatus_mpie_q <= 1'b0;
      mie_q          <= 32'b0;
      mtvec_q        <= 32'b0;
      mscratch_q     <= 32'b0;
      mepc_q         <= 32'b0;
      mcause_irq_q   <= 1'b0;
      mcause_code_q  <= 5'b0;
      mtval_q        <= 32'b0;
      msafestat_q    <= 32'b0;
      msafectrl_q    <= 32'b0;
    end else begin
      // hardware counters
      // sticky safety status
      msafestat_q <= msafestat_q | safety_evt;

      // software writes
      if (csr_we) begin
        unique case (addr_i)
          CSR_MSTATUS: begin
            mstatus_mie_q  <= csr_wdata[3];
            mstatus_mpie_q <= csr_wdata[7];
          end
          CSR_MIE:       mie_q         <= csr_wdata & 32'h0000_0888;  // MSI/MTI/MEI only
          CSR_MTVEC:     mtvec_q       <= {csr_wdata[31:2], 1'b0, csr_wdata[0]};
          CSR_MSCRATCH:  mscratch_q    <= csr_wdata;
          CSR_MEPC:      mepc_q        <= {csr_wdata[31:2], 2'b00};
          CSR_MCAUSE: begin
            mcause_irq_q  <= csr_wdata[31];
            mcause_code_q <= csr_wdata[4:0];
          end
          CSR_MTVAL:     mtval_q       <= csr_wdata;
          CSR_MSAFESTAT: msafestat_q   <= (msafestat_q & ~csr_wdata) | safety_evt;  // W1C
          default: ;
        endcase
      end

      // msafectrl: bit 1 is a self-clearing software fault trigger, so
      // the register is updated outside the case above.
      msafectrl_q <= 32'b0;
      msafectrl_q[0] <= (csr_we && (addr_i == CSR_MSAFECTRL)) ? csr_wdata[0] : msafectrl_q[0];
      msafectrl_q[1] <= csr_we && (addr_i == CSR_MSAFECTRL) && csr_wdata[1];

      // trap entry wins over a software write in the same cycle: a trap
      // only ever happens on an instruction that does not commit.
      if (trap_i) begin
        mstatus_mpie_q <= mstatus_mie_q;
        mstatus_mie_q  <= 1'b0;
        mepc_q         <= {trap_pc_i[31:2], 2'b00};
        mcause_irq_q   <= trap_is_irq_i;
        mcause_code_q  <= trap_cause_i;
        mtval_q        <= trap_val_i;
      end else if (mret_i) begin
        mstatus_mie_q  <= mstatus_mpie_q;
        mstatus_mpie_q <= 1'b1;
      end
    end
  end

  assign mtvec_o        = mtvec_q;
  assign mepc_o         = mepc_q;
  assign mstatus_mie_o  = mstatus_mie_q;
  assign sw_fault_o     = msafectrl_q[1];
  assign fault_out_en_o = msafectrl_q[0];

  // ------------------------------------------------------------------
  // Hardware counters (V38): 64-bit in 16-bit segments with predicted
  // carries, because a flat 64-bit increment was the subsystem's
  // critical path.  Software writes win over the increment, per half,
  // exactly as the flat form behaved.
  // ------------------------------------------------------------------
  cdriscv_counter64 u_mcycle (
      .clk_i   (clk_i),
      .rst_ni  (rst_ni),
      .inc_i   (1'b1),
      .wr_lo_i (csr_we && (addr_i == CSR_MCYCLE)),
      .wr_hi_i (csr_we && (addr_i == CSR_MCYCLEH)),
      .wdata_i (csr_wdata),
      .q_o     (mcycle_q)
  );

  cdriscv_counter64 u_minstret (
      .clk_i   (clk_i),
      .rst_ni  (rst_ni),
      .inc_i   (instr_retired_i),
      .wr_lo_i (csr_we && (addr_i == CSR_MINSTRET)),
      .wr_hi_i (csr_we && (addr_i == CSR_MINSTRETH)),
      .wdata_i (csr_wdata),
      .q_o     (minstret_q)
  );

  // ------------------------------------------------------------------
  // Configuration parity (V29): mtvec.  92/92 latent in the campaign --
  // a flipped trap vector is invisible until the trap that needs it.
  // mtvec changes only on a committed CSR write, so the capture strobe
  // is exact.  The other CSRs the hardware itself updates on traps
  // (mstatus, mepc, mcause) cannot use this scheme and are covered by
  // lockstep at the point of use.
  // ------------------------------------------------------------------
  cdriscv_cfg_parity #(.Width(32)) u_cfg_par (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .cfg_i  (mtvec_q),
      .wr_i   (csr_we && (addr_i == CSR_MTVEC)),
      .err_o  (cfg_err_o)
  );

endmodule
