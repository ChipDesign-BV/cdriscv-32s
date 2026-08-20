/* SPDX-FileCopyrightText: 2026 ChipDesign B.V.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Linker script for the Spike co-simulation programs.
 *
 * Everything -- code, data and stack -- lives in one 16 KiB region at
 * 0x80000000.  Two reasons: Spike keeps its debug module at [0,0x1000)
 * so the I-TCM cannot sit at 0 there, and a single region means the
 * co-simulation does not depend on the D-TCM decode, which is checked
 * separately.  The data master reaching the I-TCM also exercises the
 * bus arbitration, which is the interesting case.
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  MEM (rwx) : ORIGIN = 0x80000000, LENGTH = 16K
}

SECTIONS
{
  .text : { *(.text.init) *(.text*) *(.rodata*) . = ALIGN(8); } > MEM

  /* HTIF exit protocol, so that Spike terminates the run itself: a
     store to tohost ends the simulation.  In the RTL these are two
     ordinary words in the TCM and the store is an ordinary store. */
  .tohost ALIGN(8) : { *(.tohost) } > MEM
  .data : { . = ALIGN(4); *(.data*) *(.sdata*) . = ALIGN(4); } > MEM
  .bss  : { . = ALIGN(4); *(.bss*) *(.sbss*) *(COMMON) . = ALIGN(16); } > MEM
  . = ALIGN(16);
  _stack_bottom = .;
  . = . + 512;
  _stack_top = .;
  _end = .;
}
