/* SPDX-FileCopyrightText: 2026 ChipDesign B.V.
 * SPDX-License-Identifier: Apache-2.0
 *
 * FENCE, FENCE.I and the writable machine CSRs.
 *
 * Coverage found this gap, and it is an uncomfortable one: the core
 * calls itself RV32IM_Zicsr_Zifencei in its own header and **no test
 * had ever executed a FENCE or a FENCE.I**.  Nor had anything written
 * mcause, mtval or msafestat, all of which are writable.
 *
 * FENCE.I is exercised over real self-modifying code: a store into the
 * I-TCM, which the address map has as "instruction fetch and data",
 * then a call.  The routine is called once before the patch and once
 * after and must return different values.
 *
 * That check does *not* prove FENCE.I was necessary, and the body of
 * the test explains at length why no check on this core can.  Saying so
 * is the point -- a test that quietly passes for the wrong reason is
 * worse than no test.
 *
 * Each failing check writes its own number to the exit register; zero
 * means every check passed.
 */

    .equ EXIT_REG, 0x20000f00
    .equ SCRATCH,  0x10000800

    .equ CSR_MSAFESTAT, 0x7c0

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

    la   sp, _stack_top
    la   t0, trap_handler
    csrw mtvec, t0
    csrw mie, zero
    la   s7, unexpected         /* any trap before one is asked for */

    /* ---- 1: FENCE does not disturb memory ordering or the pipeline -- */
    li   s0, SCRATCH
    li   t0, 0x11112222
    sw   t0, 0(s0)
    fence
    lw   t1, 0(s0)
    li   a0, 1
    bne  t1, t0, fail

    /* a register written before the fence must survive the refetch */
    li   t2, 0x5a5a0001
    fence
    li   t3, 0x5a5a0001
    li   a0, 2
    bne  t2, t3, fail

    /* and the instruction after a fence must actually execute */
    li   t4, 0
    fence
    addi t4, t4, 7
    li   a0, 3
    li   t5, 7
    bne  t4, t5, fail

    /* ---- 2: FENCE.I over genuinely self-modifying code ------------- */
    jal  ra, patch_target       /* as assembled: returns 1 in a1 */
    li   a0, 4
    li   t0, 1
    bne  a1, t0, fail

    la   t1, patch_target
    li   t2, 0x00200593         /* addi a1, zero, 2 */
    sw   t2, 0(t1)
    fence.i
    jal  ra, patch_target       /* as patched: must return 2 */
    li   a0, 5
    li   t0, 2
    bne  a1, t0, fail

    /* There is deliberately no check here that FENCE.I *had* to be
     * there, because no such check can be written on this core, and
     * the attempt is instructive.
     *
     * Replacing the FENCE.I above with a NOP leaves this test passing:
     * patch_target is far enough away that it was never in the fetch
     * buffer.  Moving the patched word closer does not help either.
     * Probed directly, with the patched word as the immediate
     * successor of the store, the stale buffered word does run -- and
     * a plain NOP in that slot fixes it just as well as a FENCE.I
     * does.  The window in which a stale instruction survives is
     * exactly one instruction wide, and inserting the FENCE.I closes
     * it by occupying that slot, whatever the FENCE.I then does.
     *
     * So FENCE.I is not observable through self-modifying code here:
     * there is no instruction cache, only a short fetch buffer.  It is
     * still doing real work -- under bus back-pressure the fetch can
     * run further ahead, and then the redirect is what saves the
     * program -- but that is an argument from the RTL, not something
     * this test demonstrates.  See finding V12-O1.
     *
     * What the checks above do establish: FENCE and FENCE.I decode
     * rather than trapping, retire, redirect without corrupting the
     * register file, and the I-TCM data write path works. */

    /* ---- 3: the writable machine CSRs ----------------------------- */
    li   t0, 0x80000007
    csrw mcause, t0
    csrr t1, mcause
    li   a0, 6
    bne  t1, t0, fail

    /* only the interrupt flag and the low five code bits exist, so a
     * write of all ones must read back masked -- if the whole word came
     * back the register would be wider than the specification allows */
    li   t0, -1
    csrw mcause, t0
    csrr t1, mcause
    li   t2, 0x8000001f
    li   a0, 7
    bne  t1, t2, fail

    li   t0, 0xdeadbeef
    csrw mtval, t0
    csrr t1, mtval
    li   a0, 8
    bne  t1, t0, fail

    /* msafestat is write-one-to-clear over whatever the safety logic
     * has posted.  Clearing must never *set* a bit that was not there;
     * asserting that rather than "reads zero" keeps the check honest
     * whether or not an event happens to be live. */
    csrr t0, CSR_MSAFESTAT
    csrw CSR_MSAFESTAT, t0
    csrr t1, CSR_MSAFESTAT
    not  t2, t0
    and  t3, t1, t2
    li   a0, 9
    bnez t3, fail

    /* ---- 4: a MISCMEM encoding that is neither FENCE nor FENCE.I --- */
    li   s6, 0
    la   s7, 1f
    .word 0x0000200f            /* opcode MISCMEM, funct3 = 010 */
1:
    li   a0, 10
    li   t0, 2                  /* mcause 2: illegal instruction */
    bne  s6, t0, fail

    /* ---- 5: two more encodings that must be rejected ---------------
     * Both came from the coverage waiver review: they had been listed
     * as unreachable defaults and they are nothing of the kind.  A
     * SYSTEM instruction with funct3 = 100 leaves csr_op undecodable,
     * and an opcode the decoder knows nothing about has to fall through
     * to the top level default.  Neither had ever been executed.
     */
    li   s6, 0
    la   s7, 2f
    .word 0x00004073            /* SYSTEM, funct3 = 100 */
2:
    li   a0, 11
    li   t0, 2
    bne  s6, t0, fail

    li   s6, 0
    la   s7, 3f
    .word 0x0000000b            /* opcode 0001011, not decoded at all */
3:
    li   a0, 12
    li   t0, 2
    bne  s6, t0, fail
    la   s7, unexpected

    /* ---- done ----------------------------------------------------- */
    li   a0, 0
fail:
    li   t0, EXIT_REG
    sw   a0, 0(t0)
2:  j    2b

unexpected:
    li   a0, 99
    j    fail

    /* Lives in .text so the store below can reach it through the
     * I-TCM's data port.  Assembled as "return 1", patched to
     * "return 2". */
    .align 2
patch_target:
    li   a1, 1
    ret

    .align 2
trap_handler:
    csrr s6, mcause
    csrw mepc, s7
    mret

    .section .bss
    .align 4
_stack_bottom:
    .space 512
_stack_top:
