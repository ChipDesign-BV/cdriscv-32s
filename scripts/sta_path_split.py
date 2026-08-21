#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# Splits a reported timing path into "delay caused by missing buffering"
# and "delay caused by logic depth".
#
# A pre-layout netlist has no buffer tree, so a handful of high fanout
# nets dominate every path and the worst-slack number says almost
# nothing about the design.  The useful question underneath it is
# whether the *logic* would meet timing once the trees exist -- because
# depth is an RTL problem that buffering cannot fix, and fanout is a
# place-and-route problem that RTL cannot fix.
#
# The split is crude on purpose: a cell taking more than a nanosecond in
# this library is not doing logic, it is driving a crowd.  Ordinary
# gates here land around 0.15 ns.

import re
import sys

ROW = re.compile(r"^\s+(\d+\.\d+)\s+(\d+\.\d+)\s+[v^]\s+(\S+)\s+\((\S+)\)", re.M)
THRESHOLD_NS = 1.0


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "build/gate/sta.log"
    start = sys.argv[2] if len(sys.argv) > 2 else "=== setup with the reset trees cut"
    end = sys.argv[3] if len(sys.argv) > 3 else "=== summary, reset trees cut"
    text = open(path, errors="replace").read()
    try:
        body = text[text.index(start):text.index(end)]
    except ValueError:
        print("could not find the reported path in %s" % path)
        return 1

    rows = [(float(d), float(t), n, c) for d, t, n, c in ROW.findall(body)]
    if not rows:
        print("no path rows found")
        return 1

    big = [r for r in rows if r[0] > THRESHOLD_NS]
    small = [r for r in rows if r[0] <= THRESHOLD_NS]
    tot_big = sum(r[0] for r in big)
    tot_small = sum(r[0] for r in small)

    print("worst logic path: %d cells, arrival %.3f ns" % (len(rows), rows[-1][1]))
    print()
    print("  unbuffered fanout : %2d cells, %6.3f ns  (%.0f %%)"
          % (len(big), tot_big, 100.0 * tot_big / rows[-1][1]))
    for d, _, n, c in big:
        print("      %-10s %-20s %6.3f ns" % (n, c, d))
    print()
    print("  ordinary logic    : %2d cells, %6.3f ns  (mean %.3f ns/cell)"
          % (len(small), tot_small, tot_small / len(small)))
    print()
    print("  Logic depth is %.1f ns of the %.1f ns path.  Buffering is a"
          % (tot_small, rows[-1][1]))
    print("  place-and-route job; depth would be an RTL one.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
