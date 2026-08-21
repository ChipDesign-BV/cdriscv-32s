/* SPDX-FileCopyrightText: 2026 ChipDesign B.V.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Peripheral register read-back.
 *
 * Coverage showed a whole class of lines that had never executed: the
 * read arms of the APB decoders.  Software had written plenty of these
 * registers and read a few, so most of the read multiplexer had never
 * been selected.  A read arm that decodes to the wrong register is
 * invisible to every test that only ever writes.
 *
 * Each block also gets one read and one write at an offset inside its
 * own 256-byte slot that decodes to nothing.  Those are the `default`
 * arms, and unlike the state machine defaults elsewhere in the design
 * they are genuinely reachable: nothing stops software addressing an
 * unmapped offset.  A read must return zero and a write must not
 * disturb anything.
 *
 * The test writes a distinctive value, reads it back and compares, so
 * a decoder that returns the right *kind* of value from the wrong
 * register still fails.  Nothing here enables a block that could
 * reset the core: the watchdog is configured but never started, and
 * the BIST is only read, because running it destroys the memory the
 * test is executing from.
 *
 * Each failing check writes its own number to the exit register.
 */

    .equ EXIT_REG,  0x20000f00

    .equ SAFETY,    0x20000000
    .equ WDOG,      0x20000100
    .equ TIMER,     0x20000200
    .equ AMS,       0x20000400
    .equ MBIST,     0x20000500
    .equ IRQC,      0x20000600

    .equ UNMAPPED,  0x9c            /* inside every slot, decoded by none */

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
    la   s7, unexpected         /* any trap that was not asked for */

    /* ---- machine timer -------------------------------------------- */
    li   s0, TIMER
    li   t0, 0x0000cafe
    sw   t0, 0x08(s0)           /* MTIMECMP_LO */
    lw   t1, 0x08(s0)
    li   a0, 1
    bne  t1, t0, fail

    li   t0, 1
    sw   t0, 0x10(s0)           /* CTRL: counter enable */
    lw   t1, 0x10(s0)
    li   a0, 2
    bne  t1, t0, fail
    sw   zero, 0x10(s0)         /* leave it stopped again */

    lw   t1, UNMAPPED(s0)
    li   a0, 3
    bnez t1, fail
    li   t0, -1
    sw   t0, UNMAPPED(s0)       /* must decode to nothing */
    lw   t1, 0x08(s0)
    li   t0, 0x0000cafe
    li   a0, 4
    bne  t1, t0, fail

    /* ---- watchdog: configured, deliberately never started --------- */
    li   s0, WDOG
    li   t0, 0x00001234
    sw   t0, 0x04(s0)           /* PERIOD */
    lw   t1, 0x04(s0)
    li   a0, 5
    bne  t1, t0, fail

    lw   t1, 0x00(s0)           /* CTRL: must still read disabled */
    li   a0, 6
    bnez t1, fail

    lw   t1, UNMAPPED(s0)
    li   a0, 7
    bnez t1, fail

    /* ---- interrupt controller ------------------------------------- */
    li   s0, IRQC
    li   t0, 0x0000a5a5
    sw   t0, 0x04(s0)           /* ENABLE */
    lw   t1, 0x04(s0)
    li   a0, 8
    bne  t1, t0, fail

    li   t0, 1
    sw   t0, 0x0c(s0)           /* MSIP: software interrupt, mie is off */
    lw   t1, 0x0c(s0)
    li   a0, 9
    bne  t1, t0, fail
    sw   zero, 0x0c(s0)

    sw   zero, 0x04(s0)         /* disable the sources again */
    lw   t1, UNMAPPED(s0)
    li   a0, 10
    bnez t1, fail

    li   t0, -1                 /* write decode default arm */
    sw   t0, UNMAPPED(s0)
    lw   t1, 0x04(s0)
    li   a0, 11
    bnez t1, fail               /* ENABLE must still read back cleared */

    /* ---- safety controller: read the reset reaction mask ---------- */
    li   s0, SAFETY
    lw   t1, 0x0c(s0)           /* REACT_RST, left as configured */
    li   a0, 12
    bnez t1, fail               /* nothing has enabled a reset reaction */

    lw   t1, UNMAPPED(s0)
    li   a0, 13
    bnez t1, fail

    li   t0, -1                 /* write decode default arm */
    sw   t0, UNMAPPED(s0)
    lw   t1, 0x0c(s0)
    li   a0, 14
    bnez t1, fail               /* REACT_RST must be untouched */

    /* ---- memory BIST: read only ----------------------------------- */
    li   s0, MBIST
    lw   t1, 0x00(s0)           /* CTRL is write only, reads as zero */
    li   a0, 15
    bnez t1, fail

    lw   t1, 0x08(s0)           /* FAILADR, no BIST has run */
    li   a0, 16
    bnez t1, fail
    lw   t1, 0x0c(s0)           /* FAILDAT */
    li   a0, 17
    bnez t1, fail

    /* Slot 5 is not like the others.  Each of the two BIST controllers
     * claims sixteen bytes -- paddr[7:4] against its RegBase -- and the
     * subsystem raises a slave error for anything in the slot that
     * neither claims.  So the unmapped offset here must *trap*, and
     * checking that is worth more than skipping the slot. */
    li   s6, 0
    la   s7, 1f
    lw   t1, UNMAPPED(s0)
