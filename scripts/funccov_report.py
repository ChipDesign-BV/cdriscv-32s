#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# Functional coverage report (objective O7).
#
# Reads a merged Verilator coverage database and summarises the `user`
# points -- the cover statements in verif/cover/cdriscv_cover.sv.  Line
# and toggle points are ignored here; they have their own report, and
# mixing the three into one number is exactly the mistake recorded as
# V7-M1.
#
# Points are summed across scopes, because the question a cover point
# asks is "was this situation ever reached", not "was it reached
# everywhere".  A scope is one hierarchical path, and there are two
# reasons the same point appears in several:
#
#   * the block really is instantiated more than once -- the two
#     lockstep cores, for instance; and
#   * the same block appears under each testbench root, so a point hit
#     in tb_cdriscv_subsys and not in tb_cosim reads as "1 of 2".
#
# The count is reported as scopes rather than instances for that
# reason: it is not a per-instance figure and should not be read as
# one.  Note also that Verilator merges identically named sibling
# instances into a wildcard scope -- the two TCMs arrive as `u_*tcm` --
# so the I-TCM and D-TCM cannot be told apart here.  Where that
# distinction matters it is covered from the safety controller side
# instead, which has a separate fault bit for each.

import collections
import re
import sys

REC = re.compile(r"^C '(.*)' (\d+)$")


def fields(blob):
    out = {}
    for part in blob.split("\x01"):
        if "\x02" in part:
            k, v = part.split("\x02", 1)
            out[k] = v
    return out


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "build/cov/merged.dat"
    groups = collections.OrderedDict()
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = REC.match(line.rstrip("\n"))
            if not m:
                continue
            f = fields(m.group(1))
            if f.get("t") != "user":
                continue
            name = f.get("o", "cover")
            page = f.get("page", "").replace("v_user/", "")
            key = (page, name)
            cnt = int(m.group(2))
            g = groups.setdefault(key, {"hits": 0, "inst": 0, "inst_hit": 0})
            g["hits"] += cnt
            g["inst"] += 1
            if cnt:
                g["inst_hit"] += 1

    if not groups:
        print("no functional coverage points found in %s" % path)
        return 1

    total = len(groups)
    hit = sum(1 for g in groups.values() if g["hits"])
    print("Functional coverage: %.1f %%  (%d of %d cover points hit)"
          % (100.0 * hit / total, hit, total))
    print()

    by_block = collections.OrderedDict()
    for (page, name), g in groups.items():
        by_block.setdefault(page, []).append((name, g))

    for page, items in by_block.items():
        h = sum(1 for _, g in items if g["hits"])
        print("%s -- %d of %d" % (page, h, len(items)))
        for name, g in items:
            if g["hits"]:
                extra = ""
                if g["inst"] > 1:
                    extra = "   [%d of %d scopes]" % (g["inst_hit"], g["inst"])
                print("    hit   %-22s %10d%s" % (name, g["hits"], extra))
            else:
                print("    MISS  %-22s %10s" % (name, "-"))
        print()

    misses = [n for (_, n), g in groups.items() if not g["hits"]]
    if misses:
        print("Uncovered situations (%d): %s" % (len(misses), ", ".join(misses)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
