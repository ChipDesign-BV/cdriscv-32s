# cdriscv-32s variant 2 — specification and status

> **STATUS: NEW AND UNVERIFIED.** Nothing in `v2/` has been through the
> O1–O9 verification gate. No module here has been simulated, formally
> proven, synthesised or hardened. Do not use it for anything.
> Variant 1 (`rtl/`) is unaffected and remains the signed-off design.

## 1. What variant 2 is

Variant 1 is `RV32IM_Zicsr_Zifencei`, machine mode only, DCLS lockstep,
SEC-DED TCMs, signed off at 25 MHz and (V50) closing 50 MHz. Variant 2
keeps that safety architecture and changes what sits inside it:

| # | Feature | Why |
|---|---|---|
| 1 | `rv32im_zba_zbb_zbs_zicsr_zifencei_zca_zcb_zcmp` | code density and bit-manipulation throughput |
| 2 | PMP + end-to-end bus protection | freedom from interference; cover the path, not just the array |
| 3 | ACT4 architectural test suite | current conformance baseline |
| 4 | Single-cycle multiplier | 32 cycles → 1 for MUL |
| 5 | CLINT at the standard memory map | unmodified RISC-V software attaches |
| 6 | JTAG TAP without `riscv-dbg` | no third-party debug IP to qualify |

**Target `-march`:**

```
-march=rv32im_zba_zbb_zbs_zicsr_zifencei_zca_zcb_zcmp -mabi=ilp32
```

Toolchain support was verified before any of this was written: GCC 16.1.0
compiles the string and emits `cm.push`/`cm.popret`; Spike 1.1.1-dev
accepts every extension individually (checked against a deliberately
bogus extension, which it correctly rejects).

## 2. Why this ISA choice

Measured on representative firmware at `-Os`, decomposed so the phasing
is evidence-based rather than assumed:

| `-march` | .text | vs baseline |
|---|---|---|
| `rv32im` (variant 1) | 1092 B | — |
| `+zba_zbb_zbs` | 952 B | −12.8 % |
| `+zca` | 750 B | −31.3 % |
| `+zba_zbb_zbs_zca_zcb` | 656 B | −39.9 % |
| **full target** | **632 B** | **−42.1 %** |

Caveat kept deliberately visible: the workload is synthetic and **Zcmp
is understated** (−3.7 % incremental) because the test functions are
shallow — push/pop-multiple pays off with deep call graphs. Measure on
the real application before committing to Zcmp.

**Code density is a safety lever here, not just a cost lever.** In
variant 1's FMEDA the TCM arrays are **223.3 of 233.7 FIT — 95.5 % of
total λ**. A 42 % smaller image permits a proportionally smaller I-TCM,
and that is the single most effective change available to the failure
rate. The saving is only real if the array actually shrinks: unread
bits still flip, and the FMEDA counts all of them.

## 3. Module status

| Module | Lines | Lint | Simulated | Proven | Notes |
|---|---|---|---|---|---|
| `cdriscv_v2_pkg.sv` | 88 | clean | — | — | types, ALU/MD/PMP encodings |
| `cdriscv_v2_alu.sv` | 136 | clean | **no** | **no** | Zba+Zbb+Zbs, 27 ops, combinational |
| `cdriscv_v2_mult.sv` | 61 | clean | **no** | **no** | single-cycle 33×33 |
| `cdriscv_v2_pmp.sv` | 131 | clean | **no** | **no** | 8 regions, TOR/NA4/NAPOT |
| `cdriscv_v2_clint.sv` | 126 | clean | **no** | **no** | standard map, parity preserved |
| `cdriscv_v2_e2e.sv` | 60 | clean | **no** | **no** | generator/checker pair |
| `cdriscv_v2_jtag_tap.sv` | 164 | clean | **no** | **no** | IEEE 1149.1, private debug DR |

**Lint-clean is not verification.** Every one of these needs block
benches, formal properties where variant 1 has them, and integration
before any claim can be made.

## 4. Design decisions worth recording

**ALU operator width.** Variant 1 used a 4-bit `alu_op_e` with 15
encodings. Zba/Zbb/Zbs add 27, so the field widens to 6 bits. Base
encodings keep their variant-1 values, so shared decoder logic reads
identically.

**Multiplier.** One 33×33 signed array serves all four M-extension
multiply variants: each operand is sign- or zero-extended per the
operation, and MUL takes the low 32 bits while MULH* take bits 63:32.
Bits 65:64 are sign extension and explicitly discarded. Division stays
iterative — a single-cycle divider is not economic here.

**PMP.** Everything works in `pmpaddr` space (byte address ≫ 2), with
the conversion happening exactly once, because mixing byte and word
addresses is the classic source of off-by-four PMP bugs. First match
wins by index — not most-permissive, not most-restrictive. A locked
entry binds machine mode; an unlocked one does not.

**E2E protection.** The TCM ECC covers the *array*. It does not cover
address decode, bus muxing or the interconnect — a fault there delivers
the wrong word, correctly ECC'd, and nothing notices. E2E carries the
check bits from producer to consumer, and **folds the address into the
check**, so the same data arriving at the wrong address fails. That is
what makes it end-to-end rather than a second data ECC. It reuses the
(39,32) Hsiao code, so the existing generator, proof and bench apply.

**CLINT.** Variant 1 already implemented the function — 64-bit
mtime/mtimecmp with spec-correct *level* interrupt semantics, plus
msip — but at APB offsets. Variant 2 is the same function at the
standard layout (`msip@0x0000`, `mtimecmp@0x4000`, `mtime@0xBFF8`).
Configuration-register parity is preserved deliberately: it is what
took latent faults from 46.4 % to zero in V37, and dropping it would
cost roughly 8 points of LFM.

**JTAG.** `riscv-dbg` is the usual answer but brings a large
third-party codebase that would need qualifying alongside the core. The
TAP here is IEEE 1149.1 with BYPASS, IDCODE and two private
instructions reaching a narrow debug bus. **A standard OpenOCD RISC-V
config will not attach** — no abstract commands, no program buffer, no
DM register map. That is the deliberate trade: nothing third-party to
qualify, at the cost of a custom adapter script.

## 5. What is NOT written yet

Honest inventory of the remaining work, largest first:

1. **Zca/Zcb/Zcmp** — the compressed extensions. Needs a 16→32
   decompressor, a **16-bit-granular IF stage** (instructions straddle
   word boundaries, and in this design straddle *ECC code words*), and a
   multi-cycle sequencer for `cm.push`/`cm.pop`. This is the single
   biggest item and touches the most safety-relevant logic.
2. **Integration** — none of the six modules is wired into a core. The
   decoder, CSR file and LSU all need extending.
3. **ACT4 migration** — suite bump plus RISCOF config; +70 tests from
   the B and C groups. **Zcb and Zcmp have no architectural tests at
   all**, so they need directed tests plus Spike co-simulation.
4. **Verification** — block benches, formal properties, fault campaign,
   FMEDA recompute. Variant 1's O1–O9 gate must be re-run in full.

## 6. Effort

Earlier bottom-up estimate for the ISA extensions and CLINT alone was
**26–34 engineer-days**, of which ~40 % is re-running the verification
gate. PMP, E2E, the multiplier and JTAG add to that. The six modules
written here are perhaps 15 % of the RTL and **0 % of the
verification**.
