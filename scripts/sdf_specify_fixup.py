#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# Keep the specify blocks, drop only what Icarus rejects.
#
# strip_specify.py removes every specify block, which is right for the
# zero-delay gate flow and fatal for the SDF one: $sdf_annotate needs
# the path declarations to attach delays to.  Icarus's actual complaint
# is narrower -- "ifnone with an edge-sensitive path is not supported"
# -- so this script removes only the `ifnone`-conditioned path
# statements (their delays are zero in the shipped model and the SDF
# overrides everything anyway) and keeps plain paths, conditioned
# paths, and the timing checks.
#
# An ifnone statement spans from the `ifnone` keyword to the `;` that
# ends its path assignment, possibly across lines.
import re, sys

src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()

out, i, removed = [], 0, 0
while True:
    j = text.find("ifnone", i)
    if j < 0:
        out.append(text[i:])
        break
    # keep everything before the keyword
    out.append(text[i:j])
    # drop up to and including the terminating semicolon
    k = text.find(";", j)
    if k < 0:
        out.append(text[j:])
        break
    removed += 1
    i = k + 1

open(dst, "w").write("".join(out))
print("sdf_specify_fixup: removed %d ifnone paths, kept the rest" % removed)
