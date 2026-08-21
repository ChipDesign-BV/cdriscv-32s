#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# Makes a yosys netlist readable by OpenSTA's structural Verilog parser.
#
# The memories are black boxes, and yosys writes them with their
# parameter overrides:
#
#     cdriscv_tcm #(.Depth(32'd4096), .InitFile("")) u_dtcm (...)
#
# OpenSTA has no module and no liberty cell for cdriscv_tcm, and its
# parser rejects the parameter list outright.  The parameters carry no
# timing information -- they set the array depth and a simulation
# preload file -- so removing them for the timing netlist loses nothing.
#
# The memories remain untimed either way.  Paths that start or end
# inside them are not analysed, which is correct for a black box and is
# stated in the report rather than left for the reader to notice.

import re
import sys

# Non-greedy up to the closing paren that is followed by the instance
# name: a character class excluding ")" stops at the first `.Depth(...)`
# and matches nothing at all, which it did.
INST = re.compile(r"(\bcdriscv_tcm\b)\s*#\s*\(.*?\)\s*(\w+)\s*\(", re.DOTALL)


def main():
    src, dst = sys.argv[1], sys.argv[2]
    text = open(src, encoding="utf-8", errors="replace").read()
    out, n = INST.subn(r"\1 \2 (", text)
    open(dst, "w", encoding="utf-8").write(out)
    print("stripped parameters from %d black box instances -> %s" % (n, dst))
    return 0


if __name__ == "__main__":
    sys.exit(main())
