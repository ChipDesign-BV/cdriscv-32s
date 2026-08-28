#!/bin/bash
# Wait for f50e (pgid 330989) to finish its LVS, then start the
# rectangular-die run.  Sequential deliberately: netgen is single-core
# but detailed routing uses ~8, so overlapping them would distort both.
cd /foss/designs/cdriscv-32s/flow || exit 1
export PATH=/foss/tools/verilator/bin:/foss/tools/openroad-librelane/bin:/foss/tools/magic/bin:/foss/tools/netgen/bin:/foss/tools/iverilog/bin:/foss/tools/klayout:/foss/tools/bin:$PATH
while kill -0 330989 2>/dev/null; do sleep 60; done
echo "[queue] f50e finished at $(date +%H:%M:%S), starting f50rect"
rm -rf runs/f50rect librelane_50mhz_rect.log
librelane --manual-pdk --pdk-root /foss/pdks --run-tag f50rect \
          config_50mhz_rect.json > librelane_50mhz_rect.log 2>&1
echo "[queue] f50rect exited $? at $(date +%H:%M:%S)"
