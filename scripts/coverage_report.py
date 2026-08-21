#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# Summarises a merged Verilator coverage database: overall line coverage
# for the RTL (test benches excluded, they are not the design), and a
# ranked list of where the uncovered lines are.
#
#   python3 scripts/coverage_report.py <annotated-dir> [label]
#
# Verilator's --coverage enables line *and* toggle points, and its
# annotated output marks a source line uncovered if any point attached
# to it is uncovered.  A declaration line carries toggle points, so
# reporting the two together produces a number that is neither: it was
# published as "line coverage" for several runs and was not (V7-M1).
# The Makefile now filters the database with --filter-type and calls
# this script once per metric.

import os
import sys


def rtl_basenames(root="rtl"):
    # A file counts as RTL if and only if it is in the repository's rtl
    # tree.  Matching on the name alone is not enough: the annotated
    # directory is flat and picks up whatever the simulator compiled,
    # including Verilator's own verilated_std.sv, which was silently
    # counted as design code and dragged the reported figure down by six
    # points the first time a bench pulled it in.
    names = set()
    for dirpath, _, files in os.walk(root):
        for name in files:
            if name.endswith((".sv", ".v")):
                names.add(name)
    return names


def main():
    rtl = rtl_basenames()
    root = sys.argv[1] if len(sys.argv) > 1 else "build/cov/annotated"
    label = sys.argv[2] if len(sys.argv) > 2 else "coverage"
    rows = []
    tot_cov = tot_unc = 0

    for dirpath, _, files in os.walk(root):
        for name in sorted(files):
            if not name.endswith((".sv", ".v")):
                continue
            path = os.path.join(dirpath, name)
            cov = unc = 0
            with open(path, errors="replace") as f:
                for line in f:
                    if line.startswith("%000000"):
                        unc += 1
                    elif line[:1] in "0123456789~%":
                        cov += 1
            if cov + unc == 0:
                continue
            is_tb = name not in rtl
            rows.append((name, cov, unc, is_tb))
            if not is_tb:
                tot_cov += cov
                tot_unc += unc

    total = tot_cov + tot_unc
    pct = (100.0 * tot_cov / total) if total else 0.0
    print("RTL %s: %.1f %%  (%d of %d source lines with all points covered)"
          % (label, pct, tot_cov, total))
    print()
    print("%-34s %8s %8s %7s" % ("file", "covered", "missing", "cover"))
    print("-" * 60)
    for name, cov, unc, is_tb in sorted(rows, key=lambda r: -r[2]):
        if is_tb:
            continue
        p = 100.0 * cov / (cov + unc) if (cov + unc) else 0.0
        print("%-34s %8d %8d %6.1f%%" % (name, cov, unc, p))


if __name__ == "__main__":
    sys.exit(main())
