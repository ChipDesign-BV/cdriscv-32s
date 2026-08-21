/* SPDX-FileCopyrightText: 2026 ChipDesign B.V.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Safety mechanism test, software half.
 *
 * Exercises the mechanisms an application can reach through the
 * register map: the fault injection self tests, the sticky status and
 * its masking, and the software fault trigger.  Each check that fails
 * writes its own number to the exit register, so a failure names
 * itself.
 *
 * Mechanisms that need bench-side stimulus -- stopping the clock,
 * forcing a net inside the checker core -- are not here; they belong in
 * tb_safety.sv.
 *
 * Exit code 0 = pass, otherwise the number of the check that failed.
 */

    .equ SAFETY_BASE, 0x20000000
    .equ SFT_STATUS,   0x00
    .equ SFT_ENABLE,   0x04
    .equ SFT_CTRL,     0x14
    .equ SFT_RAW,      0x20
    .equ SFT_SELFTEST, 0x24

    .equ DTCM_SCRATCH, 0x10000800
    .equ EXIT_REG,     0x20000f00

    /* fault bit numbers, from cdriscv_pkg */
    .equ FLT_LOCKSTEP,    0
    .equ FLT_ITCM_ECC_COR, 1
    .equ FLT_ITCM_ECC_UNC, 2
    .equ FLT_DTCM_ECC_COR, 3
    .equ FLT_DTCM_ECC_UNC, 4
    .equ FLT_SW,          11

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
    csrw mie, zero              /* faults must set status, not divert us */

    li   s0, SAFETY_BASE
    li   s1, DTCM_SCRATCH
    li   s11, 0                 /* trap counter */

    /* ---- 1: nothing latched out of reset --------------------------- */
    lw   t0, SFT_STATUS(s0)
    li   a0, 1
    bnez t0, fail

    /* ---- 2: lockstep comparator self test -------------------------- */
    li   t0, 1                  /* SELFTEST[0] */
    sw   t0, SFT_SELFTEST(s0)
    nop
    nop
    nop
    nop
    lw   t0, SFT_STATUS(s0)
    srli t1, t0, FLT_LOCKSTEP
    andi t1, t1, 1
    li   a0, 2
    beqz t1, fail

    /* ---- 3: status is write 1 to clear ----------------------------- */
    li   t0, -1
    sw   t0, SFT_STATUS(s0)
    lw   t0, SFT_STATUS(s0)
    li   a0, 3
    bnez t0, fail

    /* ---- 4/5: single bit ECC error is corrected and reported -------
     * Arm the injection, then store: the corruption lands on the next
     * D-TCM write, several cycles after the APB write that armed it.
     * Before the fix for V4-F1 the two had to coincide, so this check
     * could never pass.
     */
    li   t0, 0x2                /* SELFTEST[1], target D-TCM */
    sw   t0, SFT_SELFTEST(s0)
    li   t2, 0x12345678
    sw   t2, 0(s1)              /* this write gets one bit flipped */
    lw   t3, 0(s1)              /* ... and the read must correct it */
    li   a0, 4
    bne  t3, t2, fail

    lw   t0, SFT_STATUS(s0)
    srli t1, t0, FLT_DTCM_ECC_COR
    andi t1, t1, 1
    li   a0, 5
    beqz t1, fail

    li   t0, -1
    sw   t0, SFT_STATUS(s0)

    /* ---- 6/7: double bit error is detected and traps ---------------- */
    li   t0, 0x4                /* SELFTEST[2], target D-TCM */
    sw   t0, SFT_SELFTEST(s0)
    li   t2, 0x0f0f0f0f
    sw   t2, 4(s1)              /* two bits flipped */
    lw   t3, 4(s1)              /* uncorrectable: load access fault */

    li   a0, 6
    beqz s11, fail              /* the trap must have been taken */

    lw   t0, SFT_STATUS(s0)
    srli t1, t0, FLT_DTCM_ECC_UNC
    andi t1, t1, 1
    li   a0, 7
    beqz t1, fail

    li   t0, -1
    sw   t0, SFT_STATUS(s0)

    /* ---- 20/21/22/23: the same two checks against the I-TCM --------
     * The functional coverage model (objective O7) put these here.  It
     * showed the I-TCM ECC fault bits had never been set by any test,
     * only the D-TCM ones -- the self-test had been exercised through
     * one of its two targets and the other half of the mechanism was
     * unverified.  SELFTEST[3] selects the I-TCM.
     *
     * The word corrupted is data that happens to live in instruction
     * memory and is never executed, so corrupting it cannot derail the
     * test that is running out of the same memory.
     */
    la   s10, itcm_scratch

    li   t0, 0xa                /* SELFTEST[1], target I-TCM */
    sw   t0, SFT_SELFTEST(s0)
    li   t2, 0x5a5a1234
    sw   t2, 0(s10)             /* this write gets one bit flipped */
    lw   t3, 0(s10)             /* ... and the read must correct it */
    li   a0, 20
    bne  t3, t2, fail

    lw   t0, SFT_STATUS(s0)
    srli t1, t0, FLT_ITCM_ECC_COR
    andi t1, t1, 1
    li   a0, 21
    beqz t1, fail

    li   t0, -1
    sw   t0, SFT_STATUS(s0)

    li   s11, 0
    li   t0, 0xc                /* SELFTEST[2], target I-TCM */
    sw   t0, SFT_SELFTEST(s0)
    li   t2, 0x0f0f0f0f
    sw   t2, 4(s10)             /* two bits flipped */
    lw   t3, 4(s10)             /* uncorrectable: load access fault */

    li   a0, 22
    beqz s11, fail

    lw   t0, SFT_STATUS(s0)
    srli t1, t0, FLT_ITCM_ECC_UNC
    andi t1, t1, 1
    li   a0, 23
    beqz t1, fail

    li   t0, -1
    sw   t0, SFT_STATUS(s0)

    /* ---- 8: software fault trigger --------------------------------- */
    csrwi 0x7c1, 2              /* msafectrl[1] */
    nop
    nop
    nop
    nop
    lw   t0, SFT_STATUS(s0)
    srli t1, t0, FLT_SW
    andi t1, t1, 1
    li   a0, 8
    beqz t1, fail

    li   t0, -1
    sw   t0, SFT_STATUS(s0)

    /* ---- 9: a masked source must not latch -------------------------- */
    li   t0, 0                  /* ENABLE = 0: nothing contributes */
    sw   t0, SFT_ENABLE(s0)
    li   t0, 1                  /* lockstep self test again */
    sw   t0, SFT_SELFTEST(s0)
    nop
    nop
    nop
    nop
    lw   t0, SFT_STATUS(s0)
    li   a0, 9
    bnez t0, fail

    /* ...but the raw view must still show it happened is not required:
     * RAW is a live view, and the injection pulse is long gone by now.
     * Re-enable and finish.
     */
    li   t0, -1
    sw   t0, SFT_ENABLE(s0)

pass:
    li   t0, EXIT_REG
    sw   zero, 0(t0)
1:  j    1b

fail:
    li   t0, EXIT_REG
    sw   a0, 0(t0)
2:  j    2b

    /* Trap handler: count it, skip the faulting instruction, return.
     * Only t6 and s11 are touched.
     */
trap_handler:
    addi s11, s11, 1
    csrr t6, mepc
    addi t6, t6, 4
    csrw mepc, t6
    mret

    /* Two words of data living in the instruction memory, never
     * executed, used as the target of the I-TCM ECC self-test. */
    .align 2
itcm_scratch:
    .word 0, 0

    .section .data
    .align 4
pad:
    .word 0

    .section .bss
    .align 4
_stack_bottom:
    .space 512
_stack_top:
