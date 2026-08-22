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
#   detected-sw     the workload itself spotted the fault and exited
#                   with its own code.  Distinct from `detected`
#                   because no safety mechanism latched anything: when
#                   the fault is the safety controller's own enable,
#                   software is the only thing left that can report.
#   silent-ok       no fault, the result was correct, and the safety
#                   configuration was left intact
#   latent          no fault, the result was correct, and yet the
#                   configuration is NOT what it should be -- an upset
#                   has switched a detector off and nothing noticed.
#                   Classified apart from silent-ok because calling it
#                   benign is exactly wrong: the workload passing is not
#                   evidence when the thing that would have complained
#                   is the thing that was hit.
#   SDC             no fault, and the result was WRONG -- silent data
#                   corruption, the number that matters most
#   hang            the workload never finished
#   sim-timeout     the simulator itself was killed for overrunning,
#                   which is a bench problem rather than a result
#   not-injected    the deposit never happened, because the injection
#                   cycle fell past the end of the workload.  Counted
#                   separately and excluded from the percentages: it is
#                   a hole in the campaign setup, not a result.
#
# The fault list is a named set of state elements, not every flop in the
# design; the report says so, because a diagnostic coverage figure means
# nothing without the fault list it was measured over.

import argparse
import collections
import concurrent.futures
import os
import random
import re
import subprocess
import sys

RFW = re.compile(r"^FIRFW (\d) (\d+)$", re.M)

