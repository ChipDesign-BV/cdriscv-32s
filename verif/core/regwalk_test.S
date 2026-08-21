/* SPDX-FileCopyrightText: 2026 ChipDesign B.V.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Register walk.
 *
 * Touches the registers and modes that the functional tests never
 * reach: the timer's prescaler and 64 bit roll-over, the interrupt
 * controller's edge mode and claim, the watchdog's window mode and a
 * wrong service key, the safety controller's remaining reaction and pin
 * registers, and the CSRs no program happens to read.
 *
 * This is line coverage work, so the checks are read-back checks rather
 * than behavioural ones, except where a mode has an observable effect.
 *
 * Each failing check writes its own number to the exit register.
 */

    .equ SAFETY_BASE, 0x20000000
    .equ WDOG_BASE,   0x20000100
    .equ TIMER_BASE,  0x20000200
    .equ IRQC_BASE,   0x20000600
    .equ EXIT_REG,    0x20000f00

    .equ KEY_A,       0xa5a55a5a
    .equ KEY_B,       0x5a5aa5a5

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
    li   s1, TIMER_BASE
    li   s2, IRQC_BASE
    li   s3, WDOG_BASE

/* --- 1: timer, prescaler and the 64 bit counter -------------------- */
    sw   zero, 0x10(s1)         /* CTRL: stop the counter */
    li   t0, 7
    sw   t0, 0x14(s1)           /* PRESCALER */
    lw   t0, 0x14(s1)
    li   t1, 7
    li   a0, 1
    bne  t0, t1, fail

    li   t0, 0xfffffff0         /* MTIME_LO near the roll-over */
    sw   t0, 0x00(s1)
    li   t0, 5
    sw   t0, 0x04(s1)           /* MTIME_HI */
    lw   t0, 0x04(s1)
    li   t1, 5
    li   a0, 2
    bne  t0, t1, fail

    li   t0, -1                 /* keep the compare out of reach */
    sw   t0, 0x08(s1)
    sw   t0, 0x0c(s1)
    li   t0, 1
    sw   t0, 0x10(s1)           /* run */

    li   s4, 0
1:  addi s4, s4, 1
    li   t1, 400
    blt  s4, t1, 1b             /* let the prescaled counter roll over */

    lw   t0, 0x04(s1)           /* the high word must have advanced */
    li   t1, 6
    li   a0, 3
    bne  t0, t1, fail
    sw   zero, 0x10(s1)

/* --- 2: interrupt controller, edge mode, pending and claim --------- */
    li   t0, -1
    sw   t0, 0x10(s2)           /* MODE: every source edge triggered */
    lw   t0, 0x10(s2)
    li   a0, 4
    beqz t0, fail

    li   t0, 1
    sw   t0, 0x04(s2)           /* ENABLE source 0 */
    li   t0, -1
    sw   t0, 0x00(s2)           /* clear PENDING */

    csrwi 0x7c1, 2              /* software fault -> safety irq -> source 0 */
    nop
    nop
    nop
    nop
    lw   t0, 0x00(s2)           /* an edge source must latch */
    andi t0, t0, 1
    li   a0, 5
    beqz t0, fail

    lw   t0, 0x08(s2)           /* CLAIM must name source 0 */
    li   a0, 6
    bnez t0, fail

    li   t0, -1
    sw   t0, 0x00(s2)           /* clear it again */
    li   t0, -1
    sw   t0, 0x00(s0)           /* and the safety status */
    sw   zero, 0x10(s2)         /* back to level mode */
    sw   zero, 0x04(s2)

/* --- 3: watchdog, window mode and a wrong key ---------------------- */
    li   t0, 4000
    sw   t0, 0x04(s3)           /* PERIOD */
    li   t0, 2000
    sw   t0, 0x08(s3)           /* WINDOW: service only below this */
    lw   t0, 0x08(s3)
    li   t1, 2000
    li   a0, 7
    bne  t0, t1, fail

    li   t0, 3                  /* enable + window mode */
    sw   t0, 0x00(s3)
    li   t0, -1
    sw   t0, 0x10(s3)           /* clear the watchdog status */
    sw   t0, 0x00(s0)

    li   t0, 0x12345678         /* a wrong key must be refused */
    sw   t0, 0x0c(s3)
    nop
    nop
    nop
    nop
    lw   t0, 0x10(s3)
    andi t0, t0, 2              /* bad service */
    li   a0, 8
    beqz t0, fail

    lw   t0, 0x14(s3)           /* COUNT must be readable */
    li   a0, 9
    beqz t0, fail

    sw   zero, 0x00(s3)         /* stop it */
    li   t0, -1
    sw   t0, 0x10(s3)
    sw   t0, 0x00(s0)

/* --- 4: safety controller, reaction and pin registers -------------- */
    li   t0, 0x0000f0f0
    sw   t0, 0x08(s0)           /* REACT_IRQ */
    lw   t0, 0x08(s0)
    li   t1, 0x0000f0f0
    li   a0, 10
    bne  t0, t1, fail

    li   t0, 0x00000f0f
    sw   t0, 0x10(s0)           /* REACT_PIN */
    lw   t0, 0x10(s0)
    li   t1, 0x00000f0f
    li   a0, 11
    bne  t0, t1, fail

    li   t0, 64
    sw   t0, 0x1c(s0)           /* PIN_DIV */
    lw   t0, 0x1c(s0)
    li   t1, 64
    li   a0, 12
    bne  t0, t1, fail

    li   t0, 5                  /* CTRL: enable + pin toggle mode */
    sw   t0, 0x14(s0)
    lw   t0, 0x14(s0)
    andi t0, t0, 7
    li   t1, 5
    li   a0, 13
    bne  t0, t1, fail

    lw   t0, 0x20(s0)           /* RAW must be readable */
    li   t0, 0x00010000         /* INJECT a spare bit */
    sw   t0, 0x18(s0)
    nop
    nop
    li   t0, -1
    sw   t0, 0x00(s0)
    li   t0, 1                  /* back to level mode */
    sw   t0, 0x14(s0)
    li   t0, -1
    sw   t0, 0x08(s0)
    sw   t0, 0x10(s0)

/* --- 5: the CSRs a program does not happen to read ------------------ */
    csrr t0, 0xf11              /* mvendorid */
    csrr t0, 0xf12              /* marchid   */
    csrr t0, 0xf13              /* mimpid    */
    csrr t0, 0x344              /* mip       */
    csrr t0, 0x301              /* misa      */

    csrr t1, 0xb00              /* mcycle */
    csrr t2, 0xb80              /* mcycleh */
    csrr t3, 0xb02              /* minstret */
    csrr t4, 0xb82              /* minstreth */
    csrr t5, 0xc00              /* cycle, the read-only shadow */
    csrr t6, 0xc02              /* instret */
    csrr t0, 0xc80              /* cycleh */
    csrr t0, 0xc82              /* instreth */

    li   t0, 0x1000             /* the counters are writable */
    csrw 0xb00, t0
    csrr t1, 0xb00
    li   a0, 14
    beqz t1, fail               /* it must have taken something */

    li   t0, 7
    csrw 0xb80, t0
    csrr t1, 0xb80
    li   t2, 7
    li   a0, 15
    bne  t1, t2, fail

    li   t0, 0x2000
    csrw 0xb02, t0
    csrw 0xb82, t0

    csrr t0, 0x340              /* mscratch */
    li   t1, 0xc0ffee
    csrw 0x340, t1
    csrr t0, 0x340
    li   a0, 16
    bne  t0, t1, fail

pass:
    li   t0, EXIT_REG
    sw   zero, 0(t0)
2:  j    2b

fail:
    li   t0, EXIT_REG
    sw   a0, 0(t0)
3:  j    3b

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
