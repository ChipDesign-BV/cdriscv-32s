/* SPDX-FileCopyrightText: 2026 ChipDesign B.V.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Fault injection workload.
 *
 * Computes a deterministic checksum over arithmetic and memory traffic
 * and writes it to the exit register.  The campaign classifies a run by
 * comparing that value with the golden one, so the workload has to
 * touch enough state that a corrupted bit is likely to reach it, and
 * has to terminate on its own.
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
    li   s2, 64             /* iterations */
    li   s3, 0x12345        /* running value */

loop:
    /* arithmetic */
    addi s3, s3, 7
    slli t0, s3, 3
    xor  t0, t0, s3
    srli t1, t0, 5
    add  s1, s1, t1
    mul  t2, s3, s2
    add  s1, s1, t2
    sub  t3, t2, t1
    and  t4, t3, s3
    or   t5, t4, t1
    xor  s1, s1, t5

    /* memory */
    sw   s1, 0(s0)
    lw   t6, 0(s0)
    add  s1, s1, t6
    sh   t1, 8(s0)
    lhu  a0, 8(s0)
    add  s1, s1, a0
    sb   t0, 12(s0)
    lbu  a1, 12(s0)
    add  s1, s1, a1

    /* branches, both directions */
    andi a2, s3, 1
    beqz a2, 1f
    addi s1, s1, 3
1:  bltu s1, s3, 2f
    addi s1, s1, 5
2:
    addi s2, s2, -1
    bnez s2, loop

    /* publish the checksum */
    li   t0, EXIT_REG
    sw   s1, 0(t0)
3:  j    3b

trap_handler:
    /* a trap during a fault injection run is a legitimate detection;
     * record it by exiting with a distinctive value */
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
