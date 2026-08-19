#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# Converts a flat binary into the 39 bit per line hex image the TCM
# model expects: each line is {parity[6:0], data[31:0]} of one word,
# using the same Hsiao code as rtl/safety/cdriscv_ecc_secded.sv.
#
#   python3 scripts/mkimage.py prog.bin prog.itcm.hex [--words N]
#
# With --flip WORD:BIT one code word bit is inverted on purpose, which
# is handy to see the ECC report a corrected or an uncorrectable error.

import argparse
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from gen_secded import build_columns, masks, check   # noqa: E402


def encode(word, m):
    parity = 0
    for r, mask in enumerate(m):
        bit = bin(word & mask).count("1") & 1
        parity |= bit << r
    return (parity << 32) | word


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("binary")
    ap.add_argument("hexfile")
    ap.add_argument("--words", type=int, default=0,
                    help="pad the image to this many words")
    ap.add_argument("--flip", default=None, metavar="WORD:BIT",
                    help="invert one code word bit, to exercise the ECC")
    args = ap.parse_args()

    cols, _ = build_columns()
    check(cols)
    m = masks(cols)

    with open(args.binary, "rb") as f:
        data = f.read()
    if len(data) % 4:
        data += b"\x00" * (4 - len(data) % 4)

    words = [int.from_bytes(data[i:i+4], "little") for i in range(0, len(data), 4)]
    cws = [encode(w, m) for w in words]

    if args.flip:
        idx, bit = (int(x, 0) for x in args.flip.split(":"))
        cws[idx] ^= 1 << bit

    while len(cws) < args.words:
        cws.append(encode(0, m))

    with open(args.hexfile, "w") as f:
        for cw in cws:
            f.write("%010x\n" % cw)

    sys.stderr.write("wrote %s, %d words\n" % (args.hexfile, len(cws)))


if __name__ == "__main__":
    main()
