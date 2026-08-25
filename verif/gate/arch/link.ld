/* SPDX-FileCopyrightText: 2026 ChipDesign B.V.
 * SPDX-License-Identifier: Apache-2.0
 *
 * riscv-arch-test on the subsystem memory map (verification plan O8):
 * code in the I-TCM at 0, data and the signature in the D-TCM.  Only
 * tests that fit 16K of each can run at gate level, which is the
 * subset O8 asks for, not a limitation being hidden.
 */
OUTPUT_ARCH(riscv)
ENTRY(rvtest_entry_point)
MEMORY
{
  ITCM (rx) : ORIGIN = 0x00000000, LENGTH = 16K
  DTCM (rw) : ORIGIN = 0x10000000, LENGTH = 16K
}
SECTIONS
{
  .text.init : { *(.text.init) } > ITCM
  .text      : { *(.text) *(.text.*) } > ITCM
  .data      : { *(.data) *(.data.*) *(.rodata) *(.rodata.*)
                 *(.sdata*) *(.bss) *(.sbss) *(.tohost) } > DTCM
}
