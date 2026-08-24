// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s -- shared types, encodings and constants.
//
// STATUS: verified to the O1-O7 gate of doc/verification_plan.md
//         (2026-08-24) -- may be used in a project.  O8-O9 and the
//         FMEDA are open: NOT qualified for safety-critical use.

package cdriscv_pkg;

  // ------------------------------------------------------------------
  // Machine parameters
  // ------------------------------------------------------------------
  localparam int unsigned XLEN = 32;

  // ------------------------------------------------------------------
  // RISC-V major opcodes (instr[6:0])
  // ------------------------------------------------------------------
  localparam logic [6:0] OPCODE_LOAD    = 7'h03;
  localparam logic [6:0] OPCODE_MISCMEM = 7'h0f;
  localparam logic [6:0] OPCODE_OPIMM   = 7'h13;
  localparam logic [6:0] OPCODE_AUIPC   = 7'h17;
  localparam logic [6:0] OPCODE_STORE   = 7'h23;
  localparam logic [6:0] OPCODE_OP      = 7'h33;
  localparam logic [6:0] OPCODE_LUI     = 7'h37;
  localparam logic [6:0] OPCODE_BRANCH  = 7'h63;
  localparam logic [6:0] OPCODE_JALR    = 7'h67;
  localparam logic [6:0] OPCODE_JAL     = 7'h6f;
  localparam logic [6:0] OPCODE_SYSTEM  = 7'h73;

  // ------------------------------------------------------------------
  // ALU operations
  // ------------------------------------------------------------------
  typedef enum logic [3:0] {
    ALU_ADD  = 4'd0,
    ALU_SUB  = 4'd1,
    ALU_SLL  = 4'd2,
    ALU_SLT  = 4'd3,
    ALU_SLTU = 4'd4,
    ALU_XOR  = 4'd5,
    ALU_SRL  = 4'd6,
    ALU_SRA  = 4'd7,
    ALU_OR   = 4'd8,
    ALU_AND  = 4'd9,
    ALU_EQ   = 4'd10,   // set if a == b   (branch compare)
    ALU_NE   = 4'd11,   // set if a != b
    ALU_GE   = 4'd12,   // set if a >= b   (signed)
    ALU_GEU  = 4'd13,   // set if a >= b   (unsigned)
    ALU_PASSB= 4'd14    // pass operand b  (LUI, CSR writes)
  } alu_op_e;

  // ------------------------------------------------------------------
  // Operand selects
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {
    OP_A_RS1  = 2'd0,
    OP_A_PC   = 2'd1,
    OP_A_ZERO = 2'd2
  } op_a_sel_e;

  typedef enum logic [1:0] {
    OP_B_RS2  = 2'd0,
    OP_B_IMM  = 2'd1,
    OP_B_FOUR = 2'd2    // PC + 4 for JAL/JALR link
  } op_b_sel_e;

  typedef enum logic [1:0] {
    WB_ALU  = 2'd0,
    WB_LSU  = 2'd1,
    WB_CSR  = 2'd2,
    WB_MD   = 2'd3      // multiplier / divider
  } wb_sel_e;

  // ------------------------------------------------------------------
  // M-extension operations (funct3 of OP with funct7 == 0000001)
  // ------------------------------------------------------------------
  typedef enum logic [2:0] {
    MD_MUL    = 3'b000,
    MD_MULH   = 3'b001,
    MD_MULHSU = 3'b010,
    MD_MULHU  = 3'b011,
    MD_DIV    = 3'b100,
    MD_DIVU   = 3'b101,
    MD_REM    = 3'b110,
    MD_REMU   = 3'b111
  } md_op_e;

  // ------------------------------------------------------------------
  // CSR access
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {
    CSR_NONE = 2'b00,
    CSR_RW   = 2'b01,
    CSR_RS   = 2'b10,
    CSR_RC   = 2'b11
  } csr_op_e;

  // Machine information / trap setup / trap handling
  localparam logic [11:0] CSR_MSTATUS    = 12'h300;
  localparam logic [11:0] CSR_MISA       = 12'h301;
  localparam logic [11:0] CSR_MIE        = 12'h304;
  localparam logic [11:0] CSR_MTVEC      = 12'h305;
  localparam logic [11:0] CSR_MSCRATCH   = 12'h340;
  localparam logic [11:0] CSR_MEPC       = 12'h341;
  localparam logic [11:0] CSR_MCAUSE     = 12'h342;
  localparam logic [11:0] CSR_MTVAL      = 12'h343;
  localparam logic [11:0] CSR_MIP        = 12'h344;
  localparam logic [11:0] CSR_MCYCLE     = 12'hb00;
  localparam logic [11:0] CSR_MINSTRET   = 12'hb02;
  localparam logic [11:0] CSR_MCYCLEH    = 12'hb80;
  localparam logic [11:0] CSR_MINSTRETH  = 12'hb82;
  localparam logic [11:0] CSR_CYCLE      = 12'hc00;
  localparam logic [11:0] CSR_INSTRET    = 12'hc02;
  localparam logic [11:0] CSR_CYCLEH     = 12'hc80;
  localparam logic [11:0] CSR_INSTRETH   = 12'hc82;
  localparam logic [11:0] CSR_MVENDORID  = 12'hf11;
  localparam logic [11:0] CSR_MARCHID    = 12'hf12;
  localparam logic [11:0] CSR_MIMPID     = 12'hf13;
  localparam logic [11:0] CSR_MHARTID    = 12'hf14;

  // Custom (machine-mode, read/write) safety CSRs
  localparam logic [11:0] CSR_MSAFESTAT  = 12'h7c0;  // sticky core-local fault status
  localparam logic [11:0] CSR_MSAFECTRL  = 12'h7c1;  // core-local safety control

  // ------------------------------------------------------------------
  // Exception causes (mcause, interrupt bit cleared)
  // ------------------------------------------------------------------
  localparam logic [4:0] EXC_INSTR_MISALIGN = 5'd0;
  localparam logic [4:0] EXC_INSTR_FAULT    = 5'd1;
  localparam logic [4:0] EXC_ILLEGAL_INSTR  = 5'd2;
  localparam logic [4:0] EXC_BREAKPOINT     = 5'd3;
  localparam logic [4:0] EXC_LOAD_MISALIGN  = 5'd4;
  localparam logic [4:0] EXC_LOAD_FAULT     = 5'd5;
  localparam logic [4:0] EXC_STORE_MISALIGN = 5'd6;
  localparam logic [4:0] EXC_STORE_FAULT    = 5'd7;
  localparam logic [4:0] EXC_ECALL_M        = 5'd11;

  // Interrupt causes (mcause, interrupt bit set)
  localparam logic [4:0] IRQ_M_SOFT = 5'd3;
  localparam logic [4:0] IRQ_M_TIMER= 5'd7;
  localparam logic [4:0] IRQ_M_EXT  = 5'd11;

  // ------------------------------------------------------------------
  // Load/store size encoding (funct3[1:0])
  // ------------------------------------------------------------------
  localparam logic [1:0] LS_BYTE = 2'b00;
  localparam logic [1:0] LS_HALF = 2'b01;
  localparam logic [1:0] LS_WORD = 2'b10;

  // ------------------------------------------------------------------
  // Safety fault identifiers.
  //
  // Each fault source owns one bit in the safety controller status
  // register.  Bits [15:0] are IP-internal sources, bits [31:16] are
  // brought in from the SoC through fault_ext_i.
  // ------------------------------------------------------------------
  localparam int unsigned NUM_INT_FAULTS = 16;
  localparam int unsigned NUM_EXT_FAULTS = 16;
  localparam int unsigned NUM_FAULTS     = NUM_INT_FAULTS + NUM_EXT_FAULTS;

  localparam int unsigned FLT_LOCKSTEP     = 0;   // core comparator mismatch
  localparam int unsigned FLT_ITCM_ECC_COR = 1;   // corrected single-bit error, I-TCM
  localparam int unsigned FLT_ITCM_ECC_UNC = 2;   // uncorrectable error, I-TCM
  localparam int unsigned FLT_DTCM_ECC_COR = 3;   // corrected single-bit error, D-TCM
  localparam int unsigned FLT_DTCM_ECC_UNC = 4;   // uncorrectable error, D-TCM
  localparam int unsigned FLT_REGFILE_PAR  = 5;   // register file parity error
  localparam int unsigned FLT_WDOG         = 6;   // watchdog time-out / bad service
  localparam int unsigned FLT_CLKMON       = 7;   // clock loss / out-of-range
  localparam int unsigned FLT_BUS_ERR      = 8;   // decode error / access fault
  localparam int unsigned FLT_MBIST        = 9;   // start-up memory BIST failure
  localparam int unsigned FLT_AMS          = 10;  // analog supervisor flag
  localparam int unsigned FLT_SW           = 11;  // software-signalled fault
  localparam int unsigned FLT_CORE_TRAP    = 12;  // unexpected core exception
  localparam int unsigned FLT_CFG_PAR     = 13;  // configuration register parity
                                                 // error -- latched UNGATED, see
                                                 // cdriscv_safety_ctrl
  localparam int unsigned FLT_SPARE14      = 14;
  localparam int unsigned FLT_SELFTEST     = 15;  // fault-injection self test

  // ------------------------------------------------------------------
  // SECDED code parameters (Hsiao (39,32))
  // ------------------------------------------------------------------
  localparam int unsigned ECC_DATA_W = 32;
  localparam int unsigned ECC_PAR_W  = 7;
  localparam int unsigned ECC_CW_W   = ECC_DATA_W + ECC_PAR_W;

endpackage
