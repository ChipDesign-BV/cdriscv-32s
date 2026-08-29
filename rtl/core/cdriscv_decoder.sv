// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-10 -- instruction decoder (RV32I_Zicsr_Zifencei + M).
//
// Purely combinational.  Produces the control set for one instruction
// plus an illegal-instruction flag.  Nothing in here has state, so the
// decoder is duplicated for free in the lockstep configuration.
//
// STATUS: verified to the O1-O7 gate of doc/verification_plan.md
//         (2026-08-24) -- may be used in a project.  O8-O9 and the
//         FMEDA are open: NOT qualified for safety-critical use.

`default_nettype none

module cdriscv_decoder
  import cdriscv_pkg::*;
#(
    parameter bit RV32M = 1'b1
)(
    input  logic [31:0] instr_i,

    // register file
    output logic [4:0]  rs1_addr_o,
    output logic [4:0]  rs2_addr_o,
    output logic [4:0]  rd_addr_o,
    output logic        rf_we_o,
    output logic        rs1_used_o,
    output logic        rs2_used_o,

    // execute
    output alu_op_e     alu_op_o,
    output op_a_sel_e   op_a_sel_o,
    output op_b_sel_e   op_b_sel_o,
    output logic [31:0] imm_o,
    output wb_sel_e     wb_sel_o,

    // multiply / divide
    output logic        md_req_o,
    output md_op_e      md_op_o,

    // load / store
    output logic        lsu_req_o,
    output logic        lsu_we_o,
    output logic [1:0]  lsu_size_o,
    output logic        lsu_sign_ext_o,

    // control transfer
    output logic        branch_o,       // conditional branch
    output logic        jump_o,         // JAL / JALR
    output logic        jalr_o,         // target base is rs1 (not PC)

    // CSR
    output logic        csr_access_o,
    output csr_op_e     csr_op_o,
    output logic [11:0] csr_addr_o,
    output logic        csr_imm_o,      // use zero-extended uimm[4:0] as source

    // system
    output logic        ecall_o,
    output logic        ebreak_o,
    output logic        mret_o,
    output logic        wfi_o,
    output logic        fence_o,
    output logic        fencei_o,

    output logic        illegal_instr_o
);

  logic [6:0] opcode;
  logic [2:0] funct3;
  logic [6:0] funct7;

  assign opcode = instr_i[6:0];
  assign funct3 = instr_i[14:12];
  assign funct7 = instr_i[31:25];

  assign rs1_addr_o = instr_i[19:15];
  assign rs2_addr_o = instr_i[24:20];
  assign rd_addr_o  = instr_i[11:7];
  assign csr_addr_o = instr_i[31:20];

  // ------------------------------------------------------------------
  // Immediates
  // ------------------------------------------------------------------
  logic [31:0] imm_i_type, imm_s_type, imm_b_type, imm_u_type, imm_j_type, imm_z_type;

  assign imm_i_type = {{20{instr_i[31]}}, instr_i[31:20]};
  assign imm_s_type = {{20{instr_i[31]}}, instr_i[31:25], instr_i[11:7]};
  assign imm_b_type = {{19{instr_i[31]}}, instr_i[31], instr_i[7], instr_i[30:25], instr_i[11:8], 1'b0};
  assign imm_u_type = {instr_i[31:12], 12'b0};
  assign imm_j_type = {{11{instr_i[31]}}, instr_i[31], instr_i[19:12], instr_i[20], instr_i[30:21], 1'b0};
  assign imm_z_type = {27'b0, instr_i[19:15]};   // CSR uimm

  // ------------------------------------------------------------------
  // Main decode
  // ------------------------------------------------------------------
  always_comb begin
    // defaults: NOP-like, nothing enabled
    rf_we_o        = 1'b0;
    rs1_used_o     = 1'b0;
    rs2_used_o     = 1'b0;
    alu_op_o       = ALU_ADD;
    op_a_sel_o     = OP_A_RS1;
    op_b_sel_o     = OP_B_IMM;
    imm_o          = imm_i_type;
    wb_sel_o       = WB_ALU;
    md_req_o       = 1'b0;
    md_op_o        = MD_MUL;
    lsu_req_o      = 1'b0;
    lsu_we_o       = 1'b0;
    lsu_size_o     = LS_WORD;
    lsu_sign_ext_o = 1'b0;
    branch_o       = 1'b0;
    jump_o         = 1'b0;
    jalr_o         = 1'b0;
    csr_access_o   = 1'b0;
    csr_op_o       = CSR_NONE;
    csr_imm_o      = 1'b0;
    ecall_o        = 1'b0;
    ebreak_o       = 1'b0;
    mret_o         = 1'b0;
    wfi_o          = 1'b0;
    fence_o        = 1'b0;
    fencei_o       = 1'b0;
    illegal_instr_o= 1'b0;

    // Only 32-bit instructions are supported (no C extension): the two
    // low bits must be 11.
    if (instr_i[1:0] != 2'b11) begin
      illegal_instr_o = 1'b1;
    end else begin
      unique case (opcode)

        // ----------------------------------------------------------
        OPCODE_LUI: begin
          rf_we_o    = 1'b1;
          op_a_sel_o = OP_A_ZERO;
          op_b_sel_o = OP_B_IMM;
          imm_o      = imm_u_type;
          alu_op_o   = ALU_PASSB;
        end

        OPCODE_AUIPC: begin
          rf_we_o    = 1'b1;
          op_a_sel_o = OP_A_PC;
          op_b_sel_o = OP_B_IMM;
          imm_o      = imm_u_type;
          alu_op_o   = ALU_ADD;
        end

        // ----------------------------------------------------------
        OPCODE_JAL: begin
          rf_we_o    = 1'b1;
          jump_o     = 1'b1;
          op_a_sel_o = OP_A_PC;
          op_b_sel_o = OP_B_FOUR;   // rd <- PC + 4
          imm_o      = imm_j_type;  // target = PC + imm
          alu_op_o   = ALU_ADD;
        end

        OPCODE_JALR: begin
          rs1_used_o = 1'b1;
          rf_we_o    = 1'b1;
          jump_o     = 1'b1;
          jalr_o     = 1'b1;
          op_a_sel_o = OP_A_PC;
          op_b_sel_o = OP_B_FOUR;   // rd <- PC + 4
          imm_o      = imm_i_type;  // target = (rs1 + imm) & ~1
          alu_op_o   = ALU_ADD;
          if (funct3 != 3'b000) illegal_instr_o = 1'b1;
        end

        // ----------------------------------------------------------
        OPCODE_BRANCH: begin
          rs1_used_o = 1'b1;
          rs2_used_o = 1'b1;
          branch_o   = 1'b1;
          op_a_sel_o = OP_A_RS1;
          op_b_sel_o = OP_B_RS2;
          imm_o      = imm_b_type;  // target = PC + imm
          unique case (funct3)
            3'b000:  alu_op_o = ALU_EQ;    // BEQ
            3'b001:  alu_op_o = ALU_NE;    // BNE
            3'b100:  alu_op_o = ALU_SLT;   // BLT
            3'b101:  alu_op_o = ALU_GE;    // BGE
            3'b110:  alu_op_o = ALU_SLTU;  // BLTU
            3'b111:  alu_op_o = ALU_GEU;   // BGEU
            default: illegal_instr_o = 1'b1;
          endcase
        end

        // ----------------------------------------------------------
        OPCODE_LOAD: begin
          rs1_used_o     = 1'b1;
          rf_we_o        = 1'b1;
          lsu_req_o      = 1'b1;
          lsu_we_o       = 1'b0;
          wb_sel_o       = WB_LSU;
          op_a_sel_o     = OP_A_RS1;
          op_b_sel_o     = OP_B_IMM;
          imm_o          = imm_i_type;
          alu_op_o       = ALU_ADD;       // address = rs1 + imm
          lsu_size_o     = funct3[1:0];
          lsu_sign_ext_o = ~funct3[2];
          unique case (funct3)
            3'b000, 3'b001, 3'b010, 3'b100, 3'b101: ;  // LB LH LW LBU LHU
            default: illegal_instr_o = 1'b1;
          endcase
        end

        OPCODE_STORE: begin
          rs1_used_o = 1'b1;
          rs2_used_o = 1'b1;
          lsu_req_o  = 1'b1;
          lsu_we_o   = 1'b1;
          op_a_sel_o = OP_A_RS1;
          op_b_sel_o = OP_B_IMM;
          imm_o      = imm_s_type;
          alu_op_o   = ALU_ADD;           // address = rs1 + imm
          lsu_size_o = funct3[1:0];
          unique case (funct3)
            3'b000, 3'b001, 3'b010: ;     // SB SH SW
            default: illegal_instr_o = 1'b1;
          endcase
        end

        // ----------------------------------------------------------
        OPCODE_OPIMM: begin
          rs1_used_o = 1'b1;
          rf_we_o    = 1'b1;
          op_a_sel_o = OP_A_RS1;
          op_b_sel_o = OP_B_IMM;
          imm_o      = imm_i_type;
          unique case (funct3)
            3'b000: alu_op_o = ALU_ADD;    // ADDI
            3'b010: alu_op_o = ALU_SLT;    // SLTI
            3'b011: alu_op_o = ALU_SLTU;   // SLTIU
            3'b100: alu_op_o = ALU_XOR;    // XORI
            3'b110: alu_op_o = ALU_OR;     // ORI
            3'b111: alu_op_o = ALU_AND;    // ANDI
            3'b001: begin                  // SLLI
              alu_op_o        = ALU_SLL;
              imm_o           = {27'b0, instr_i[24:20]};
              illegal_instr_o = (funct7 != 7'b0000000);
            end
            3'b101: begin                  // SRLI / SRAI
              if (instr_i[30]) alu_op_o = ALU_SRA;
              else             alu_op_o = ALU_SRL;
              imm_o    = {27'b0, instr_i[24:20]};
              illegal_instr_o = !((funct7 == 7'b0000000) || (funct7 == 7'b0100000));
            end
            default: illegal_instr_o = 1'b1;
          endcase
        end

        // ----------------------------------------------------------
        OPCODE_OP: begin
          rs1_used_o = 1'b1;
          rs2_used_o = 1'b1;
          rf_we_o    = 1'b1;
          op_a_sel_o = OP_A_RS1;
          op_b_sel_o = OP_B_RS2;

          if (funct7 == 7'b0000001) begin
            // M extension
            if (RV32M) begin
              md_req_o = 1'b1;
              md_op_o  = md_op_e'(funct3);
              wb_sel_o = WB_MD;
            end else begin
              illegal_instr_o = 1'b1;
            end
          end else begin
            unique case ({funct7, funct3})
              {7'b0000000, 3'b000}: alu_op_o = ALU_ADD;    // ADD
              {7'b0100000, 3'b000}: alu_op_o = ALU_SUB;    // SUB
              {7'b0000000, 3'b001}: alu_op_o = ALU_SLL;    // SLL
              {7'b0000000, 3'b010}: alu_op_o = ALU_SLT;    // SLT
              {7'b0000000, 3'b011}: alu_op_o = ALU_SLTU;   // SLTU
              {7'b0000000, 3'b100}: alu_op_o = ALU_XOR;    // XOR
              {7'b0000000, 3'b101}: alu_op_o = ALU_SRL;    // SRL
              {7'b0100000, 3'b101}: alu_op_o = ALU_SRA;    // SRA
              {7'b0000000, 3'b110}: alu_op_o = ALU_OR;     // OR
              {7'b0000000, 3'b111}: alu_op_o = ALU_AND;    // AND
              default:              illegal_instr_o = 1'b1;
            endcase
          end
        end

        // ----------------------------------------------------------
        OPCODE_MISCMEM: begin
          unique case (funct3)
            3'b000:  fence_o  = 1'b1;   // FENCE  -- ordering is trivial here
            3'b001:  fencei_o = 1'b1;   // FENCE.I -- refetch after the fence
            default: illegal_instr_o = 1'b1;
          endcase
        end

        // ----------------------------------------------------------
        OPCODE_SYSTEM: begin
          if (funct3 == 3'b000) begin
            // privileged / environment
            unique case (instr_i[31:7])
              25'b0000000_00000_00000_000_00000: ecall_o  = 1'b1;   // ECALL
              25'b0000000_00001_00000_000_00000: ebreak_o = 1'b1;   // EBREAK
              25'b0011000_00010_00000_000_00000: mret_o   = 1'b1;   // MRET
              25'b0001000_00101_00000_000_00000: wfi_o    = 1'b1;   // WFI
              default: illegal_instr_o = 1'b1;
            endcase
          end else begin
            // Zicsr
            csr_access_o = 1'b1;
            rf_we_o      = 1'b1;
            wb_sel_o     = WB_CSR;
            csr_imm_o    = funct3[2];
            rs1_used_o   = ~funct3[2];
            imm_o        = imm_z_type;
            unique case (funct3[1:0])
              2'b01:   csr_op_o = CSR_RW;
              2'b10:   csr_op_o = CSR_RS;
              2'b11:   csr_op_o = CSR_RC;
              default: illegal_instr_o = 1'b1;
            endcase
          end
        end

        default: illegal_instr_o = 1'b1;
      endcase
    end

    // An illegal instruction must not have any architectural effect.
    if (illegal_instr_o) begin
      rf_we_o      = 1'b0;
      lsu_req_o    = 1'b0;
      md_req_o     = 1'b0;
      branch_o     = 1'b0;
      jump_o       = 1'b0;
      csr_access_o = 1'b0;
      csr_op_o     = CSR_NONE;
      ecall_o      = 1'b0;
      ebreak_o     = 1'b0;
      mret_o       = 1'b0;
      wfi_o        = 1'b0;
      fence_o      = 1'b0;
      fencei_o     = 1'b0;
    end
  end

endmodule
