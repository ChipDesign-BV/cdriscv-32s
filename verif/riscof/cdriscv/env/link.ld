/* SPDX-FileCopyrightText: 2026 ChipDesign B.V.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Linker script for the architectural tests.
 *
 * Everything lives in the I-TCM at 0x8000_0000, which is where the
 * co-simulation bench maps it -- Spike keeps its debug module at the
 * bottom of the address space, so the instruction memory cannot sit at
 * zero there.  Code and data in one region also means the data master
 * reaches the I-TCM, which exercises the bus arbitration rather than
 * avoiding it.
 */

OUTPUT_ARCH( "riscv" )
ENTRY(rvtest_entry_point)

SECTIONS
{
  . = 0x80000000;
  .text.init : { *(.text.init) }
  . = ALIGN(0x40);
  .tohost : { *(.tohost) }
  . = ALIGN(0x40);
  .text : { *(.text) }
  . = ALIGN(0x40);
  .data : { *(.data) }
  .data.string : { *(.data.string) }
  .bss : { *(.bss) }
  _end = .;
}
