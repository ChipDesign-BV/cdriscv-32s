// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// riscv-arch-test model hooks for the gate-level subsystem run (O8).
// Differences from verif/riscof/cdriscv/env/model_test.h, both forced
// by the target being the real subsystem rather than the cosim bench:
// the halt writes the SoC-expansion exit register instead of tohost,
// and there is no console.  RVMODEL_DATA_SECTION stays after
// end_signature -- finding V35 -- although the anchor arithmetic does
// not matter here, since the signature is compared word-for-word
// against the recorded Spike reference rather than re-derived.
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

#define RVMODEL_BOOT

// A store of zero to the exit register ends the simulation as a pass;
// the bench then reads the signature straight out of the D-TCM banks.
#define RVMODEL_HALT                                                    \
  li t0, 0x20000f00;                                                    \
  sw zero, 0(t0);                                                       \
1: j 1b;

#define RVMODEL_DATA_BEGIN                                              \
  .align 4; .global begin_signature; begin_signature:

#define RVMODEL_DATA_END                                                \
  .align 4; .global end_signature; end_signature:                       \
  RVMODEL_DATA_SECTION

#define RVMODEL_IO_INIT
#define RVMODEL_IO_WRITE_STR(_R, _STR)
#define RVMODEL_IO_CHECK()
#define RVMODEL_IO_ASSERT_GPR_EQ(_S, _R, _I)
#define RVMODEL_IO_ASSERT_SFPR_EQ(_F, _R, _I)
#define RVMODEL_IO_ASSERT_DFPR_EQ(_D, _R, _I)
#define RVMODEL_SET_MSW_INT
#define RVMODEL_CLEAR_MSW_INT
#define RVMODEL_CLEAR_MTIMER_INT
#define RVMODEL_CLEAR_MEXT_INT
#define RVMODEL_MTVEC_ALIGN 6
#endif