RE = re.compile(r"FI target=(\d+) bit=(\d+) cycle=(\d+) exit=([0-9a-fx]+) "
                r"golden=([0-9a-f]+) exited=(\d) status=([0-9a-fX]+) inj=(\d)"
                r" cfg=([0-9a-fxX_]+)")

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
    9: "safety controller STATUS",
    10: "safety controller ENABLE",
    11: "safety controller REACT_IRQ",
    12: "safety controller REACT_RST",
    13: "safety controller CTRL.enable",
    14: "watchdog counter",
    15: "watchdog CTRL.enable",
    16: "mtvec",
    17: "mscratch",
    18: "core state machine",
    19: "lockstep delay pipeline",
    20: "clock monitor CTRL.enable",
    21: "clock monitor MIN",
    22: "clock monitor MAX",
    23: "interrupt controller ENABLE",
    24: "machine timer MTIMECMP",
    25: "AMS channel mask",
    26: "register file WRITE PATH (transient)",
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
    ap.add_argument("--ibase", type=int, default=40,
                    help="first I-TCM word of the workload's live code")
    ap.add_argument("--ispan", type=int, default=45,
                    help="how many words of live code to inject into")
    ap.add_argument("--sw-detect", default="",
                    help="exit code the workload writes when it detects a "
                         "fault itself, e.g. a configuration read-back")
    ap.add_argument("--golden-cfg", default="",
                    help="safety configuration signature from a clean run")
    ap.add_argument("--name", default="A: arithmetic and memory",
                    help="workload name, printed with the results")
    ap.add_argument("--jobs", type=int, default=(os.cpu_count() or 2),
                    help="simulations to run at once")
    ap.add_argument("--max-sim-cycle", type=int, default=50000,
                    help="give-up point for a workload that never finishes")
    args = ap.parse_args()

    # A clean reference for the configuration signature: taken from the
    # run itself rather than hard-coded, since it depends on the
    # workload.
    golden_cfg = args.golden_cfg
    rng = random.Random(args.seed)
    classes = collections.Counter()
    by_target = collections.defaultdict(collections.Counter)
    # V4-F3: what a register-write comparator would have added.  Counted
    # only where nothing else caught the fault, since a second mechanism
    # reporting an already-reported fault is worth nothing.
    would = collections.Counter()
    would_tot = collections.Counter()
    # Detection latency, in cycles from the injection.  Coverage says
    # whether a fault is found; latency says whether it is found in
    # time, and a fault tolerant time interval is spent on the second.
    lat = collections.defaultdict(list)
    mechanisms = collections.Counter()
    sdc_cases = []

    # The fault list is drawn up front from a seeded generator, so it is
    # identical whatever --jobs is set to.  The runs themselves are
    # independent processes and there is no reason to serialise them;
    # the plan asks for 10^4 injections and one at a time does not get
    # there in a working day.
    faults = [(rng.randrange(len(TARGETS)),
               rng.randrange(39),
               rng.randrange(args.min_cycle, args.max_cycle))
              for _ in range(args.runs)]

    def run_one(f):
        # A run that overruns is reported, not raised.  An uncaught
        # TimeoutExpired here takes the whole campaign down and throws
        # away every result that had already completed, which is how
        # a 1000 run campaign once returned nothing at all.
        t, b, c = f
        try:
            return subprocess.run(
                ["vvp", args.vvp, "+HEX=" + args.hex, "+DHEX=" + args.dhex,
                 "+IBASE=%d" % args.ibase, "+ISPAN=%d" % args.ispan,
                 "+MAXCYCLE=%d" % args.max_sim_cycle,
                 "+TARGET=%d" % t, "+BIT=%d" % b, "+CYCLE=%d" % c,
                 "+GOLDEN=" + args.golden],
                capture_output=True, text=True, timeout=600)
        except subprocess.TimeoutExpired:
            return None

    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        outcomes = list(pool.map(run_one, faults))

    for (t, b, c), r in zip(faults, outcomes):
        if r is None:
            classes["sim-timeout"] += 1
            by_target[t]["sim-timeout"] += 1
            continue
        m = None
        for line in r.stdout.splitlines():
            m = RE.search(line) or m
        if not m:
            classes["no-result"] += 1
            continue

        exit_v, golden, exited, status = m.group(4), m.group(5), m.group(6), m.group(7)
        st = int(status, 16) if "X" not in status.upper() else -1

        if m.group(8) == "0":
            classes["not-injected"] += 1
            continue

        if st > 0:
            cls = "detected"
            for bit, name in MECHANISM.items():
                if st & (1 << bit):
                    mechanisms[name] += 1
        elif st < 0:
            cls = "x-propagation"
        elif exited != "1":
            cls = "hang"
        elif args.sw_detect and exit_v == args.sw_detect:
            # The workload found the fault and said so.  It is a
            # detection, even though the safety controller latched
            # nothing -- and when the fault is the controller's own
            # enable, the controller latching nothing is the whole
            # point rather than a failure of this classifier.
            cls = "detected-sw"
        elif exit_v == golden:
            cls = "silent-ok" if (not golden_cfg or m.group(9) == golden_cfg) \
                  else "latent"
        else:
            cls = "SDC"
            sdc_cases.append((t, b, c, exit_v))

        classes[cls] += 1
        by_target[t][cls] += 1

        rfw = RFW.search(r.stdout)
        if rfw:
            would_tot[t] += 1
            if rfw.group(1) == "1" and cls not in ("detected", "detected-sw"):
                would[t] += 1
            if cls == "detected":
                d = int(rfw.group(2))
                if d:
                    lat[t].append(d)

    total = sum(classes.values()) - classes["not-injected"]
    print("Fault injection campaign: %d single event upsets" % total)
    print("Workload: %s" % args.name)
    print("Fault list: %d named state elements (not every flop -- see tb_fi.sv)\n"
          % len(TARGETS))
    if classes["not-injected"]:
        print("  WARNING: %d runs never injected -- the cycle range runs past\n"
              "  the end of the workload.  Excluded from the counts below."
              % classes["not-injected"])
    for cls in ("detected", "detected-sw", "silent-ok", "latent", "SDC",
                "hang", "sim-timeout",
                "x-propagation", "no-result"):
        if classes[cls]:
            print("  %-14s %4d  %5.1f %%" % (cls, classes[cls],
                                             100.0 * classes[cls] / total))
    print("\nBy target:")
    print("  %-34s %8s %5s %9s %6s %5s %5s"
          % ("state element", "detected", "sw", "silent-ok", "latent", "SDC", "hang"))
    for t in sorted(by_target):
        c = by_target[t]
        print("  %-34s %8d %5d %9d %6d %5d %5d"
              % (TARGETS[t], c["detected"], c["detected-sw"], c["silent-ok"],
                 c["latent"], c["SDC"], c["hang"] + c["sim-timeout"]))
    if lat:
        print("\nDetection latency, cycles from injection (detected runs only):")
        print("  %-34s %6s %7s %6s %6s" % ("state element", "runs", "median",
                                           "90th", "worst"))
        allv = []
        for t in sorted(lat):
            v = sorted(lat[t])
            allv.extend(v)
            print("  %-34s %6d %7d %6d %6d"
                  % (TARGETS[t], len(v), v[len(v)//2],
                     v[int(len(v) * 0.9)], v[-1]))
        allv.sort()
        if allv:
            print("  %-34s %6d %7d %6d %6d"
                  % ("ALL", len(allv), allv[len(allv)//2],
                     allv[int(len(allv) * 0.9)], allv[-1]))

    if sum(would.values()):
        print("\nUndetected faults a register-write comparator would have")
        print("caught (finding V4-F3 -- rd_addr and rf_wdata are not in the")
        print("lockstep compare vector today):")
        for t in sorted(would):
            if would[t]:
                print("  %-34s %4d of %4d" % (TARGETS[t], would[t], would_tot[t]))
        print("  %-34s %4d total" % ("", sum(would.values())))

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
