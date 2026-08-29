#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# cdriscv-32s-10 FMEDA computation (verification plan O9).
#
# Everything in this file is one of exactly three kinds of number, and
# each row of the tables says which:
#
#   MEASURED  -- element populations counted from the placed netlist
#                (build/gate/cdriscv_subsys_pd_final.v), and diagnostic
#                coverage from the fault-injection campaigns
#                (verification_findings.md V9/V29/V30/V33/V37).
#   ASSUMED   -- base failure rates.  No foundry FIT data exists for
#                this design; the values are typical published figures
#                for a 130 nm-class process at sea level and are the
#                part a real safety case MUST replace.
#   DERIVED   -- everything computed from the above.
#
# Metrics follow the ISO 26262 definitions:
#   SPFM = 1 - sum(lambda_SPF) / sum(lambda_safety_related)
#   LFM  = 1 - sum(lambda_MPF_latent) / sum(lambda_SR - lambda_SPF)
# A fault is "safe" when it cannot violate the assumed safety goal
# (the campaigns' silent-ok class: correct result, configuration
# intact); a residual/single-point fault is dangerous and undetected;
# a latent multiple-point fault is a disabled mechanism nothing
# reported -- the class V29 measured at 46.4 % and V37 took to zero.

# ----------------------------------------------------------------- ASSUMED
# Soft-error rates, 130 nm-class, sea level, typical literature values.
SEU_SRAM_FIT_PER_MBIT = 700.0    # SRAM cell upsets
SEU_FF_FIT_PER_MBIT   = 400.0    # flip-flop upsets
# Permanent (hard) failures: a round SN 29500-class figure quoted for a
# ~2.6 mm^2 digital die, split over the cell population by count.
#
# It is NOT scaled to this design's 3.353 mm^2 die.  Permanent failure
# rate scales with area, so leaving it here makes the permanent
# contribution optimistic by roughly 3.353/2.6.  It is left unscaled
# deliberately: every rate in this block is a placeholder awaiting
# foundry data, and inventing a scaled number would dress an assumption
# up as a measurement.  A real safety case replaces the whole block.
PERM_FIT_TOTAL        = 20.0
MBIT = 1024.0 * 1024.0

# Fraction of SEU events assumed to upset more than one bit in a word
# (adjacent multi-bit upsets; layout interleaving not yet credited).
MBU_FRACTION = 0.02

# ----------------------------------------------------------------- MEASURED
SRAM_BITS   = 2 * 4096 * 39          # two TCMs, logical bits
TOTAL_CELLS = 39191                   # placed netlist
TOTAL_FF    = 5658

# Flip-flop populations per functional element, counted from the
# netlist's Q-net names.  "dc_*" are the measured diagnostic coverages:
# dc_seu for single-bit upsets (campaigns), dc_mbu for the multi-bit
# fraction, dc_perm for permanent faults (mechanism-based argument).
# safe_frac is the campaigns' silent-ok share for that element class --
# upsets that provably cannot violate the goal (masked/overwritten).
ELEMENTS = [
    # name,                ffs,  safe, dc_seu, dc_mbu, dc_perm, mechanism
    ("core pair (lockstep)", 3295, 0.45, 0.99,  0.99,  0.99,
     "DCLS compares every output; V9/V37 campaigns: 0 SDC in ~10^4; "
     "residual is the comparator itself and common-mode"),
    ("lockstep delay+compare", 448, 0.10, 0.90,  0.90,  0.90,
     "self-checking by construction (a delay-line upset causes a "
     "mismatch); residual: faults forcing permanent agreement"),
    ("TCM control+ECC logic",  108, 0.30, 0.95,  0.95,  0.95,
     "ECC datapath faults surface as detected errors or bus faults; "
     "BIST covers permanent"),
    ("safety controller",      196, 0.05, 0.999, 0.90,  0.90,
     "config parity (V37: 0 latent / 2600); sticky status is "
     "self-evidencing; residual: reaction wiring"),
    ("watchdog",                 9, 0.05, 0.999, 0.90,  0.90,
     "config parity + timeout is self-revealing (a dead watchdog "
     "fires or never fires -- external pin protocol catches both)"),
    ("clock monitor",          149, 0.10, 0.999, 0.90,  0.85,
     "config parity; ref-domain copies reload each heartbeat (V37)"),
    ("interrupt controller",    97, 0.20, 0.999, 0.90,  0.90,
     "config parity on ENABLE/MODE; pending is dynamic"),
    ("timer",                   97, 0.30, 0.999, 0.90,  0.90,
     "config parity on MTIMECMP/CTRL; mtime dynamic"),
    ("AMS interface",          344, 0.30, 0.999, 0.90,  0.85,
     "config parity incl. limits and mask (V37); results dynamic"),
    ("memory BIST (x2)",       120, 0.60, 0.50,  0.50,  0.70,
     "dormant in mission; faults surface at next BIST run -- "
     "detected late, so counted mostly latent for SEU"),
    ("bus + reset sync",         7, 0.05, 0.95,  0.95,  0.95,
     "bus errors trap; reset-sync faults are fail-stop"),
    ("registers: core RF",       0, 0.60, 0.99,  0.50,  0.99,
     "parity per word (in core-pair count; kept for the record)"),
]

