/* SPDX-FileCopyrightText: 2026 ChipDesign B.V.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Fault injection workload B: traps and interrupts.
 *
 * The first campaign reported mepc detected 0 times out of 41 and
 * mstatus.MIE 0 out of 37.  Neither number said anything about the
 * design.  Workload A takes no traps and enables no interrupts, so
 * both bits are dead state for the whole run and an upset in them is
 * invisible by construction.
 *
 * This workload makes them live:
 *
 *   mepc          an ecall every iteration, at a fixed program counter.
 *                 The handler folds mepc into the checksum and then
 *                 returns through it, so an upset either corrupts the
 *                 result or lands the return somewhere it should not.
 *   mstatus.MIE   the machine timer runs and its interrupt is enabled.
 *                 The handler counts interrupts and the count goes into
 *                 the checksum, so losing MIE loses interrupts and
 *                 changes the answer.
 *
 * The interrupt count has to be robust against a fault that merely
 * shifts timing by a cycle, or every perturbation would look like data
 * corruption.  So the handler rearms from MTIMECMP rather than from
 * MTIME: the schedule is absolute, not relative to when the handler
 * happened to run.
 *
 * Registers s8, s9 and s10 belong to the handler and the main loop
 * never touches them, which is why there is no save and restore.
 */

    .equ EXIT_REG,     0x20000f00
    .equ SCRATCH,      0x10000800
    .equ TIMER,        0x20000200
    .equ MTIME_LO,     0x00
    .equ MTIMECMP_LO,  0x08
    .equ MTIMECMP_HI,  0x0c
    .equ TMR_CTRL,     0x10
    .equ TMR_PRESCALE, 0x14
    .equ IRQ_STEP,     400
    .equ CAUSE_ECALL,  11

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

    /* machine timer: free running from zero, first compare at IRQ_STEP */
    li   t0, TIMER
    sw   zero, MTIME_LO(t0)
    sw   zero, 4(t0)
    sw   zero, MTIMECMP_HI(t0)
    li   t1, IRQ_STEP
    sw   t1, MTIMECMP_LO(t0)
    sw   zero, TMR_PRESCALE(t0)
    li   t1, 1
    sw   t1, TMR_CTRL(t0)

    /* enable the machine timer interrupt, then interrupts globally */
    li   t0, 0x80               /* mie.MTIE */
    csrw mie, t0
    li   t0, 0x8                /* mstatus.MIE */
    csrs mstatus, t0

    li   s0, SCRATCH
    li   s1, 0                  /* checksum */
    li   s2, 64                 /* iterations */
    li   s3, 0x12345            /* running value */
    li   s7, 0                  /* interrupts taken */

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

    /* a synchronous trap at a known program counter: this is what
     * puts a deterministic value into mepc */
    ecall

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

    /* fold the interrupt count in, weighted so that losing one
     * interrupt cannot be cancelled by an arithmetic slip */
    slli t0, s7, 11
    add  s1, s1, t0
    add  s1, s1, s7

    li   t0, EXIT_REG
    sw   s1, 0(t0)
3:  j    3b

    .align 2
trap_handler:
    csrr s8, mcause
    bltz s8, irq_path           /* mcause[31] set means interrupt */

    li   s9, CAUSE_ECALL
    bne  s8, s9, bad_trap

    csrr s10, mepc
    add  s1, s1, s10            /* the return address is part of the answer */
    addi s10, s10, 4
    csrw mepc, s10
    mret

irq_path:
    addi s7, s7, 1
    li   s9, TIMER
    lw   s10, MTIMECMP_LO(s9)
    li   s8, IRQ_STEP
    add  s10, s10, s8           /* absolute schedule, immune to handler jitter */
    sw   s10, MTIMECMP_LO(s9)
    mret

    /* anything else is a real detection: a fault has pushed the core
     * into a trap the workload does not take */
bad_trap:
    li   s9, EXIT_REG
    li   s10, 0xdead0000
    or   s10, s10, s8
    sw   s10, 0(s9)
4:  j    4b

    .section .data
    .align 4
pad: .word 0
    .section .bss
    .align 4
_stack_bottom: .space 512
_stack_top:
