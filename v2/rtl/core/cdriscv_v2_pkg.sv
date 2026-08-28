// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s variant 2 -- shared types.
//
// Variant 2 targets
//   -march=rv32im_zba_zbb_zbs_zicsr_zifencei_zca_zcb_zcmp -mabi=ilp32
// and adds PMP, end-to-end bus protection, a single-cycle multiplier,
// a standard CLINT and a JTAG TAP.  Variant 1 (rtl/) is unchanged and
// remains the signed-off configuration.
//
// STATUS: NEW AND UNVERIFIED.  Nothing in v2/ has been through the
//         O1-O9 gate.  Do not use.

`ifndef CDRISCV_V2_PKG_SV
`define CDRISCV_V2_PKG_SV

package cdriscv_v2_pkg;

  // --------------------------------------------------------------- ALU
  // Variant 1 used a 4-bit operator with 15 encodings.  Zba/Zbb/Zbs add
  // 27 more, so the field widens to 6 bits.  The base encodings keep
  // their variant-1 values so the shared decoder logic reads the same.
  typedef enum logic [5:0] {
    ALU_ADD   = 6'd0,  ALU_SUB   = 6'd1,  ALU_SLL  = 6'd2,
    ALU_SLT   = 6'd3,  ALU_SLTU  = 6'd4,  ALU_XOR  = 6'd5,
    ALU_SRL   = 6'd6,  ALU_SRA   = 6'd7,  ALU_OR   = 6'd8,
    ALU_AND   = 6'd9,  ALU_EQ    = 6'd10, ALU_NE   = 6'd11,
    ALU_GE    = 6'd12, ALU_GEU   = 6'd13, ALU_PASSB= 6'd14,

    // ---- Zba: address generation
    ALU_SH1ADD = 6'd16, ALU_SH2ADD = 6'd17, ALU_SH3ADD = 6'd18,

    // ---- Zbb: basic bit manipulation
    ALU_ANDN  = 6'd20, ALU_ORN   = 6'd21, ALU_XNOR  = 6'd22,
    ALU_CLZ   = 6'd23, ALU_CTZ   = 6'd24, ALU_CPOP  = 6'd25,
    ALU_MAX   = 6'd26, ALU_MAXU  = 6'd27, ALU_MIN   = 6'd28,
    ALU_MINU  = 6'd29, ALU_SEXTB = 6'd30, ALU_SEXTH = 6'd31,
    ALU_ZEXTH = 6'd32, ALU_ROL   = 6'd33, ALU_ROR   = 6'd34,
    ALU_ORCB  = 6'd35, ALU_REV8  = 6'd36,

    // ---- Zbs: single-bit
    ALU_BCLR  = 6'd40, ALU_BEXT  = 6'd41, ALU_BINV  = 6'd42,
    ALU_BSET  = 6'd43
  } alu_op_e;

  // ---------------------------------------------------- mul / div
  // Encoded as funct3 of the M extension so the decoder passes the
  // field straight through.
  typedef enum logic [2:0] {
    MD_MUL    = 3'd0, MD_MULH  = 3'd1, MD_MULHSU = 3'd2, MD_MULHU = 3'd3,
    MD_DIV    = 3'd4, MD_DIVU  = 3'd5, MD_REM    = 3'd6, MD_REMU  = 3'd7
  } md_op_e;

  // ------------------------------------------------------------ PMP
  // Machine-mode PMP, NAPOT/TOR/NA4/OFF as per the privileged spec.
  typedef enum logic [1:0] {
    PMP_OFF   = 2'b00,
    PMP_TOR   = 2'b01,
    PMP_NA4   = 2'b10,
    PMP_NAPOT = 2'b11
  } pmp_mode_e;

  typedef struct packed {
    logic      l;        // locked
    logic [1:0] rsv;
    pmp_mode_e a;        // address matching mode
    logic      x, w, r;  // execute / write / read
  } pmp_cfg_t;

  typedef enum logic [1:0] {
    PMP_ACC_READ  = 2'd0,
    PMP_ACC_WRITE = 2'd1,
    PMP_ACC_EXEC  = 2'd2
  } pmp_access_e;

  // ------------------------------------------- end-to-end protection
  // A bus payload carried with its own check bits so a fault anywhere
  // between producer and consumer is detected at the consumer rather
  // than trusted because the wires looked fine.
  typedef struct packed {
    logic [31:0] data;
    logic [6:0]  chk;    // (39,32) Hsiao SEC-DED, as the TCMs use
  } e2e_word_t;

endpackage

`endif
