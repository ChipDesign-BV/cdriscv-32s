/* SPDX-FileCopyrightText: 2026 ChipDesign B.V.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Fault injection workload C: dense sub-word memory traffic.
 *
 * Workload B settled mepc and mstatus.MIE.  It left one row unexplained:
 * the LSU address offset, detected once in thirty two on both workloads
 * so far.  Those two bits select the byte lane and are live only while
 * an access is in flight, so a workload that spends most of its time on
 * arithmetic will almost never activate them -- and, unlike mepc,
 * nothing overwrites them in between, so the low number could equally
 * be a real gap.  The two cases are told apart by raising the exposure
 * and seeing whether detection follows.
 *
 * So this loop is almost nothing but loads and stores, at every width
 * and every alignment the ISA allows, with both sign extending and zero
 * extending forms.  Arithmetic appears only to fold results into the
 * checksum.
 *
 * Every byte the loop reads is written by the loop first.  An unwritten
 * D-TCM byte reads as X in simulation and the X would spread into the
 * checksum, which is finding V4-F2 and would make every run look
 * detected.
 */

    .equ EXIT_REG, 0x20000f00
    .equ SCRATCH,  0x10000800

    .section .text.init, "ax"
    .global _start
_start:
    li  x1,0
    li  x2,0
    li  x3,0
    li  x4,0
    li  x5,0
    li  x6,0
    li  x7,0
    li  x8,0
    li  x9,0
    li  x10,0
    li  x11,0
    li  x12,0
    li  x13,0
    li  x14,0
    li  x15,0
    li  x16,0
    li  x17,0
    li  x18,0
    li  x19,0
    li  x20,0
    li  x21,0
    li  x22,0
    li  x23,0
    li  x24,0
    li  x25,0
    li  x26,0
    li  x27,0
    li  x28,0
    li  x29,0
    li  x30,0
    li  x31,0
    la  sp, _stack_top
    la  t0, trap_handler
    csrw mtvec, t0
    csrw mie, zero

    li   s0, SCRATCH
    li   s1, 0              /* checksum */
    li   s2, 48             /* iterations */
    li   s3, 0x2468         /* running value */

loop:
    addi s3, s3, 13

    /* word in, every sub-word form out */
    sw   s3, 0(s0)
    lb   t0, 0(s0)          /* sign extending byte */
    lbu  t1, 1(s0)          /* zero extending byte */
    lh   t2, 2(s0)          /* sign extending half */
    lhu  t3, 2(s0)          /* zero extending half, same address */
    lw   t4, 0(s0)
    add  s1, s1, t0
    add  s1, s1, t1
    xor  s1, s1, t2
    add  s1, s1, t3
    xor  s1, s1, t4

    /* sub-word stores at all four byte offsets, read back as a word */
    sb   t0, 4(s0)
    sb   t1, 5(s0)
    sh   t2, 6(s0)
    lw   t5, 4(s0)
    add  s1, s1, t5

    /* misaligned-in-word halfword and byte, all four bytes written */
    sh   s1, 8(s0)
    sb   s1, 10(s0)
    sb   t1, 11(s0)
    lhu  t6, 8(s0)
    lbu  a0, 10(s0)
    lb   a1, 11(s0)
    add  s1, s1, t6
    xor  s1, s1, a0
    add  s1, s1, a1
    lw   a2, 8(s0)
    xor  s1, s1, a2

    addi s2, s2, -1
    bnez s2, loop

    li   t0, EXIT_REG
    sw   s1, 0(t0)
3:  j    3b

trap_handler:
    li   t0, EXIT_REG
    li   t1, 0xdead0000
    csrr t2, mcause
    or   t1, t1, t2
    sw   t1, 0(t0)
4:  j    4b

    .section .data
    .align 4
pad: .word 0
    .section .bss
    .align 4
_stack_bottom: .space 512
_stack_top:
