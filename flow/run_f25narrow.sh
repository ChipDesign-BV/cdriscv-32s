#!/bin/bash
# 25 MHz narrow-rectangle probe.  Height fixed at f50rect's 2521 um; width
# 1330 um, only 179 um wider than the 1151 um macro row.
#
# Macro gaps stay at f50rect's 40 um.  The first attempt used 29 um, which
# after the 10 um halos leaves an 8.64 um channel -- too narrow for a PDN
# strap, too wide to be left empty -- and PDN-0179 aborted the run.  Only
# the side margins changed, 125 -> 90 um.
cd /foss/designs/cdriscv-32s/flow || exit 1
export PATH=/foss/tools/verilator/bin:/foss/tools/openroad-librelane/bin:/foss/tools/magic/bin:/foss/tools/netgen/bin:/foss/tools/iverilog/bin:/foss/tools/klayout:/foss/tools/bin:$PATH
librelane --manual-pdk --pdk-root /foss/pdks --run-tag f25narrow \
          config_25mhz_narrow.json > librelane_25mhz_narrow.log 2>&1
echo "[f25narrow] exited $? at $(date +%H:%M:%S)"