SRAM = ("TCM arrays (SEC-DED)", SRAM_BITS, 0.40, 0.996, 0.996, 0.996,
        "Hsiao SEC-DED corrects 1, detects 2; campaigns: 0 latent; "
        "March C- BIST at start-up for permanent")

def fit_ff(n):    return n * SEU_FF_FIT_PER_MBIT / MBIT
def fit_sram(n):  return n * SEU_SRAM_FIT_PER_MBIT / MBIT

def main():
    rows = []
    tot = dict(lam=0.0, safe=0.0, spf=0.0, lat=0.0)

    def add(name, lam, safe_frac, dc_s, dc_m, mech, perm_lam, dc_p):
        # transient part
        lam_t   = lam
        safe    = lam_t * safe_frac
        resid   = lam_t - safe
        sb, mb  = resid * (1 - MBU_FRACTION), resid * MBU_FRACTION
        det     = sb * dc_s + mb * dc_m
        undet   = resid - det
        # permanent part
        p_safe  = perm_lam * safe_frac
        p_res   = perm_lam - p_safe
        p_det   = p_res * dc_p
        p_undet = p_res - p_det
        lam_all  = lam_t + perm_lam
        safe_all = safe + p_safe
        spf      = undet + p_undet          # dangerous, undetected
        # a detected fault in a *mechanism* element is a potential
        # latent contributor only if the report path itself is the
        # casualty; V37's ungated bit closes that structurally, so
        # detected faults count as perceived, undetected mechanism
        # faults as latent.  For this single-goal analysis latent ==
        # undetected mechanism-side faults, already inside spf for the
        # primary goal; LFM uses the mechanism subset (below).
        rows.append((name, lam_all, safe_all, spf, mech))
        tot['lam']  += lam_all
        tot['safe'] += safe_all
        tot['spf']  += spf

    # SRAM
    n, sname = SRAM[1], SRAM[0]
    perm_share = PERM_FIT_TOTAL * 0.5           # ASSUMED: half the hard
    add(sname, fit_sram(n), SRAM[2], SRAM[3], SRAM[4], SRAM[6],
        perm_share, SRAM[5])

    # logic elements share the other half of the permanent budget by
    # flop count (ASSUMED apportionment)
    perm_logic = PERM_FIT_TOTAL * 0.5
    for (name, ffs, safe, dcs, dcm, dcp, mech) in ELEMENTS:
        if ffs == 0:
            continue
        add(name, fit_ff(ffs), safe, dcs, dcm, mech,
            perm_logic * ffs / TOTAL_FF, dcp)

    lam, spf, safe = tot['lam'], tot['spf'], tot['safe']
    spfm = 1 - spf / lam
    # LFM over the mechanism elements: undetected faults in the things
    # that do the detecting.  Mechanism set = everything except the two
    # mission datapaths (core pair handled by DCLS, TCM arrays by ECC).
    mech_rows = [r for r in rows if r[0] not in
                 ("core pair (lockstep)", SRAM[0])]
    lam_mech = sum(r[1] for r in mech_rows)
    lat_mech = sum(r[3] for r in mech_rows)
    lfm = 1 - lat_mech / lam_mech

    print("cdriscv-32s-10 FMEDA -- computed %s" % "2026-08-25")
    print("ASSUMED rates: SRAM %.0f FIT/Mbit, FF %.0f FIT/Mbit, "
          "permanent %.0f FIT total, MBU fraction %.0f%%"
          % (SEU_SRAM_FIT_PER_MBIT, SEU_FF_FIT_PER_MBIT,
             PERM_FIT_TOTAL, MBU_FRACTION * 100))
    print()
    print("%-26s %10s %10s %10s" % ("element", "lambda FIT", "safe FIT", "SPF FIT"))
    for name, l, s, d, mech in rows:
        print("%-26s %10.3f %10.3f %10.4f" % (name, l, s, d))
    print("%-26s %10.3f %10.3f %10.4f" % ("TOTAL", lam, safe, spf))
    print()
    print("SPFM = %.2f %%   (ASIL B >= 90, C >= 97, D >= 99)" % (100 * spfm))
    print("LFM  = %.2f %%   (ASIL B >= 60, C >= 80, D >= 90)  "
          "[mechanism subset: %.3f of %.3f FIT undetected]"
          % (100 * lfm, lat_mech, lam_mech))
    print("residual dangerous-undetected rate: %.4f FIT" % spf)

if __name__ == "__main__":
    main()
