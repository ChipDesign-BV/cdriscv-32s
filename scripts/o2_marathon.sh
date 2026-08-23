#!/bin/bash
# O2 grind: accumulate >= 1e9 co-simulated instructions against Spike,
# zero mismatches, in resumable batches.  Progress and every batch
# verdict land in build/o2_marathon.log; a mismatch stops the run and
# the failing seed's program is kept by random_regress.py.
set -u
cd "$(dirname "$0")/.."
export PATH="/headless/.local/bin:/foss/tools/bin:$PATH"
LOG=build/o2_marathon.log
TARGET=1000000000
TOTAL=$(grep -oE "cumulative=[0-9]+" "$LOG" 2>/dev/null | tail -1 | cut -d= -f2)
TOTAL=${TOTAL:-0}
# grep -c prints 0 AND exits 1 on no match; an `|| echo 0` fallback here
# once produced "0\n0", failed the integer test, and silently skipped the
# whole loop.  grep -c's output alone is already always a number.
BATCH=$(grep -cE ":: \[random\]" "$LOG" 2>/dev/null); BATCH=${BATCH:-0}
echo "$(date -u +%F' '%H:%M:%S) resume total=$TOTAL done=$BATCH" >> "$LOG"
while [ "$TOTAL" -lt "$TARGET" ] && [ "$BATCH" -lt 4000 ]; do
  S=$((1000 + BATCH * 500))
  OUT=$(SPIKE=/headless/verif-tools/spike/bin/spike VVP=vvp \
        python3 verif/core/random_regress.py \
        --seeds 500 --start "$S" --count 2000 --loops 20 --stall 30 \
        --vvp build/obj_cosim/tb_cosim_vl 2>&1 | tail -2 | tr '\n' ' ')
  echo "$(date -u +%H:%M:%S) batch=$BATCH start=$S :: $OUT" >> "$LOG"
  # The runner's last line is "[random] PASS" or "[random] FAIL: ...";
  # the instruction count is on the line before it.  tail -1 once caught
  # only the PASS line, failed the "programs match" test, and stopped a
  # perfectly healthy run after its first passing batch.
  case "$OUT" in
    *"programs match"*"PASS"*) : ;;
    *) echo "MISMATCH OR ERROR in batch $BATCH -- stopping" >> "$LOG"; exit 1 ;;
  esac
  N=$(echo "$OUT" | grep -oE "[0-9]+ instructions" | grep -oE "[0-9]+")
  TOTAL=$((TOTAL + ${N:-0}))
  BATCH=$((BATCH + 1))
  echo "cumulative=$TOTAL" >> "$LOG"
done
if [ "$TOTAL" -ge "$TARGET" ]; then
  echo "O2 TARGET REACHED: $TOTAL instructions, zero mismatches" >> "$LOG"
fi
