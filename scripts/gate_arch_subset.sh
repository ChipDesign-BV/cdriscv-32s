#!/bin/bash
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# The O8 arch-test subset: build each test against the subsystem memory
# map, run it on the placed netlist with SDF, and compare the signature
# read back from the D-TCM banks word-for-word against the Spike
# reference riscof recorded.  Only tests fitting 16K I-TCM / 16K D-TCM
# can run; a test that does not fit is reported as SKIP, not hidden.
set -u
cd "$(dirname "$0")/.."
export PATH="/foss/tools/bin:$PATH"
SUITE=verif/riscof/riscv-arch-test/riscv-test-suite
WORK=verif/riscof/riscof_work
PASS=0; FAIL=0; SKIP=0
for spec in "$@"; do
  grp=${spec%%/*}; t=${spec##*/}
  src=$SUITE/rv32i_m/$grp/src/$t.S
  ref=$WORK/rv32i_m/$grp/src/$t.S/ref/Reference-spike.signature
  b=build/gate/arch_$t
  # The macro set is part of the test's identity: the privilege tests
  # compile their trap handler only under -Drvtest_mtrap_routine=True,
  # and without it a trap jumps to the reset value of mtvec -- address
  # zero -- and silently restarts the program.  riscof's generated
  # Makefile records the exact set per test; use it.
  MACROS=$(grep -A4 "/$t\.S" $WORK/Makefile.DUT-cdriscv | grep -oE -- "-D[a-zA-Z_0-9=]+" | sort -u | tr '\n' ' ')
  [ -z "$MACROS" ] && MACROS="-DTEST_CASE_1=True -DXLEN=32"
  # M tests need the m extension; harmless for the rest
  riscv64-unknown-elf-gcc -march=rv32im_zicsr_zifencei -mabi=ilp32 -mno-relax \
    -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
    -T verif/gate/arch/link.ld -I verif/gate/arch -I $SUITE/env \
    "$src" -o $b.elf $MACROS 2>/dev/null
  if [ ! -f $b.elf ]; then echo "SKIP  $spec (build failed / does not fit)"; SKIP=$((SKIP+1)); continue; fi
  riscv64-unknown-elf-objcopy -O binary --only-section=.text.init --only-section=.text $b.elf $b.itcm.bin
  riscv64-unknown-elf-objcopy -O binary --only-section=.data $b.elf $b.dtcm.bin
  python3 scripts/mkimage.py $b.itcm.bin $b.itcm.hex --words 4096 >/dev/null
  python3 scripts/mkimage.py $b.dtcm.bin $b.dtcm.hex --words 4096 >/dev/null
  SB=$(riscv64-unknown-elf-nm $b.elf | awk '/ begin_signature/{print $1}')
  SE=$(riscv64-unknown-elf-nm $b.elf | awk '/ end_signature/{print $1}')
  vvp build/gate/tb_sdf_subsys.vvp \
    +ITCM_HEX=$b.itcm.hex +DTCM_HEX=$b.dtcm.hex \
    +SDF=build/gate/cdriscv_subsys_pd_sim.sdf +MAX_CYCLES=60000 \
    +SIGFILE=$b.sig +SIGBEGIN=$SB +SIGEND=$SE > $b.log 2>&1
  if grep -q "\[TB-SDF\] PASS" $b.log && diff -q $b.sig "$ref" >/dev/null 2>&1; then
    C=$(grep -m1 -oE "PASS after [0-9]+ cycles" $b.log | tr -dc 0-9)
    echo "PASS  $spec ($C cycles, signature matches Spike)"
    PASS=$((PASS+1))
  else
    echo "FAIL  $spec (see $b.log)"
    FAIL=$((FAIL+1))
  fi
done
echo "gate-arch subset: $PASS pass, $FAIL fail, $SKIP skip"
[ $FAIL -eq 0 ]
