/* SPDX-FileCopyrightText: 2026 ChipDesign B.V.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Trap and illegal instruction test.
 *
 * Walks every exception cause the core can raise and checks mcause,
 * mepc and mtval for each.  Nothing else reaches these paths: a valid
 * program contains no illegal encodings and takes no access faults, so
 * the decoder's rejection logic and most of the trap arbitration had
 * never run -- see the coverage table in verification_findings.md.
 *
 * The handler always returns to an address the main flow puts in s7
 * beforehand.  Advancing mepc by four would work for most causes but
 * not for an instruction access fault, where mepc points into unmapped
 * memory and the next fetch would fault again for ever.
 *
 * Each failing check writes its own number to the exit register.
 */

    .equ EXIT_REG,   0x20000f00
    .equ UNMAPPED,   0x40000000

    .equ CAUSE_IMISALIGN, 0
    .equ CAUSE_IFAULT,    1
    .equ CAUSE_ILLEGAL,   2
    .equ CAUSE_BREAK,     3
    .equ CAUSE_LMISALIGN, 4
    .equ CAUSE_LFAULT,    5
    .equ CAUSE_SMISALIGN, 6
    .equ CAUSE_SFAULT,    7
    .equ CAUSE_ECALL,     11

    .section .text.init, "ax"
    .global _start
_start:
    li  x1, 0
    li  x2, 0
    li  x3, 0
    li  x4, 0
    li  x5, 0
    li  x6, 0
    li  x7, 0
    li  x8, 0
    li  x9, 0
    li  x10, 0
    li  x11, 0
    li  x12, 0
    li  x13, 0
    li  x14, 0
    li  x15, 0
    li  x16, 0
    li  x17, 0
    li  x18, 0
    li  x19, 0
    li  x20, 0
    li  x21, 0
    li  x22, 0
    li  x23, 0
    li  x24, 0
    li  x25, 0
    li  x26, 0
    li  x27, 0
    li  x28, 0
    li  x29, 0
    li  x30, 0
    li  x31, 0

    la   sp, _stack_top
    la   t0, trap_handler
    csrw mtvec, t0
    csrw mie, zero
    li   s8, -1                 /* captured mcause */

/* --- 1: ecall ------------------------------------------------------ */
    la   s7, r1
    ecall
r1: li   a0, 1
    li   t0, CAUSE_ECALL
    bne  s8, t0, fail

/* --- 2: ebreak ----------------------------------------------------- */
    la   s7, r2
    ebreak
r2: li   a0, 2
    li   t0, CAUSE_BREAK
    bne  s8, t0, fail

/* --- 3: illegal instruction, all zero word ------------------------- */
    la   s7, r3
    .word 0x00000000
r3: li   a0, 3
    li   t0, CAUSE_ILLEGAL
    bne  s8, t0, fail
    li   a0, 4
    bnez s9, fail               /* mtval must be the instruction word */

/* --- 4: illegal instruction, reserved funct7 on ADD ---------------- */
    la   s7, r4
    .word 0x02000033            /* funct7 = 0000001 handled, use 0100001 */
r4: li   a0, 5
    li   t0, CAUSE_ILLEGAL
    bne  s8, t0, fail

/* --- 5: illegal instruction, a word that is not 32 bit wide -------- */
    la   s7, r5
    .word 0x00000001            /* instr[1:0] != 11 */
r5: li   a0, 6
    li   t0, CAUSE_ILLEGAL
    bne  s8, t0, fail

/* --- 6: illegal SYSTEM encoding ------------------------------------ */
    la   s7, r6
    .word 0x30000073            /* not ecall/ebreak/mret/wfi */
r6: li   a0, 7
    li   t0, CAUSE_ILLEGAL
    bne  s8, t0, fail

/* --- 6b: the reserved encodings inside each opcode ------------------
 * One per opcode group, to reach the per-opcode default arms of the
 * decoder.  These are the branches no valid program can reach and the
 * random generator never emits, so only a directed test gets there.
 */
    la   s7, r6b1
    .word 0x00002063            /* BRANCH, funct3 = 010 reserved */
r6b1: li a0, 20
    li   t0, CAUSE_ILLEGAL
    bne  s8, t0, fail

    la   s7, r6b2
    .word 0x00003003            /* LOAD, funct3 = 011 reserved */
