#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# Summarises a merged Verilator coverage database: overall line coverage
# for the RTL (test benches excluded, they are not the design), and a
# ranked list of where the uncovered lines are.
#
#   python3 scripts/coverage_report.py build/cov/annotated

import os
import sys


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "build/cov/annotated"
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
            is_tb = name.startswith("tb_") or "/verif/" in path
            rows.append((name, cov, unc, is_tb))
            if not is_tb:
                tot_cov += cov
                tot_unc += unc

    total = tot_cov + tot_unc
    pct = (100.0 * tot_cov / total) if total else 0.0
    print("RTL line coverage: %.1f %%  (%d of %d lines with all points covered)"
          % (pct, tot_cov, total))
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
