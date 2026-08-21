#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# Removes specify/endspecify blocks from a Verilog cell library.
#
# Icarus rejects the SG13G2 models outright -- "ifnone with an
# edge-sensitive path is not supported" -- and the blocks it is choking
# on carry no information: every delay in the library is (0.0,0.0).
# They are placeholders for back-annotation, not timing.
#
# This is worth being blunt about, because "gate level simulation"
# suggests more than what this gives.  With zero delay models and no
# SDF, a gate level run checks that the *netlist* computes what the RTL
# computed, that reset brings it to a defined state, and that nothing
# goes X.  It says nothing whatever about timing.  Timing needs static
# timing analysis against the same library, which is a separate job.
#
# Deleting the block is NOT sufficient on its own, and getting this
# wrong is silent in the worst way.  The sequential models read their
# data, clock and reset from `delayed_D`, `delayed_CLK` and
# `delayed_RESET_B`, and those nets are driven *by the timing checks
# inside the specify block*.  Remove the block and nothing drives them:
# every flip-flop clocks X, for ever.  The first attempt here did
# exactly that and produced a netlist where all 4 800 multiplier
# vectors returned xxxxxxxx.
#
# So each `delayed_X` is tied to `X` as the block is removed, which is
# the standard zero-delay transformation.

import re
import sys

SPECIFY  = re.compile(r"\bspecify\b.*?\bendspecify\b", re.DOTALL)
DELAYED  = re.compile(r"\bwire\s+((?:delayed_\w+\s*,\s*)*delayed_\w+)\s*;")


def main():
    src, dst = sys.argv[1], sys.argv[2]
    text = open(src, encoding="utf-8", errors="replace").read()
    out, n = SPECIFY.subn("", text)

    # tie each delayed_X straight to X, since nothing drives them now
    ties = [0]

    def tie(m):
        names = [x.strip() for x in m.group(1).split(",")]
        lines = [m.group(0)]
        for d in names:
            base = d[len("delayed_"):]
            lines.append("  assign %s = %s;" % (d, base))
            ties[0] += 1
        return "\n".join(lines)

    out = DELAYED.sub(tie, out)
    open(dst, "w", encoding="utf-8").write(out)
    print("stripped %d specify blocks, tied %d delayed nets -> %s"
          % (n, ties[0], dst))
    return 0


if __name__ == "__main__":
    sys.exit(main())
