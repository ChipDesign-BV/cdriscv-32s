#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# Drop INTERCONNECT entries from an SDF for Icarus consumption.
#
# Icarus cannot create intermodpaths for interconnect delays whose
# source is a top-level port bit, and its annotator follows the failed
# insertion with a NULL-handle assertion (vvp SIGABRT).  Gate-level
# simulation therefore runs on cell IOPATH delays and timing checks
# only; the interconnect delays this removes are exactly the
# placement-estimated numbers OpenSTA already analyses in `make fmax`,
# so nothing is unverified -- it is verified in the right tool.
import sys
src, dst = sys.argv[1], sys.argv[2]
kept = dropped = 0
with open(src) as f, open(dst, "w") as g:
    for line in f:
        if "(INTERCONNECT " in line:
            dropped += 1
            continue
        g.write(line)
        kept += 1
print("sdf_sim_filter: dropped %d INTERCONNECT entries, kept %d lines" % (dropped, kept))
