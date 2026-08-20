/* SPDX-FileCopyrightText: 2026 ChipDesign B.V.
 * SPDX-License-Identifier: Apache-2.0
 *
 * cdriscv-32s -- minimal start-up code and smoke test program.
 *
 * Boots at 0x00000000 in the I-TCM, sets up a stack in the D-TCM and a
 * trap vector, exercises a few instructions and peripherals, then ends
 * the simulation through the exit register in the SoC expansion slot.
 *
 * STATUS: NOT VERIFIED YET -- DO NOT USE YET.
 */

    .equ PERIPH_BASE, 0x20000000
    .equ SAFETY_BASE, PERIPH_BASE + 0x000
    .equ WDOG_BASE,   PERIPH_BASE + 0x100
    .equ TIMER_BASE,  PERIPH_BASE + 0x200
    .equ AMS_BASE,    PERIPH_BASE + 0x400
    .equ EXIT_REG,    PERIPH_BASE + 0xf00

    .section .text.init, "ax"
    .global _start
_start:
    /* x1..x31 = 0 so that a lockstep pair starts from the same state */
    li  x1,  0
    li  x2,  0
    li  x3,  0
    li  x4,  0
    li  x5,  0
    li  x6,  0
    li  x7,  0
    li  x8,  0
    li  x9,  0
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
    la  t0, trap_handler
    csrw mtvec, t0
    csrw mie, zero

    /* --- integer smoke test --------------------------------------- */
    li   t0, 12345
    li   t1, 6789
    add  t2, t0, t1
    li   t3, 19134
    bne  t2, t3, fail

    mul  t2, t0, t1
    li   t3, 83810205
    bne  t2, t3, fail

    li   t0, -1000
    li   t1, 7
    div  t2, t0, t1
    li   t3, -142
    bne  t2, t3, fail
    rem  t2, t0, t1
    li   t3, -6
    bne  t2, t3, fail

    /* --- comparison smoke test ------------------------------------
     * The first version of this program used only bne/beq, which let a
     * polarity error in the ALU comparator (finding V0-F2) reach the
     * first simulation undetected.  Every comparison form is checked
     * here now, in both directions.
     */
    li   t0, -5
    li   t1, 3
    slt  t2, t0, t1             /* -5 < 3 signed -> 1 */
    li   t3, 1
    bne  t2, t3, fail
    sltu t2, t0, t1             /* 0xfffffffb < 3 unsigned -> 0 */
    bne  t2, zero, fail
    slti t2, t0, 0              /* -5 < 0 -> 1 */
    bne  t2, t3, fail
    sltiu t2, t1, 4             /* 3 < 4 unsigned -> 1 */
    bne  t2, t3, fail

    blt  t1, t0, fail           /* 3 < -5 signed: must not branch */
    bltu t1, t0, 6f             /* 3 < 0xfffffffb unsigned: must branch */
    j    fail
6:  bge  t0, t1, fail           /* -5 >= 3 signed: must not branch */
    bgeu t0, t1, 7f             /* 0xfffffffb >= 3 unsigned: must branch */
    j    fail
7:

    /* --- memory smoke test ---------------------------------------- */
    la   t0, scratch
    li   t1, 0xdeadbeef
    sw   t1, 0(t0)
    lw   t2, 0(t0)
    bne  t1, t2, fail

    li   t1, 0x55
    sb   t1, 1(t0)
    lbu  t2, 1(t0)
    bne  t1, t2, fail

    /* --- peripherals ---------------------------------------------- */
    /* start a one shot ADC sequence over channels 0 and 1 */
    li   t0, AMS_BASE
    li   t1, 3
    sw   t1, 8(t0)              /* CHMASK  */
    li   t1, 10
    sw   t1, 4(t0)              /* PERIOD  */
    li   t1, 1
    sw   t1, 0(t0)              /* CTRL: sequencer enable, one shot */

    /* wait for the sequence to report done */
    li   t2, 0
1:  lw   t1, 12(t0)             /* STATUS */
    andi t1, t1, 2
    bnez t1, 2f
    addi t2, t2, 1
    li   t3, 10000
    blt  t2, t3, 1b
    j    fail                   /* the sequencer never finished */
2:

    /* --- done ------------------------------------------------------ */
pass:
    li   t0, EXIT_REG
    li   t1, 0
    sw   t1, 0(t0)
3:  j    3b

fail:
    li   t0, EXIT_REG
    li   t1, 1
    sw   t1, 0(t0)
4:  j    4b

trap_handler:
    /* any unexpected trap fails the run */
    li   t0, EXIT_REG
    csrr t1, mcause
    addi t1, t1, 0x100          /* non zero, keeps the cause visible */
    sw   t1, 0(t0)
5:  j    5b

    .section .data
    .align 2
scratch:
    .word 0
    .word 0

    .section .bss
    .align 4
_stack_bottom:
    .space 1024
_stack_top:
