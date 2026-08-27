#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# Generates rtl/safety/cdriscv_ecc_secded.sv: a Hsiao SEC-DED
# encoder/decoder pair.  Set PAR/DATA below: (7,32) gives the (39,32)
# code, (8,64) the (72,64) one.
#
# Hsiao construction: the 32 data columns are distinct weight-3 columns
# of a 7-row parity check matrix, chosen so that the row weights are as
# balanced as possible; the 7 check columns are the unit vectors.
#
#   * single bit error -> syndrome equals one column   -> odd weight  -> correctable
#   * double bit error -> syndrome is the XOR of two   -> even weight -> detectable
#     distinct columns, hence non-zero and of even weight
#
# The generator checks these properties before emitting anything.

import argparse
import re
import itertools
import sys

# Defaults reproduce the shipped (39,32) code; override on the command
# line for other geometries, e.g. --par 8 --data 64 for (72,64).
PAR = 7
DATA = 32
OUT = "rtl/safety/cdriscv_ecc_secded.sv"
PREFIX = "cdriscv_ecc"

def build_columns():
    # Odd-weight columns, lightest first.  (39,32) needs 32 of the 35
    # weight-3 columns available in 7 rows.  (72,64) needs 64 and only
    # C(8,3) = 56 weight-3 columns exist, so weight-5 columns make up
    # the rest -- which is what the standard (72,64) Hsiao code does.
    # Lighter columns first keeps the parity trees shallow; correctness
    # only requires odd weight, which check() enforces either way.
    cands = []
    for w in range(3, PAR + 1, 2):
        cands.extend(set(c) for c in itertools.combinations(range(PAR), w))
        if len(cands) >= DATA:
            break
    if len(cands) < DATA:
        raise SystemExit(
            f"{PAR} parity bits admit only {len(cands)} odd-weight columns, "
            f"{DATA} needed")
    row_w = [0] * PAR
    chosen = []
    remaining = list(cands)
    while len(chosen) < DATA:
        # pick the candidate that keeps the row weights most balanced
        best = min(remaining, key=lambda c: (len(c),
                                             max(row_w[r] + (r in c) for r in range(PAR)),
                                             sum((row_w[r] + (r in c)) ** 2 for r in range(PAR)),
                                             sorted(c)))
        chosen.append(best)
        remaining.remove(best)
        for r in best:
            row_w[r] += 1
    return chosen, row_w

def check(cols):
    # all columns (data + check) distinct and of odd weight
    all_cols = [frozenset(c) for c in cols] + [frozenset([i]) for i in range(PAR)]
    assert len(set(all_cols)) == len(all_cols), "columns are not distinct"
    for c in all_cols:
        assert len(c) % 2 == 1, "column weight is not odd"
    # every double error yields a non-zero even-weight syndrome
    for a, b in itertools.combinations(all_cols, 2):
        syn = a ^ b
        assert len(syn) != 0 and len(syn) % 2 == 0, "double error not detectable"
    return True

def masks(cols):
    # mask[r] has bit d set when data bit d contributes to parity bit r
    return [sum(1 << d for d, c in enumerate(cols) if r in c) for r in range(PAR)]

def parse_args():
    global PAR, DATA, OUT, PREFIX
    ap = argparse.ArgumentParser(description="generate a Hsiao SEC-DED encoder/decoder")
    ap.add_argument("--par", type=int, default=PAR, help="parity bits")
    ap.add_argument("--data", type=int, default=DATA, help="data bits")
    ap.add_argument("--prefix", default=PREFIX,
                    help="module name prefix (default: %(default)s); use a "
                         "distinct one when two geometries coexist")
    ap.add_argument("-o", "--out", default=OUT, help="output file")
    a = ap.parse_args()
    PAR, DATA, OUT, PREFIX = a.par, a.data, a.out, a.prefix


def verify_emitted(txt, dmsb, cmsb, pmsb, nib_d):
    """Check the emitted TEXT, not just the abstract code.

    check() validates the column matrix and passed happily while the
    emitter wrote 64-bit masks tagged 32'h -- which SystemVerilog
    truncates silently.  Everything below reads the emitted string back.
    """
    def need(pat, what):
        if not re.search(pat, txt):
            raise SystemExit("emit check failed: no %s" % what)

    need(r"input  logic \[%d:0\] data_i" % dmsb, "data_i[%d:0]" % dmsb)
    need(r"output logic \[%d:0\] cw_o" % cmsb, "cw_o[%d:0]" % cmsb)
    need(r"logic \[%d:0\] parity;" % pmsb, "parity[%d:0]" % pmsb)
    need(r"assign parity_in = cw_i\[%d:%d\];" % (cmsb, DATA), "parity_in slice")

    # Every mask literal must be sized DATA and fit in nib_d nibbles.
    # This is the check that would have caught the bug.
    masks_found = re.findall(r"& (\d+)'h([0-9a-f]+)\)", txt)
    if not masks_found:
        raise SystemExit("emit check failed: no mask literals")
    for size, digits in masks_found:
        if int(size) != DATA:
            raise SystemExit("emit check failed: mask sized %s, want %d"
                             % (size, DATA))
        if len(digits) > nib_d:
            raise SystemExit("emit check failed: mask %s over %d nibbles"
                             % (digits, nib_d))
    n = len(re.findall(r"assign parity\[\d+\] =", txt))
    if n != PAR:
        raise SystemExit("emit check failed: %d parity eqs, want %d" % (n, PAR))


def main():
    parse_args()
    cols, row_w = build_columns()
    check(cols)
    m = masks(cols)
    # Geometry-derived widths.  Every one of these used to be hardcoded
    # to the (39,32) case, which silently emitted a 64-bit mask tagged
    # 32'h -- SystemVerilog truncates that to the low 32 bits, so the
    # parity equations were wrong with no error anywhere.
    dmsb  = DATA - 1
    cmsb  = PAR + DATA - 1
    pmsb  = PAR - 1
    nib_d = (DATA + 3) // 4
    nib_p = (PAR + 3) // 4
    for r in range(PAR):
        assert m[r] < (1 << DATA), "mask %d wider than DATA" % r

    hdr = """// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s -- Hsiao SEC-DED code, ({cw},{data}).
//
// GENERATED by scripts/gen_secded.py -- do not edit by hand.
// Regenerate with: gen_secded.py --par {par} --data {data} -o <file>
//
// Corrects any single bit error, detects any double bit error.  The
// code is systematic: the data bits appear unchanged in the code word,
// so an encoder is parity generation only.
//
// Code word layout: {{parity[{pmsb}:0], data[{dmsb}:0]}}
// Row weights of the parity check matrix: {roww}
//
// STATUS: verified to the O1-O7 gate of doc/verification_plan.md
//         (2026-08-24) -- may be used in a project.  O8-O9 and the
//         FMEDA are open: NOT qualified for safety-critical use.

`default_nettype none

// ---------------------------------------------------------------------
// Encoder
// ---------------------------------------------------------------------
module {pfx}_enc (
    input  logic [{dmsb}:0] data_i,
    output logic [{cmsb}:0] cw_o
);

  logic [{pmsb}:0] parity;

""".format(cw=PAR + DATA, data=DATA, par=PAR, pmsb=pmsb, dmsb=dmsb,
           cmsb=cmsb, roww=row_w, pfx=PREFIX)

    body = ""
    for r in range(PAR):
        body += "  assign parity[%d] = ^(data_i & %d'h%0*x);\n" % (
            r, DATA, nib_d, m[r])
    body += """
  assign cw_o = {{parity, data_i}};

endmodule

// ---------------------------------------------------------------------
// Decoder
// ---------------------------------------------------------------------
module {pfx}_dec (
    input  logic [{cmsb}:0] cw_i,
    output logic [{dmsb}:0] data_o,
    output logic [{pmsb}:0]  syndrome_o,
    output logic        err_single_o,   // corrected
    output logic        err_double_o    // uncorrectable
);

  logic [{dmsb}:0] data_in;
  logic [{pmsb}:0]  parity_in;

  assign data_in   = cw_i[{dmsb}:0];
  assign parity_in = cw_i[{cmsb}:{data}];

""".format(cmsb=cmsb, dmsb=dmsb, pmsb=pmsb, data=DATA, pfx=PREFIX)

    for r in range(PAR):
        body += "  assign syndrome_o[%d] = parity_in[%d] ^ (^(data_in & %d'h%0*x));\n" % (
            r, r, DATA, nib_d, m[r])
    body += """
  // The syndrome of a single bit error equals that bit's column, which
  // always has odd weight; a double error gives an even, non-zero one.
  logic syndrome_nz, syndrome_odd;
  assign syndrome_nz  = |syndrome_o;
  assign syndrome_odd = ^syndrome_o;

  assign err_single_o = syndrome_nz &&  syndrome_odd;
  assign err_double_o = syndrome_nz && !syndrome_odd;

  // Correction mask: one hot on the data bit whose column matches the
  // syndrome.  A syndrome that matches a parity column corrects a
  // parity bit, which needs no action on the data output.
  logic [{dmsb}:0] flip;

""".format(dmsb=dmsb)

    for d, c in enumerate(cols):
        val = sum(1 << r for r in c)
        body += "  assign flip[%2d] = err_single_o && (syndrome_o == %d'h%0*x);\n" % (
            d, PAR, nib_p, val)
    body += """
  assign data_o = data_in ^ flip;

endmodule
"""
    out = hdr + body
    verify_emitted(out, dmsb, cmsb, pmsb, nib_d)
    with open(OUT, "w") as f:
        f.write(out)
    sys.stderr.write("wrote %s: (%d,%d) code, row weights %s\n"
                     % (OUT, PAR + DATA, DATA, row_w))

if __name__ == "__main__":
    main()