r6b2: li a0, 21
    li   t0, CAUSE_ILLEGAL
    bne  s8, t0, fail

    la   s7, r6b3
    .word 0x00003023            /* STORE, funct3 = 011 reserved */
r6b3: li a0, 22
    li   t0, CAUSE_ILLEGAL
    bne  s8, t0, fail

    la   s7, r6b4
    .word 0x40001013            /* SLLI with a reserved funct7 */
r6b4: li a0, 23
    li   t0, CAUSE_ILLEGAL
    bne  s8, t0, fail

    la   s7, r6b5
    .word 0x40001033            /* SLL with a reserved funct7 */
r6b5: li a0, 24
    li   t0, CAUSE_ILLEGAL
    bne  s8, t0, fail

    la   s7, r6b6
    .word 0x0000200f            /* MISC-MEM, funct3 = 010 reserved */
r6b6: li a0, 25
    li   t0, CAUSE_ILLEGAL
    bne  s8, t0, fail

    li   s8, -1                 /* clear the captured cause */
    la   s7, r6b7
    .word 0x00006013            /* OP-IMM, funct3 = 110 is ORI: legal,
                                 * kept as a negative control -- if this
                                 * one traps, the decoder is rejecting a
                                 * valid instruction */
r6b7: li a0, 26
    li   t0, CAUSE_ILLEGAL
    beq  s8, t0, fail

/* --- 7: load address misaligned ------------------------------------ */
    la   s7, r7
    la   t1, scratch
    addi t1, t1, 1
    lw   t2, 0(t1)
r7: li   a0, 8
    li   t0, CAUSE_LMISALIGN
    bne  s8, t0, fail

/* --- 8: store address misaligned ----------------------------------- */
    la   s7, r8
    la   t1, scratch
    addi t1, t1, 2
    sw   t2, 0(t1)
r8: li   a0, 9
    li   t0, CAUSE_SMISALIGN
    bne  s8, t0, fail

/* --- 9: load access fault, unmapped address ------------------------ */
    la   s7, r9
    li   t1, UNMAPPED
    lw   t2, 0(t1)
r9: li   a0, 10
    li   t0, CAUSE_LFAULT
    bne  s8, t0, fail

/* --- 10: store access fault ---------------------------------------- */
    la   s7, r10
    li   t1, UNMAPPED
    sw   t2, 0(t1)
r10: li  a0, 11
    li   t0, CAUSE_SFAULT
    bne  s8, t0, fail

/* --- 11: instruction address misaligned ----------------------------
 * With IALIGN=32 a control transfer target with bit 1 set is
 * misaligned.  jalr clears bit 0 only.
 */
    la   s7, r11
    la   t1, aligned_target
    addi t1, t1, 2
    jalr ra, t1, 0
r11: li  a0, 12
    li   t0, CAUSE_IMISALIGN
    bne  s8, t0, fail

/* --- 12: instruction access fault ---------------------------------- */
    la   s7, r12
    li   t1, UNMAPPED
    jalr ra, t1, 0
r12: li  a0, 13
    li   t0, CAUSE_IFAULT
    bne  s8, t0, fail

/* --- 13: mret returns to the right place, and traps still work ----- */
    la   s7, r13
    ecall
r13: li  a0, 14
    li   t0, CAUSE_ECALL
    bne  s8, t0, fail

/* --- 20: write to a read-only CSR --------------------------------- */
    la   s7, r20
    csrw mvendorid, t0          /* addr[11:10]=11: read only by spec */
r20: li  a0, 20
    li   t0, CAUSE_ILLEGAL
    bne  s8, t0, fail

/* --- 21: read of an unimplemented CSR ------------------------------ */
    la   s7, r21
    csrr t1, 0x345              /* machine range, not implemented */
r21: li  a0, 21
    li   t0, CAUSE_ILLEGAL
    bne  s8, t0, fail

pass:
    li   t0, EXIT_REG
    sw   zero, 0(t0)
1:  j    1b

fail:
    li   t0, EXIT_REG
    sw   a0, 0(t0)
2:  j    2b

    .align 2
aligned_target:
    ret

trap_handler:
    csrr s8, mcause
    csrr s9, mtval
    csrr s10, mepc
    csrw mepc, s7
    mret

    .section .data
    .align 4
scratch:
    .word 0, 0, 0, 0

    .section .bss
    .align 4
_stack_bottom:
    .space 512
_stack_top:
