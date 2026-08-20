/* SPDX-FileCopyrightText: 2026 ChipDesign B.V.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Safety reaction and configuration test.
 *
 * Covers the paths an integrator actually uses and that nothing else
 * touches: configuring the clock monitor through its registers rather
 * than by forcing them, locking the safety controller, and the reset
 * request reaction -- which restarts the core, so this program has to
 * recognise its own second boot.
 *
 * Each failing check writes its own number to the exit register.
 */

    .equ SAFETY_BASE, 0x20000000
    .equ SFT_STATUS,   0x00
    .equ SFT_ENABLE,   0x04
    .equ SFT_REACT_RST,0x0c
    .equ SFT_CTRL,     0x14

    .equ TIMER_BASE,  0x20000200
    .equ TMR_CMP_HI,  0x0c

    .equ CLKMON_BASE, 0x20000300
    .equ CM_CTRL,     0x00
    .equ CM_MIN,      0x04
    .equ CM_MAX,      0x08
    .equ CM_STATUS,   0x0c
    .equ CM_COUNT,    0x10

    .equ EXIT_REG,    0x20000f00
    .equ MARKER,      0x00005eed

    .equ FLT_CLKMON,  7
    .equ FLT_SW,      11

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
    li   s1, CLKMON_BASE
    li   s2, TIMER_BASE

    /* Second boot?  The warm reset restarts the core but leaves the
     * peripherals standing, so the marker written before the reset is
     * still there.  That is how the last check verifies itself.
     */
    lw   t0, TMR_CMP_HI(s2)
    li   t1, MARKER
    beq  t0, t1, after_reset

    /* ---- 1: clock monitor, configured through its registers --------
     * The bench half of the safety tests forces these registers; this
     * is the path software uses, and it had never run.
     *
     * System clock 100 MHz, reference 1 MHz, heartbeat every 256 system
     * cycles: about 2.6 reference cycles per heartbeat period.
     */
    sw   zero, CM_CTRL(s1)      /* disable while configuring */
    li   t0, 1
    sw   t0, CM_MIN(s1)
    li   t0, 6
    sw   t0, CM_MAX(s1)
    li   t0, 1
    sw   t0, CM_CTRL(s1)        /* enable */

    lw   t0, CM_MIN(s1)         /* the registers must read back */
    li   t1, 1
    li   a0, 1
    bne  t0, t1, fail
    lw   t0, CM_MAX(s1)
    li   t1, 6
    li   a0, 2
    bne  t0, t1, fail

    li   s4, 0
1:  addi s4, s4, 1
    li   t1, 3000               /* about 30k cycles: ~100 heartbeats */
    blt  s4, t1, 1b

    lw   t0, CM_STATUS(s1)
    andi t0, t0, 1
    li   a0, 3
    bnez t0, fail               /* nominal ratio must not trip it */

    lw   t0, CM_COUNT(s1)       /* and the measurement must be sane */
    li   a0, 4
    beqz t0, fail

    /* ---- 2: a window the clock cannot meet must trip it ------------ */
    sw   zero, CM_CTRL(s1)
    li   t0, 10                 /* the real count is about 2.6 */
    sw   t0, CM_MIN(s1)
    li   t0, 20
    sw   t0, CM_MAX(s1)
    li   t0, 1
    sw   t0, CM_CTRL(s1)

    li   s4, 0
2:  addi s4, s4, 1
    li   t1, 3000
    blt  s4, t1, 2b

    lw   t0, CM_STATUS(s1)
    andi t0, t0, 1
    li   a0, 5
    beqz t0, fail               /* out of range, it should have tripped */

    lw   t0, SFT_STATUS(s0)     /* and it must reach the safety controller */
    srli t0, t0, FLT_CLKMON
    andi t0, t0, 1
    li   a0, 6
    beqz t0, fail

    li   t0, 1                  /* clear the monitor's sticky bit */
    sw   t0, CM_STATUS(s1)
    sw   zero, CM_CTRL(s1)      /* and switch it off again */
    li   t0, -1
    sw   t0, SFT_STATUS(s0)

    /* ---- 3: arm the reset reaction, before locking -------------------
     * Order matters, and getting it wrong is instructive: an earlier
     * version of this test set the lock first and then tried to write
     * REACT_RST.  The write was refused, no reset happened, and the
     * test failed -- the lock doing exactly its job.
     */
    li   t0, 0x00000800         /* REACT_RST for the software fault bit */
    sw   t0, SFT_REACT_RST(s0)

    /* ---- 4: the configuration lock ---------------------------------- */
    li   t0, 0x0000ffff         /* a recognisable ENABLE value */
    sw   t0, SFT_ENABLE(s0)
    li   t0, 0x9                /* CTRL: enable | lock */
    sw   t0, SFT_CTRL(s0)

    li   t0, 0x12345678         /* must be refused now */
    sw   t0, SFT_ENABLE(s0)
    lw   t0, SFT_ENABLE(s0)
    li   t1, 0x0000ffff
    li   a0, 7
    bne  t0, t1, fail

    /* ---- 5: reset request reaction ----------------------------------
     * React to the software fault with a reset.  The core restarts; the
     * peripherals, and the marker, do not.
     */
    li   t0, MARKER
    sw   t0, TMR_CMP_HI(s2)     /* leave a note for the next boot */

    csrwi 0x7c1, 2              /* software fault -> reset request */

    li   s4, 0
3:  addi s4, s4, 1
    li   t1, 2000
    blt  s4, t1, 3b
    li   a0, 8
    j    fail                   /* still running: no reset happened */

after_reset:
    /* The marker was there, so we have been restarted.  The fault that
     * caused it must still be latched, since the safety controller is
     * not part of the warm reset domain.
     */
    lw   t0, SFT_STATUS(s0)
    srli t0, t0, FLT_SW
    andi t0, t0, 1
    li   a0, 9
    beqz t0, fail

pass:
    li   t0, EXIT_REG
    sw   zero, 0(t0)
4:  j    4b

fail:
    li   t0, EXIT_REG
    sw   a0, 0(t0)
5:  j    5b

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
