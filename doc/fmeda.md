# cdriscv-32s FMEDA

**Computed 2026-08-25 by `scripts/fmeda.py` — rerun it, do not edit the
numbers here by hand.**

## 1. What this is, and what it is not

This is a Failure Modes, Effects and Diagnostic Analysis of the
subsystem at the architecture level, built from three kinds of number,
each labeled throughout:

* **MEASURED** — element populations counted from the placed netlist
  (5 658 flip-flops attributed per block by register name, 319 488
  logical SRAM bits, 39 191 cells), and diagnostic coverage from the
  fault-injection campaigns of findings V9/V29/V30/V33/V37 (~10⁴
  classified single-event upsets, zero silent data corruption, zero
  latent configuration faults after V37).
* **ASSUMED** — base failure rates. **No foundry reliability data for
  IHP SG13G2 was available to this analysis.** The rates are typical
  published figures for a 130 nm-class process at sea level:
  700 FIT/Mbit SRAM soft errors, 400 FIT/Mbit flip-flop soft errors,
  20 FIT total permanent for a ~2.6 mm² die, 2 % multi-bit-upset
  fraction. **A real safety case replaces every one of these** with
  foundry data and a mission profile; the script makes that a
  five-line edit.
* **DERIVED** — the metrics.

This document is an architectural statement, not a certification. The
metrics landing above the ASIL D thresholds means the *architecture*
carries no structural gap under the stated assumptions — it does not
mean ASIL D compliance, which additionally requires qualified tools,
process evidence, foundry data and an assessed safety case.

## 2. Result

```
cdriscv-32s FMEDA -- computed 2026-08-25
ASSUMED rates: SRAM 700 FIT/Mbit, FF 400 FIT/Mbit, permanent 20 FIT total, MBU fraction 2%

element                    lambda FIT   safe FIT    SPF FIT
TCM arrays (SEC-DED)          223.281     89.312     0.5359
core pair (lockstep)            7.081      3.186     0.0389
lockstep delay+compare          0.963      0.096     0.0866
TCM control+ECC logic           0.232      0.070     0.0081
safety controller               0.421      0.021     0.0331
watchdog                        0.019      0.001     0.0015
clock monitor                   0.320      0.032     0.0357
interrupt controller            0.208      0.042     0.0138
timer                           0.208      0.063     0.0121
AMS interface                   0.739      0.222     0.0641
memory BIST (x2)                0.258      0.155     0.0346
bus + reset sync                0.015      0.001     0.0007
TOTAL                         233.746     93.200     0.8652

SPFM = 99.63 %   (ASIL B >= 90, C >= 97, D >= 99)
LFM  = 91.42 %   (ASIL B >= 60, C >= 80, D >= 90)  [mechanism subset: 0.290 of 3.384 FIT undetected]
residual dangerous-undetected rate: 0.8652 FIT
```

**SPFM 99.6 %, LFM 91.4 %, residual 0.87 FIT** under the stated
assumptions — numerically above the ASIL D targets (SPFM ≥ 99 %,
LFM ≥ 90 %), with the caveats of section 1.

## 3. What the configuration parity is worth, in metric terms

Recomputing with the V37 configuration parity removed — single-bit
diagnostic coverage of every configuration register set to the zero
that V29 measured — gives **LFM 83.4 %**: below the ASIL D bar,
ASIL C territory. The one mechanism added in V37 is the difference
between the architecture clearing the latent-fault target and missing
it, which is the quantified form of what the campaign said in counts:
1 207 latent upsets out of 2 600 before, zero after.

## 4. Where the residual lives

Half the 0.87 FIT residual is the TCM arrays' triple-bit-and-beyond
tail past SEC-DED — reducible with layout interleaving (credit for
which is deliberately not taken here). Most of the rest is the
lockstep delay-and-compare structure and the reaction wiring of the
safety controller: the checkers themselves, which is where any DCLS
architecture's residual lives. The self-test hooks (SELFTEST, INJECT)
exist precisely to exercise these at start-up; crediting them would
raise DC on those rows and is left to the safety case.

## 5. Sensitivity

The metrics are ratios, so they are insensitive to the absolute FIT
scale (doubling every rate changes neither SPFM nor LFM). They are
sensitive to: the MBU fraction (2 % assumed; interleaving data would
justify less), the DCLS coverage figure (0.99 assumed, supported by
zero SDC in ~10⁴ injections but not proven to three nines), and the
BIST-dormancy treatment (counted mostly latent between runs; periodic
in-mission BIST would move it).

## 6. Handoff checklist for the safety-case owner

1. Replace the ASSUMED block in `scripts/fmeda.py` with foundry FIT
   data and the mission profile.
2. Decide the multi-bit story: SRAM column interleaving factor, and
   whether the software scrub (V30) is claimed for double-bit
   configuration coverage.
3. Common-cause analysis for the lockstep pair (shared clock, reset,
   voltage) — outside what fault injection can measure.
4. Credit or discard the start-up self-tests in the permanent-fault DC.
5. Re-run the script; the tables regenerate.
