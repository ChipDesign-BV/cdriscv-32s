/* SPDX-FileCopyrightText: 2026 ChipDesign B.V.
 * SPDX-License-Identifier: Apache-2.0
 *
 * cdriscv-32s -- linker script: code in the I-TCM, data in the D-TCM.
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  ITCM (rx)  : ORIGIN = 0x00000000, LENGTH = 16K
  DTCM (rw)  : ORIGIN = 0x10000000, LENGTH = 16K
}

SECTIONS
{
  .text : {
    *(.text.init)
    *(.text*)
    *(.rodata*)
    . = ALIGN(4);
  } > ITCM

  .data : {
    . = ALIGN(4);
    *(.data*)
    *(.sdata*)
    . = ALIGN(4);
  } > DTCM

  .bss : {
    . = ALIGN(4);
    *(.bss*)
    *(.sbss*)
    *(COMMON)
    . = ALIGN(4);
  } > DTCM

  _end = .;
}
