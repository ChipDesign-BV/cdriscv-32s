// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// RISCOF target macros for cdriscv-32s.
//
// The subsystem has no console and no interrupt controller the tests
// can reach directly, so the IO macros are empty and the interrupt
// macros drive what the design does provide.  RVMODEL_HALT stores to
// `tohost`, which the bench watches: it dumps the signature region out
// of the I-TCM and finishes.  That is the only halt mechanism the tests
// need and it matches the HTIF convention the reference model uses.

#ifndef _COMPLIANCE_MODEL_H
#define _COMPLIANCE_MODEL_H

#define RVMODEL_DATA_SECTION \
        .pushsection .tohost,"aw",@progbits;                            \
        .align 8; .global tohost; tohost: .dword 0;                     \
        .align 8; .global fromhost; fromhost: .dword 0;                 \
        .popsection;                                                    \
        .align 8; .global begin_regstate; begin_regstate:               \
        .word 128;                                                      \
        .align 8; .global end_regstate; end_regstate:                   \
        .word 4;

#define RVMODEL_HALT                                                    \
  li x1, 1;                                                             \
  write_tohost:                                                         \
  sw x1, tohost, t5;                                                    \
  j write_tohost;

#define RVMODEL_BOOT

#define RVMODEL_DATA_BEGIN                                              \
  RVMODEL_DATA_SECTION                                                  \
  .align 4; .global begin_signature; begin_signature:

#define RVMODEL_DATA_END                                                \
  .align 4; .global end_signature; end_signature:                       \
  .align 4;

// No console on this subsystem: the signature is the only output.
#define RVMODEL_IO_INIT
#define RVMODEL_IO_WRITE_STR(_R, _STR)
#define RVMODEL_IO_CHECK()
#define RVMODEL_IO_ASSERT_GPR_EQ(_S, _R, _I)
#define RVMODEL_IO_ASSERT_SFPR_EQ(_F, _R, _I)
#define RVMODEL_IO_ASSERT_DFPR_EQ(_D, _R, _I)

// Software interrupt through the interrupt controller's MSIP register
// (slot 6, offset 0x0c).  The timer and external cases are cleared
// rather than set: the tests that need them are not in the RV32IM
// selection this target runs.
#define RVMODEL_SET_MSW_INT                                             \
  li t1, 1;                                                             \
  li t2, 0x2000060c;                                                    \
  sw t1, 0(t2);

#define RVMODEL_CLEAR_MSW_INT                                           \
  li t2, 0x2000060c;                                                    \
  sw x0, 0(t2);

#define RVMODEL_CLEAR_MTIMER_INT                                        \
  li t2, 0x20000208;                                                    \
  li t1, -1;                                                            \
  sw t1, 0(t2);

#define RVMODEL_CLEAR_MEXT_INT

#endif // _COMPLIANCE_MODEL_H
