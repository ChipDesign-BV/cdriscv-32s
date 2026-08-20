#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# Reference model and vector generator for cdriscv_alu.
#
# Emits one 100-bit hex word per vector: {op[3:0], a[31:0], b[31:0],
# expected[31:0]}.  The model is written from the RISC-V specification,
# deliberately without looking at the RTL, so that it is an independent
# opinion rather than a transcription.
#
#   python3 verif/block/alu/gen_vectors.py <outfile> [random_count]

import random
import sys

M = 0xFFFFFFFF

# must match cdriscv_pkg::alu_op_e
OPS = {
    "ADD": 0, "SUB": 1, "SLL": 2, "SLT": 3, "SLTU": 4, "XOR": 5,
    "SRL": 6, "SRA": 7, "OR": 8, "AND": 9, "EQ": 10, "NE": 11,
    "GE": 12, "GEU": 13, "PASSB": 14,
}


def s32(x):
    return x - (1 << 32) if x & 0x80000000 else x


def model(op, a, b):
    sh = b & 31
    if op == "ADD":   return (a + b) & M
    if op == "SUB":   return (a - b) & M
    if op == "SLL":   return (a << sh) & M
    if op == "SRL":   return (a >> sh) & M
    if op == "SRA":   return (s32(a) >> sh) & M
    if op == "XOR":   return (a ^ b) & M
    if op == "OR":    return (a | b) & M
    if op == "AND":   return (a & b) & M
    if op == "SLT":   return 1 if s32(a) < s32(b) else 0
    if op == "SLTU":  return 1 if a < b else 0
    if op == "GE":    return 1 if s32(a) >= s32(b) else 0
    if op == "GEU":   return 1 if a >= b else 0
    if op == "EQ":    return 1 if a == b else 0
    if op == "NE":    return 1 if a != b else 0
    if op == "PASSB": return b
    raise ValueError(op)


CORNERS = [
    0x00000000, 0x00000001, 0x00000002, 0x0000001f, 0x00000020, 0x00000021,
    0x7ffffffe, 0x7fffffff, 0x80000000, 0x80000001, 0xfffffffe, 0xffffffff,
    0x55555555, 0xaaaaaaaa, 0x0000ffff, 0xffff0000,
]


def main():
    out = sys.argv[1]
    nrand = int(sys.argv[2]) if len(sys.argv) > 2 else 20000
    rng = random.Random(20260820)

    vectors = []
    for name, code in OPS.items():
        # every corner crossed with every corner
        for a in CORNERS:
            for b in CORNERS:
                vectors.append((code, a, b, model(name, a, b)))
        # random operands
        for _ in range(nrand):
            a = rng.getrandbits(32)
            b = rng.getrandbits(32)
            vectors.append((code, a, b, model(name, a, b)))
        # random operands with a corner on one side, which is where
        # sign and boundary errors live
        for _ in range(nrand // 4):
            a = rng.choice(CORNERS)
            b = rng.getrandbits(32)
            vectors.append((code, a, b, model(name, a, b)))
            vectors.append((code, b, a, model(name, b, a)))

    with open(out, "w") as f:
        for code, a, b, exp in vectors:
            word = (code << 96) | (a << 64) | (b << 32) | exp
            f.write("%025x\n" % word)
    sys.stderr.write("wrote %s, %d vectors over %d operators\n"
                     % (out, len(vectors), len(OPS)))


if __name__ == "__main__":
    main()
