/* SPDX-FileCopyrightText: 2026 ChipDesign B.V.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Peripheral and interrupt test.
 *
 * Covers what nothing else reaches: the machine timer, the interrupt
 * controller, all three interrupt causes, WFI, the watchdog and the
 * memory BIST.  Before this test the core had never taken an interrupt
 * at all -- see the coverage baseline in verification_findings.md.
 *
 * Each failing check writes its own number to the exit register.
 *
 * Register discipline: interrupts arrive asynchronously, so anything
 * that must survive one lives in an s register.  The handler touches
 * only t3..t6 and s2.
 */

    .equ SAFETY_BASE, 0x20000000
    .equ WDOG_BASE,   0x20000100
    .equ TIMER_BASE,  0x20000200
    .equ MBIST_BASE,  0x20000500
    .equ IRQC_BASE,   0x20000600
    .equ EXIT_REG,    0x20000f00

    .equ MTIMECMP_LO, 0x08
    .equ MTIMECMP_HI, 0x0c
    .equ TMR_CTRL,    0x10

    .equ IRQC_ENABLE, 0x04
    .equ IRQC_MSIP,   0x0c
    .equ IRQC_MODE,   0x10

    .equ WD_CTRL,     0x00
    .equ WD_PERIOD,   0x04
    .equ WD_SERVICE,  0x0c
    .equ WD_STATUS,   0x10

    .equ MB_D_CTRL,   0x40
    .equ MB_D_STATUS, 0x44

    .equ KEY_A,       0xa5a55a5a
    .equ KEY_B,       0x5a5aa5a5

    .equ MIE_MSIE,    0x008
    .equ MIE_MTIE,    0x080
    .equ MIE_MEIE,    0x800
    .equ MSTATUS_MIE, 0x008

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
    li   s2, 0                  /* interrupt flags set by the handler */
    li   s0, SAFETY_BASE
    li   s1, TIMER_BASE
    li   s3, IRQC_BASE

    /* ---- 1: machine timer interrupt --------------------------------
     * The compare value is 64 bit: the high word must be zero for a
     * small deadline.  Writing -1 there, as a first version of this
     * test did, puts the deadline centuries away and nothing fires.
     */
    sw   zero, MTIMECMP_HI(s1)
    li   t0, 200
    sw   t0, MTIMECMP_LO(s1)
    li   t0, 1
    sw   t0, TMR_CTRL(s1)       /* counter enable */

    li   t0, MIE_MTIE
    csrw mie, t0
    li   t0, MSTATUS_MIE
    csrs mstatus, t0

    li   s4, 0
1:  andi t0, s2, 1
    bnez t0, 2f
    addi s4, s4, 1
    li   t1, 20000
    blt  s4, t1, 1b
    li   a0, 1
    j    fail                   /* the timer interrupt never arrived */
2:

    /* ---- 2: WFI wakes on an interrupt ------------------------------ */
    sw   zero, MTIMECMP_HI(s1)
    lw   t0, 0(s1)              /* current mtime low */
    addi t0, t0, 100
    sw   t0, MTIMECMP_LO(s1)
    andi s2, s2, ~1             /* clear the timer flag */
    wfi
    andi t0, s2, 1
    li   a0, 2
    beqz t0, fail               /* WFI returned without the interrupt */

    /* ---- 3: external interrupt through the interrupt controller ---- */
    li   t0, -1
    sw   t0, MTIMECMP_HI(s1)
    sw   t0, MTIMECMP_LO(s1)    /* silence the timer */

    li   t0, 1
    sw   t0, IRQC_ENABLE(s3)    /* source 0 = safety controller */
    sw   zero, IRQC_MODE(s3)    /* level sensitive */

    li   t0, MIE_MEIE
    csrw mie, t0

    csrwi 0x7c1, 2              /* software fault -> safety irq */

    li   s4, 0
3:  andi t0, s2, 2
    bnez t0, 4f
    addi s4, s4, 1
    li   t1, 20000
    blt  s4, t1, 3b
    li   a0, 3
    j    fail
4:

    /* ---- 4: software interrupt ------------------------------------- */
    li   t0, MIE_MSIE
    csrw mie, t0
    li   t0, 1
    sw   t0, IRQC_MSIP(s3)

    li   s4, 0
