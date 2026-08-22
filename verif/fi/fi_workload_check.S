/* SPDX-FileCopyrightText: 2026 ChipDesign B.V.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Fault injection workload D: the same work, plus a configuration
 * check.
 *
 * V29 measured that twelve configuration registers are 100 % latent --
 * an upset switches a safety mechanism off and the design goes on
 * producing correct answers with nothing to say it has been disarmed.
 * The safety manual's response is to tell integrators to re-read the
 * configuration periodically.  This workload is that advice, written
 * down and executable, so that the campaign can measure what it is
 * worth instead of the manual asserting it.
 *
 * Every iteration the loop re-reads each configuration register and
 * compares it against the value it wrote.  A mismatch raises the
 * software fault through msafectrl, which the safety controller latches
 * like any other -- so a fault that was latent becomes detected, and
 * the campaign counts it as such without any change to the classifier.
 *
 * The check costs eleven loads and eleven compares per iteration.  That
 * is the price being measured, and it is not small: the arithmetic it
 * guards is about twenty instructions.
 */

    .equ EXIT_REG,     0x20000f00
    .equ SCRATCH,      0x10000800

    .equ SAFETY,       0x20000000
    .equ SFT_ENABLE,   0x04
    .equ SFT_REACT_IRQ,0x08
    .equ SFT_REACT_RST,0x0c
    .equ SFT_CTRL,     0x14

    .equ WDOG,         0x20000100
    .equ CLKMON,       0x20000300
    .equ AMS,          0x20000400
    .equ IRQC,         0x20000600
    .equ TIMER,        0x20000200

    .equ CSR_MSAFECTRL, 0x7c1

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

    /* ---- arm the mechanisms, and remember what we armed them with -- */
    li   s4, SAFETY
    li   t0, -1
    sw   t0, SFT_ENABLE(s4)         /* every source contributes */
    li   t0, 0x00000101
    sw   t0, SFT_REACT_IRQ(s4)
    li   t0, 0x00000202
    sw   t0, SFT_REACT_RST(s4)
    li   t0, 1
    sw   t0, SFT_CTRL(s4)           /* controller enabled */

    li   s5, CLKMON
    /* The bench clocks a 1 MHz reference against 100 MHz with HbDiv
     * 256, so the measured count is about 2.6 reference cycles.  A
     * window of 20..40 trips the monitor on every run and every
     * injection then looks detected -- which would have made this
     * campaign meaningless. */
    li   t0, 1
    sw   t0, 0x04(s5)               /* MIN */
    li   t0, 6
    sw   t0, 0x08(s5)               /* MAX */
    li   t0, 1
    sw   t0, 0x00(s5)               /* enable */

    li   s6, IRQC
    li   t0, 0x0000000f
    sw   t0, 0x04(s6)               /* ENABLE */

    li   s7, WDOG
    li   t0, 0x00010000
    sw   t0, 0x04(s7)               /* PERIOD, watchdog left disabled */

    li   s8, TIMER
    li   t0, 0x00002000
    sw   t0, 0x08(s8)               /* MTIMECMP_LO */

    li   s9, AMS
    li   t0, 0x00000005
    sw   t0, 0x08(s9)               /* channel mask */

    li   s0, SCRATCH
    li   s1, 0                      /* checksum */
    li   s2, 64                     /* iterations */
    li   s3, 0x12345                /* running value */

loop:
    /* ---- the work, identical to workload A ---------------------- */
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

    sw   s1, 0(s0)
    lw   t6, 0(s0)
    add  s1, s1, t6
    sh   t1, 8(s0)
    lhu  a0, 8(s0)
    add  s1, s1, a0
    sb   t0, 12(s0)
    lbu  a1, 12(s0)
    add  s1, s1, a1

    andi a2, s3, 1
    beqz a2, 1f
    addi s1, s1, 3
1:  bltu s1, s3, 2f
    addi s1, s1, 5
2:

    /* ---- the mitigation: is everything still armed? -------------- */
    lw   a3, SFT_ENABLE(s4)
    li   a4, -1
    bne  a3, a4, cfg_bad
    lw   a3, SFT_REACT_IRQ(s4)
    li   a4, 0x00000101
    bne  a3, a4, cfg_bad
    lw   a3, SFT_REACT_RST(s4)
    li   a4, 0x00000202
    bne  a3, a4, cfg_bad
    lw   a3, SFT_CTRL(s4)
    andi a3, a3, 1
    li   a4, 1
    bne  a3, a4, cfg_bad

    lw   a3, 0x04(s5)               /* clock monitor MIN */
    li   a4, 1
    bne  a3, a4, cfg_bad
    lw   a3, 0x08(s5)               /* MAX */
    li   a4, 6
    bne  a3, a4, cfg_bad
    lw   a3, 0x00(s5)               /* enable */
    andi a3, a3, 1
    li   a4, 1
    bne  a3, a4, cfg_bad

    lw   a3, 0x04(s6)               /* interrupt controller ENABLE */
    li   a4, 0x0000000f
    bne  a3, a4, cfg_bad

    csrr a3, mtvec
    la   a4, trap_handler
    bne  a3, a4, cfg_bad

    /* The first version of this workload checked only the safety
     * controller, the clock monitor, the interrupt controller and
     * mtvec.  The watchdog, the timer and the AMS mask stayed 100 %
     * latent -- not because the mitigation does not work, but because
     * a read-back check covers exactly what it reads back.  These
     * three close that. */
    lw   a3, 0x04(s7)               /* watchdog PERIOD */
    li   a4, 0x00010000
    bne  a3, a4, cfg_bad
    lw   a3, 0x08(s8)               /* timer MTIMECMP_LO */
    li   a4, 0x00002000
    bne  a3, a4, cfg_bad
    lw   a3, 0x08(s9)               /* AMS channel mask */
    li   a4, 0x00000005
    bne  a3, a4, cfg_bad

    addi s2, s2, -1
    bnez s2, loop

    li   t0, EXIT_REG
    sw   s1, 0(t0)
3:  j    3b

    /* The configuration is not what it was written as.  Raise the
     * software fault so the safety controller latches it: that is the
     * whole point -- a latent fault becomes a reported one. */
cfg_bad:
    csrwi CSR_MSAFECTRL, 2
    nop
    nop
    nop
    li   t0, EXIT_REG
    li   t1, 0xbad0c0de
    sw   t1, 0(t0)
4:  j    4b

trap_handler:
    li   t0, EXIT_REG
    li   t1, 0xdead0000
    csrr t2, mcause
    or   t1, t1, t2
    sw   t1, 0(t0)
5:  j    5b

    .section .bss
    .align 4
_stack_bottom:
    .space 512
_stack_top:
