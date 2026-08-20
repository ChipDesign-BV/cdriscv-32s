#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# Reference model and vector generator for cdriscv_multdiv.
#
# One 99-bit hex word per vector: {op[2:0], a[31:0], b[31:0], expected}.
# The model implements the RISC-V M extension semantics from the
# specification, including the two special cases the specification calls
# out: division by zero, and the signed overflow INT_MIN / -1.

import random
import sys

M = 0xFFFFFFFF
OPS = {"MUL": 0, "MULH": 1, "MULHSU": 2, "MULHU": 3,
       "DIV": 4, "DIVU": 5, "REM": 6, "REMU": 7}


def s32(x):
    return x - (1 << 32) if x & 0x80000000 else x


def model(op, a, b):
    sa, sb = s32(a), s32(b)
    if op == "MUL":    return (sa * sb) & M
    if op == "MULH":   return ((sa * sb) >> 32) & M
    if op == "MULHU":  return ((a * b) >> 32) & M
    if op == "MULHSU": return ((sa * b) >> 32) & M
    if op == "DIV":
        if b == 0:                       return M                 # -1
        if a == 0x80000000 and sb == -1: return 0x80000000        # overflow
        q = abs(sa) // abs(sb)
        return (-q if (sa < 0) != (sb < 0) else q) & M
    if op == "DIVU":
        return M if b == 0 else (a // b) & M
    if op == "REM":
        if b == 0:                       return a
        if a == 0x80000000 and sb == -1: return 0
        r = abs(sa) % abs(sb)
        return (-r if sa < 0 else r) & M
    if op == "REMU":
        return a if b == 0 else (a % b) & M
    raise ValueError(op)


CORNERS = [0x00000000, 0x00000001, 0x00000002, 0x00000003, 0x0000ffff,
           0x7ffffffe, 0x7fffffff, 0x80000000, 0x80000001, 0xfffffffe,
           0xffffffff, 0x55555555, 0xaaaaaaaa, 0x000003e8, 0x00000007]


def main():
    out = sys.argv[1]
    nrand = int(sys.argv[2]) if len(sys.argv) > 2 else 2000
    rng = random.Random(20260820)

    vectors = []
    for name, code in OPS.items():
        for a in CORNERS:
            for b in CORNERS:
                vectors.append((code, a, b, model(name, a, b)))
        for _ in range(nrand):
            a, b = rng.getrandbits(32), rng.getrandbits(32)
            vectors.append((code, a, b, model(name, a, b)))
        # small divisors, where the quotient is large
        for _ in range(nrand // 4):
            a = rng.getrandbits(32)
            b = rng.randint(1, 16)
            vectors.append((code, a, b, model(name, a, b)))

    with open(out, "w") as f:
        for code, a, b, exp in vectors:
            f.write("%025x\n" % ((code << 96) | (a << 64) | (b << 32) | exp))
    sys.stderr.write("wrote %s, %d vectors\n" % (out, len(vectors)))


if __name__ == "__main__":
    main()