5:  andi t0, s2, 4
    bnez t0, 6f
    addi s4, s4, 1
    li   t1, 20000
    blt  s4, t1, 5b
    li   a0, 4
    j    fail
6:
    csrw mie, zero              /* interrupts off for the rest */
    li   t0, MSTATUS_MIE
    csrc mstatus, t0
    li   t0, -1
    sw   t0, 0(s0)              /* clear the safety status */

    /* ---- 5: watchdog services correctly ---------------------------- */
    li   s5, WDOG_BASE
    li   t0, 3000
    sw   t0, WD_PERIOD(s5)
    li   t0, 1                  /* enable, no window, no reset request */
    sw   t0, WD_CTRL(s5)

    li   s4, 0
7:  li   t0, KEY_A              /* service: two step key */
    sw   t0, WD_SERVICE(s5)
    li   t0, KEY_B
    sw   t0, WD_SERVICE(s5)
    addi s4, s4, 1
    li   t1, 8
    blt  s4, t1, 7b

    lw   t0, 0(s0)              /* safety status: the watchdog bit is 6 */
    srli t0, t0, 6
    andi t0, t0, 1
    li   a0, 5
    bnez t0, fail               /* a correctly serviced watchdog must be quiet */

    /* ---- 6: watchdog times out when it is not serviced -------------- */
    li   t0, 200
    sw   t0, WD_PERIOD(s5)      /* short period, restarts the counter */

    li   s4, 0
8:  addi s4, s4, 1
    li   t1, 4000
    blt  s4, t1, 8b

    lw   t0, 0(s0)
    srli t0, t0, 6
    andi t0, t0, 1
    li   a0, 6
    beqz t0, fail               /* it should have fired by now */

    sw   zero, WD_CTRL(s5)      /* disable it again */
    li   t0, -1
    sw   t0, 0(s0)

    /* ---- 7: memory BIST over the D-TCM ------------------------------
     * Destructive, and it blocks the D-TCM while it runs -- but this
     * loop only touches peripherals and the I-TCM, so the core keeps
     * running.  Nothing below uses the D-TCM.
     */
    li   s6, MBIST_BASE
    li   t0, 1
    sw   t0, MB_D_CTRL(s6)      /* start */

    li   s4, 0
9:  lw   t0, MB_D_STATUS(s6)
    andi t1, t0, 2              /* done */
    bnez t1, 10f
    addi s4, s4, 1
    li   t1, 200000
    blt  s4, t1, 9b
    li   a0, 7
    j    fail                   /* BIST never finished */
10:
    andi t1, t0, 4              /* fail */
    li   a0, 8
    bnez t1, fail               /* a good memory must not report a failure */

pass:
    li   t0, EXIT_REG
    sw   zero, 0(t0)
11: j    11b

fail:
    li   t0, EXIT_REG
    sw   a0, 0(t0)
12: j    12b

    /* ------------------------------------------------------------------
     * Trap handler.  Interrupts set a bit in s2 and silence their
     * source; exceptions skip the faulting instruction.
     * ------------------------------------------------------------------ */
trap_handler:
    csrr t6, mcause
    bltz t6, irq_path           /* mcause[31] set => interrupt */

    csrr t6, mepc
    addi t6, t6, 4
    csrw mepc, t6
    mret

irq_path:
    andi t5, t6, 0x1f
    li   t4, 7
    beq  t5, t4, irq_timer
    li   t4, 11
    beq  t5, t4, irq_ext
    li   t4, 3
    beq  t5, t4, irq_soft
    mret                        /* unexpected cause: ignore */

irq_timer:
    li   t4, TIMER_BASE
    li   t3, -1
    sw   t3, MTIMECMP_LO(t4)
    sw   t3, MTIMECMP_HI(t4)
    ori  s2, s2, 1
    mret

irq_ext:
    li   t4, SAFETY_BASE
    li   t3, -1
    sw   t3, 0(t4)              /* clear the sticky status, drops the irq */
    ori  s2, s2, 2
    mret

irq_soft:
    li   t4, IRQC_BASE
    sw   zero, IRQC_MSIP(t4)
    ori  s2, s2, 4
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
