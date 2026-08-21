/* SPDX-FileCopyrightText: 2026 ChipDesign B.V.
 * SPDX-License-Identifier: Apache-2.0
 *
 * AMS interface test.
 *
 * The mixed-signal half of the IP, and the part with the least
 * coverage: the smoke test starts one sequence and looks at one status
 * bit, so the limit registers, the range checking, the conversion
 * time-out, the trim output and the analog test bus had never run.
 *
 * The bench's ADC model answers a conversion after 20 cycles with
 * 0x100 + channel, which is what the expected values below come from.
 * The time-out is provoked by setting the limit *below* that latency
 * rather than by changing the model.
 *
 * Each failing check writes its own number to the exit register.
 */

    .equ SAFETY_BASE, 0x20000000
    .equ AMS_BASE,    0x20000400
    .equ EXIT_REG,    0x20000f00

    .equ AMS_CTRL,    0x00
    .equ AMS_PERIOD,  0x04
    .equ AMS_CHMASK,  0x08
    .equ AMS_STATUS,  0x0c
    .equ AMS_RESULT0, 0x10
    .equ AMS_RESULT1, 0x14
    .equ AMS_LIMIT0,  0x30
    .equ AMS_LIMIT1,  0x34
    .equ AMS_DAC,     0x50
    .equ AMS_FLAGCFG, 0x54
    .equ AMS_TIMEOUT, 0x58

    .equ FLT_AMS,     10

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

    li   s0, SAFETY_BASE
    li   s1, AMS_BASE

/* --- 1: a sequence over two channels, wide limits ------------------ */
    li   t0, 0x0000ffff         /* LIMIT: lo = 0x0000, hi = 0xffff */
    li   t1, 0xffff0000
    or   t0, t0, t1
    li   t0, 0xffff0000         /* hi = 0xffff, lo = 0x0000 */
    sw   t0, AMS_LIMIT0(s1)
    sw   t0, AMS_LIMIT1(s1)

    li   t0, 1000
    sw   t0, AMS_TIMEOUT(s1)
    li   t0, 10
    sw   t0, AMS_PERIOD(s1)
    li   t0, 3                  /* channels 0 and 1 */
    sw   t0, AMS_CHMASK(s1)
    li   t0, -1                 /* clear any status */
    sw   t0, AMS_STATUS(s1)
    li   t0, 1                  /* enable, one shot */
    sw   t0, AMS_CTRL(s1)

    li   s4, 0
1:  lw   t0, AMS_STATUS(s1)
    andi t1, t0, 2              /* done */
    bnez t1, 2f
    addi s4, s4, 1
    li   t1, 4000
    blt  s4, t1, 1b
    li   a0, 1
    j    fail                   /* the sequence never finished */
2:
    lw   t0, AMS_RESULT0(s1)    /* the model answers 0x100 + channel */
    li   t1, 0x100
    li   a0, 2
    bne  t0, t1, fail
    lw   t0, AMS_RESULT1(s1)
    li   t1, 0x101
    li   a0, 3
    bne  t0, t1, fail

    lw   t0, AMS_STATUS(s1)     /* range flags live in bits 15:8 */
    srli t0, t0, 8
    andi t0, t0, 0xff
    li   a0, 4
    bnez t0, fail               /* everything was inside its window */

/* --- 2: a window channel 1 cannot meet ----------------------------- */
    li   t0, 0x00500000         /* hi = 0x0050, lo = 0x0000 */
    sw   t0, AMS_LIMIT1(s1)
    li   t0, -1
    sw   t0, AMS_STATUS(s1)
    sw   t0, 0(s0)              /* and the safety status */
    li   t0, 1
    sw   t0, AMS_CTRL(s1)

    li   s4, 0
3:  lw   t0, AMS_STATUS(s1)
    andi t1, t0, 2
    bnez t1, 4f
    addi s4, s4, 1
    li   t1, 4000
    blt  s4, t1, 3b
    li   a0, 5
    j    fail
4:
    lw   t0, AMS_STATUS(s1)
    srli t0, t0, 9              /* channel 1's range flag */
    andi t0, t0, 1
    li   a0, 6
    beqz t0, fail

    lw   t0, 0(s0)              /* and it must reach the safety controller */
    srli t0, t0, FLT_AMS
    andi t0, t0, 1
    li   a0, 7
    beqz t0, fail

    li   t0, 0xffff0000         /* put the window back */
    sw   t0, AMS_LIMIT1(s1)
    li   t0, -1
    sw   t0, AMS_STATUS(s1)
    sw   t0, 0(s0)

/* --- 3: conversion time-out ----------------------------------------
 * The model needs 20 cycles; give the sequencer 2.  No change to the
 * bench is needed to exercise the time-out path.
 */
    li   t0, 2
    sw   t0, AMS_TIMEOUT(s1)
    li   t0, 1
    sw   t0, AMS_CTRL(s1)

    li   s4, 0
5:  lw   t0, AMS_STATUS(s1)
    andi t1, t0, 4              /* time-out */
    bnez t1, 6f
    addi s4, s4, 1
    li   t1, 4000
    blt  s4, t1, 5b
    li   a0, 8
    j    fail
6:
    lw   t0, 0(s0)
    srli t0, t0, FLT_AMS
    andi t0, t0, 1
    li   a0, 9
    beqz t0, fail               /* a stuck ADC is a safety fault */

    li   t0, 1000               /* restore a sane time-out */
    sw   t0, AMS_TIMEOUT(s1)
    li   t0, -1
    sw   t0, AMS_STATUS(s1)
    sw   t0, 0(s0)

/* --- 4: trim output and analog test bus ----------------------------- */
    li   t0, 0xabc
    sw   t0, AMS_DAC(s1)
    lw   t0, AMS_DAC(s1)
    li   t1, 0xabc
    li   a0, 10
    bne  t0, t1, fail

    li   t0, 0x54               /* atest enable, select 5 */
    sw   t0, AMS_CTRL(s1)
    lw   t0, AMS_CTRL(s1)
    andi t1, t0, 0x74
    li   t2, 0x54
    li   a0, 11
    bne  t1, t2, fail

    li   t0, 0xf                /* all four analog flags raise faults */
    sw   t0, AMS_FLAGCFG(s1)
    lw   t0, AMS_FLAGCFG(s1)
    li   t1, 0xf
    li   a0, 12
    bne  t0, t1, fail

pass:
    li   t0, EXIT_REG
    sw   zero, 0(t0)
7:  j    7b

fail:
    li   t0, EXIT_REG
    sw   a0, 0(t0)
8:  j    8b

trap_handler:
    csrr t6, mepc
    addi t6, t6, 4
    csrw mepc, t6
    mret

    .section .data
    .align 4
pad:
    .word 0

    .section .bss
    .align 4
_stack_bottom:
    .space 512
_stack_top:
