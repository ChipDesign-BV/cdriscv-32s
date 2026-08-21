#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# Fault injection campaign driver.
#
# Runs single event upsets across the fault list in verif/fi/tb_fi.sv
# and classifies each run:
#
#   detected        a safety mechanism latched a fault
#   silent-ok       no fault, and the workload result was correct
#   SDC             no fault, and the result was WRONG -- silent data
#                   corruption, the number that matters most
#   hang            the workload never finished
#
# The fault list is a named set of state elements, not every flop in the
# design; the report says so, because a diagnostic coverage figure means
# nothing without the fault list it was measured over.

import argparse
import collections
import random
import re
import subprocess
import sys

RE = re.compile(r"FI target=(\d+) bit=(\d+) cycle=(\d+) exit=([0-9a-fx]+) "
                r"golden=([0-9a-f]+) exited=(\d) status=([0-9a-fX]+)")

TARGETS = {
    0: "core register file word",
    1: "fetch buffer instruction word",
    2: "fetch program counter",
    3: "mepc",
    4: "mstatus.MIE",
    5: "LSU address offset",
    6: "I-TCM word (ECC protected)",
    7: "D-TCM word (ECC protected)",
    8: "register file parity bit",
}

MECHANISM = {
    0: "lockstep", 1: "I-TCM ECC corrected", 2: "I-TCM ECC uncorrectable",
    3: "D-TCM ECC corrected", 4: "D-TCM ECC uncorrectable",
    5: "register file parity", 6: "watchdog", 7: "clock monitor",
    8: "bus error", 9: "memory BIST", 10: "AMS", 11: "software",
    12: "core trap",
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=150)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--vvp", default="build/tb_fi.vvp")
    ap.add_argument("--hex", default="build/fi_workload.hex")
    ap.add_argument("--dhex", default="build/dtcm_zero.hex")
    ap.add_argument("--golden", default="f095470a")
    ap.add_argument("--min-cycle", type=int, default=60)
    ap.add_argument("--max-cycle", type=int, default=3000)
    args = ap.parse_args()

    rng = random.Random(args.seed)
    classes = collections.Counter()
    by_target = collections.defaultdict(collections.Counter)
    mechanisms = collections.Counter()
    sdc_cases = []

    for i in range(args.runs):
        t = rng.randrange(len(TARGETS))
        b = rng.randrange(39)
        c = rng.randrange(args.min_cycle, args.max_cycle)
        r = subprocess.run(
            ["vvp", args.vvp, "+HEX=" + args.hex, "+DHEX=" + args.dhex,
             "+TARGET=%d" % t, "+BIT=%d" % b, "+CYCLE=%d" % c,
             "+GOLDEN=" + args.golden],
            capture_output=True, text=True, timeout=600)
        m = None
        for line in r.stdout.splitlines():
            m = RE.search(line) or m
        if not m:
            classes["no-result"] += 1
            continue

        exit_v, golden, exited, status = m.group(4), m.group(5), m.group(6), m.group(7)
        st = int(status, 16) if "X" not in status.upper() else -1

        if st > 0:
            cls = "detected"
            for bit, name in MECHANISM.items():
                if st & (1 << bit):
                    mechanisms[name] += 1
        elif st < 0:
            cls = "x-propagation"
        elif exited != "1":
            cls = "hang"
        elif exit_v == golden:
            cls = "silent-ok"
        else:
            cls = "SDC"
            sdc_cases.append((t, b, c, exit_v))

        classes[cls] += 1
        by_target[t][cls] += 1

    total = sum(classes.values())
    print("Fault injection campaign: %d single event upsets" % total)
    print("Fault list: %d named state elements (not every flop -- see tb_fi.sv)\n"
          % len(TARGETS))
    for cls in ("detected", "silent-ok", "SDC", "hang", "x-propagation", "no-result"):
        if classes[cls]:
            print("  %-14s %4d  %5.1f %%" % (cls, classes[cls],
                                             100.0 * classes[cls] / total))
    print("\nBy target:")
    print("  %-34s %8s %9s %5s %5s" % ("state element", "detected", "silent-ok",
                                       "SDC", "hang"))
    for t in sorted(by_target):
        c = by_target[t]
        print("  %-34s %8d %9d %5d %5d"
              % (TARGETS[t], c["detected"], c["silent-ok"], c["SDC"], c["hang"]))
    if mechanisms:
        print("\nWhich mechanism reported (a fault may set several):")
        for name, n in mechanisms.most_common():
            print("  %-28s %4d" % (name, n))
    if sdc_cases:
        print("\nSilent data corruption cases (target, bit, cycle, result):")
        for c in sdc_cases[:10]:
            print("  %s" % (c,))
    return 0


if __name__ == "__main__":
    sys.exit(main())