1:  li   a0, 18
    li   t0, 5                  /* load access fault */
    bne  s6, t0, fail
    la   s7, unexpected

    /* Run the D-TCM BIST.  It had never been started from software, and
     * a read-back check needs something that is not zero to compare
     * against -- every BIST register reads zero until one has run, so
     * "the unmapped offset reads zero" would otherwise be true for the
     * mapped ones too and discriminate nothing.
     *
     * This destroys the D-TCM contents.  Safe here only because this
     * test keeps everything in registers and never touches it. */
    li   t0, 1
    sw   t0, 0x40(s0)           /* D-TCM CTRL: start */
2:  lw   t1, 0x44(s0)           /* STATUS */
    andi t2, t1, 2              /* done */
    beqz t2, 2b
    andi t2, t1, 4              /* fail */
    li   a0, 19
    bnez t2, fail

    /* The check bits of the failing word, added for V0-F1.  The BIST
     * above passed, so there is no failing word and this must read
     * zero -- what it exercises here is the decode and the read arm,
     * both of which are new: each controller now claims 32 bytes
     * rather than 16, which is what makes an offset of 0x10 reachable
     * at all. */
    lw   t1, 0x50(s0)           /* D-TCM FAILDATH */
    li   a0, 18
    bnez t1, fail

    /* An offset inside the claimed 32 bytes that decodes to nothing.
     * This used to be unreachable and was waived as W2c: when each
     * controller claimed only 16 bytes, a word access could only ever
     * produce 0x0, 0x4, 0x8 or 0xc and every one of them had an arm.
     * Widening the claim to 32 bytes for FAILDATH made 0x14, 0x18 and
     * 0x1c reachable, so the waiver no longer holds and this is a test
     * instead. */
    lw   t1, 0x54(s0)
    li   a0, 19
    bnez t1, fail

    /* Inside a claimed range, an offset the controller does not decode
     * reads as zero.  Only offsets 0, 4, 8 and 0xc exist and a word
     * access can only ever produce those, so this needs a byte read.
     * STATUS is non-zero now, which is what makes the pair of reads
     * below mean something. */
    lbu  t1, 0x44(s0)
    li   a0, 22
    beqz t1, fail               /* decoded: must not read zero */
    lbu  t1, 0x41(s0)
    li   a0, 23
    bnez t1, fail               /* not decoded: must read zero */

    /* ---- AMS interface -------------------------------------------- */
    li   s0, AMS
    li   t0, 0x00000640
    sw   t0, 0x04(s0)           /* PERIOD */
    lw   t1, 0x04(s0)
    li   a0, 24
    bne  t1, t0, fail

    li   t0, 0x0000000d
    sw   t0, 0x08(s0)           /* CHMASK */
    lw   t1, 0x08(s0)
    li   a0, 25
    bne  t1, t0, fail

    li   t0, 0x0f2c0111         /* LIMIT 0: low 0x0111, high 0x0f2c */
    sw   t0, 0x30(s0)
    lw   t1, 0x30(s0)
    li   a0, 26
    bne  t1, t0, fail

    li   t0, 0x00000fa0
    sw   t0, 0x58(s0)           /* TIMEOUT */
    lw   t1, 0x58(s0)
    li   a0, 27
    bne  t1, t0, fail

    sw   zero, 0x08(s0)         /* no channels, so nothing converts */
    lw   t1, UNMAPPED(s0)
    li   a0, 28
    bnez t1, fail

    /* ---- done ----------------------------------------------------- */
    li   a0, 0
fail:
    li   t0, EXIT_REG
    sw   a0, 0(t0)
2:  j    2b

unexpected:
    li   a0, 98
    j    fail

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
