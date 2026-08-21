// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// Formal properties for cdriscv_decoder.
//
// The decoder is combinational, so a bounded model check quantifies
// over **every one of the 2^32 instruction encodings**.  No simulation
// can do that, and the property below is exactly the one that matters
// for safety: an instruction the decoder rejects must have no
// architectural effect whatsoever.
//
// If a reserved encoding were to set, say, rf_we while also raising
// illegal_instr_o, the core would take an illegal instruction trap
// *and* corrupt a register on the way -- a silent data corruption
// triggered by a bit flip in the instruction memory that the ECC
// happened to miscorrect, or by a wild jump into data.

`default_nettype none

module decoder_fv
  import cdriscv_pkg::*;
(
    input  logic        clk_i,
    input  logic [31:0] instr_i
);

  logic [4:0]  rs1_addr, rs2_addr, rd_addr;
  logic        rf_we, rs1_used, rs2_used;
  alu_op_e     alu_op;
  op_a_sel_e   op_a_sel;
  op_b_sel_e   op_b_sel;
  logic [31:0] imm;
  wb_sel_e     wb_sel;
  logic        md_req;
  md_op_e      md_op;
  logic        lsu_req, lsu_we, lsu_sign_ext;
  logic [1:0]  lsu_size;
  logic        branch, jump, jalr;
  logic        csr_access, csr_imm;
  csr_op_e     csr_op;
  logic [11:0] csr_addr;
  logic        ecall, ebreak, mret, wfi, fence, fencei;
  logic        illegal;

  cdriscv_decoder #(.RV32M(1'b1)) u_dut (
      .instr_i         (instr_i),
      .rs1_addr_o      (rs1_addr),
      .rs2_addr_o      (rs2_addr),
      .rd_addr_o       (rd_addr),
      .rf_we_o         (rf_we),
      .rs1_used_o      (rs1_used),
      .rs2_used_o      (rs2_used),
      .alu_op_o        (alu_op),
      .op_a_sel_o      (op_a_sel),
      .op_b_sel_o      (op_b_sel),
      .imm_o           (imm),
      .wb_sel_o        (wb_sel),
      .md_req_o        (md_req),
      .md_op_o         (md_op),
      .lsu_req_o       (lsu_req),
      .lsu_we_o        (lsu_we),
      .lsu_size_o      (lsu_size),
      .lsu_sign_ext_o  (lsu_sign_ext),
      .branch_o        (branch),
      .jump_o          (jump),
      .jalr_o          (jalr),
      .csr_access_o    (csr_access),
      .csr_op_o        (csr_op),
      .csr_addr_o      (csr_addr),
      .csr_imm_o       (csr_imm),
      .ecall_o         (ecall),
      .ebreak_o        (ebreak),
      .mret_o          (mret),
      .wfi_o           (wfi),
      .fence_o         (fence),
      .fencei_o        (fencei),
      .illegal_instr_o (illegal)
  );

  always @(posedge clk_i) begin
    // An illegal instruction must have no architectural effect: no
    // register write, no memory access, no control transfer, no CSR
    // access, no system side effect.  Over every encoding.
    if (illegal) begin
      p_illegal_no_rf:   assert (!rf_we);
      p_illegal_no_lsu:  assert (!lsu_req);
      p_illegal_no_md:   assert (!md_req);
      p_illegal_no_ctrl: assert (!branch && !jump);
      p_illegal_no_csr:  assert (!csr_access && (csr_op == CSR_NONE));
      p_illegal_no_sys:  assert (!ecall && !ebreak && !mret && !wfi &&
                                 !fence && !fencei);
    end

    // Mutually exclusive by construction: an instruction is never both
    // a memory access and a multiply, nor both a branch and a jump.
    p_excl_lsu_md:     assert (!(lsu_req && md_req));
    p_excl_branch_jump:assert (!(branch && jump));

    // Anything that is not a 32-bit encoding is rejected.  This is the
    // check that has to change first if the compressed extension is
    // ever added -- see doc/isa_extension_plan.md.
    p_only_32bit: assert ((instr_i[1:0] == 2'b11) || illegal);
  end

endmodule
