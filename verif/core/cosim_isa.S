/* SPDX-FileCopyrightText: 2026 ChipDesign B.V.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Co-simulation program: exercises the RV32IM instruction set and every
 * control transfer form, with no peripheral access, so that Spike and
 * the RTL can execute exactly the same thing.
 *
 * Rules for anything added here:
 *   - no peripheral or CSR-counter dependent control flow: mcycle and
 *     minstret legitimately differ between the model and the RTL, so a
 *     branch on them would diverge for the wrong reason
 *   - end in a tight loop at `done`; the runner stops both sides after
 *     a fixed number of retired instructions
 */

    .section .text.init, "ax"
    .global _start
_start:
    /* deterministic architectural state on both sides */
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
    la  sp, _stack_top

    /* ---- upper immediates and pc relative ---- */
    lui   a0, 0xdeadb
    addi  a0, a0, 0x2ef
    auipc a1, 0
    auipc a2, 0x1

    /* ---- register-immediate ALU ---- */
    li    t0, -1365            /* 0xfffffaab */
    addi  t1, t0, 1000
    slti  t2, t0, 0
    sltiu t3, t0, 0
    xori  t4, t0, 0x5a5
    ori   t5, t0, 0x0f0
    andi  t6, t0, 0x3ff
    slli  s0, t0, 1
    slli  s1, t0, 31
    srli  s2, t0, 1
    srli  s3, t0, 31
    srai  s4, t0, 1
    srai  s5, t0, 31
    srai  s6, t0, 0

    /* ---- register-register ALU ---- */
    li    a3, 0x7fffffff
    li    a4, 0x80000000
    add   a5, a3, a4
    sub   a6, a3, a4
    sll   a7, a3, t0           /* shift amount from the low 5 bits */
    slt   s7, a3, a4
    sltu  s8, a3, a4
    xor   s9, a3, a4
    srl   s10, a4, a3
    sra   s11, a4, a3
    or    t0, a3, a4
    and   t1, a3, a4

    /* ---- multiply and divide, including the corner cases ---- */
    li    a0, -2147483648      /* INT_MIN */
    li    a1, -1
    mul   a2, a0, a1
    mulh  a3, a0, a1
    mulhu a4, a0, a1
    mulhsu a5, a0, a1
    div   a6, a0, a1           /* overflow: quotient is INT_MIN */
    rem   a7, a0, a1           /* 0 */
    divu  s0, a0, a1
    remu  s1, a0, a1
    li    a1, 0
    div   s2, a0, a1           /* divide by zero: -1 */
    rem   s3, a0, a1           /* divide by zero: dividend */
    divu  s4, a0, a1
    remu  s5, a0, a1
    li    a0, 1000
    li    a1, 7
    mul   s6, a0, a1
    div   s7, a0, a1
    rem   s8, a0, a1

    /* ---- loads and stores, every size and alignment ---- */
    la    t0, scratch
    li    t1, 0x89abcdef
    sw    t1, 0(t0)
    lw    t2, 0(t0)
    lb    t3, 0(t0)
    lb    t4, 1(t0)
    lb    t5, 2(t0)
    lb    t6, 3(t0)
    lbu   s9, 0(t0)
    lbu   s10, 3(t0)
    lh    s11, 0(t0)
    lh    a2, 2(t0)
    lhu   a3, 0(t0)
    lhu   a4, 2(t0)
    li    t1, 0x55
    sb    t1, 4(t0)
    sb    t1, 5(t0)
    sb    t1, 6(t0)
    sb    t1, 7(t0)
    lw    a5, 4(t0)
    li    t1, 0xa5a5
    sh    t1, 8(t0)
    sh    t1, 10(t0)
    lw    a6, 8(t0)

    /* ---- branches, both directions ---- */
    li    t0, 5
    li    t1, -5
    beq   t0, t0, 1f
    j     fail
1:  bne   t0, t1, 2f
    j     fail
2:  blt   t1, t0, 3f
    j     fail
3:  bge   t0, t1, 4f
    j     fail
4:  bltu  t0, t1, 5f           /* 5 < 0xfffffffb unsigned */
    j     fail
5:  bgeu  t1, t0, 6f
    j     fail
6:  beq   t0, t1, fail
    bne   t0, t0, fail
    blt   t0, t1, fail
    bge   t1, t0, fail
    bltu  t1, t0, fail
    bgeu  t0, t1, fail

    /* ---- jumps ---- */
    jal   ra, subroutine
    la    t0, subroutine
    jalr  ra, t0, 0
    jal   x0, 7f               /* jal with rd = x0 */
7:

    /* ---- a loop, so the fetch redirect path runs many times ---- */
    li    t0, 0
    li    t1, 20
8:  addi  t0, t0, 1
    mul   t2, t0, t0
    blt   t0, t1, 8b

    /* ---- CSRs (read only side: no counter dependent branches) ---- */
    csrr  t3, mhartid
    csrr  t4, misa
    li    t5, 0x1234
    csrw  mscratch, t5
    csrr  t6, mscratch
    csrrw s0, mscratch, x0
    csrrs s1, mscratch, t5
    csrrc s2, mscratch, t5
    csrrwi s3, mscratch, 7
    csrrsi s4, mscratch, 8
    csrrci s5, mscratch, 8

done:
    /* HTIF: a non-zero write to tohost with bit 0 set ends a Spike run.
       On the RTL this is just a store into the TCM, and the bench stops
       on its own instruction count. */
    la    t0, tohost
    li    t1, 1
    sw    t1, 0(t0)
1:  j     1b

fail:
    la    t0, tohost
    li    t1, 3
    sw    t1, 0(t0)
2:  j     2b

subroutine:
    addi  a0, a0, 1
    ret

    .section .tohost, "aw", @progbits
    .align 3
    .global tohost
tohost:
    .dword 0
    .global fromhost
fromhost:
    .dword 0

    .section .data
    .align 4
scratch:
    .word 0, 0, 0, 0
