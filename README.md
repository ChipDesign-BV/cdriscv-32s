# cdriscv-32s

**A 32-bit RISC-V core subsystem for safety-critical mixed-signal SoCs.**

(c) 2026 ChipDesign B.V. — [Apache-2.0](LICENSE)

> [!IMPORTANT]
> **Verified for project use — not qualified for safety-critical use.**
>
> As of 2026-08-24 the O1–O7 gate of
> [doc/verification_plan.md](doc/verification_plan.md) is met — the
> plan's own definition of "may be used in a project". The audit, from
> runs in this repository:
>
> | # | Objective | Criterion | State |
> |---|-----------|-----------|-------|
> | O1 | ISA conformance | `riscv-arch-test` passes vs Spike | **met** — 85 of 85, current suite, unmodified |
> | O2 | golden-model random co-simulation | ≥ 10⁹ instructions, zero mismatches | **met** — 1 008 435 332 instructions, 27 500 programs, zero mismatches |
> | O3 | block benches | all directed tests pass | **met** |
> | O4 | safety mechanisms fire, and only then | fires + stays-quiet test per mechanism | **met** — benches plus ~10⁴ fault injections |
> | O5 | structural cleanliness | lint clean, documented waivers | **met** |
> | O6 | code coverage | 100 % stmt/branch, ≥ 95 % toggle, reviewed waivers | **met** — 96.2 % line (100 % with reviewed waivers), 96.2 % toggle |
> | O7 | functional coverage | cross matrices closed | **met** — 65 of 65 cover points |
>
> Also measured: configuration-register upsets hardware-detected
> (latent 46.4 % → 0), diagnostic latency median 2–4 cycles, zero
> silent data corruption over ~10⁴ injections, and **timing closed at
> the 50 MHz integration target** (worst slack +0.04 ns, TNS 0 on the
> placed and buffered netlist; 81 MHz capability when constrained
> harder). Twelve
> functional defects were found and fixed on the way; CI re-runs the
> gate on every push.
>
> **The full plan, O1–O9, now has a result for every objective.** The
> FMEDA exists ([doc/fmeda.md](doc/fmeda.md)): SPFM 99.6 %, LFM 91.4 %,
> residual 0.87 FIT — **under assumed failure rates**, clearly labeled,
> that a real safety case must replace with foundry data. An
> architectural statement, not a certification: no ISO 26262 or
> IEC 61508 compliance of any kind is claimed, and the remaining work
> (foundry FIT data, common-cause analysis, safety-case ownership) is
> listed in the document's handoff checklist. No functional
> safety claim of any kind is made, and no compliance with ISO 26262,
> IEC 61508 or any other standard. The safety mechanisms are measured,
> not certified.

## What it is

A small, deterministic RISC-V control subsystem meant to sit in the
digital corner of a mixed-signal SoC — a sensor front-end, a motor or
power controller, a battery monitor — where a failure of the control
loop has to be *detected and signalled*, not tolerated.

The design goal is not performance. It is that every structure in the
subsystem is small enough to reason about, and that a fault in it is
either detected by a mechanism that reports it, or bounded by one.

* **Core** — RV32IM_Zicsr_Zifencei, machine mode only, two stages, one
  instruction in the execute stage at a time. No forwarding, no
  speculation, no caches: every instruction has a statically known
  worst-case latency. Straight-line code retires one instruction per
  cycle (measured CPI 1.20 on a dependent ALU loop, the residual being
  the taken-branch redirect).
* **Dual core lockstep (DCLS)** — a checker core runs the same program
  delayed by a configurable number of cycles, and every output is
  compared. The delay makes the pair diverse in time, so a disturbance
  that hits both cores in the same cycle hits them in different parts of
  the program.
* **SEC-DED protected memories** — 39-bit words (Hsiao code) in both
  tightly coupled memories, single bit errors corrected, double bit
  errors reported as a bus error and as a fault.
* **March C- memory BIST** — over the raw 39-bit words, so the check bit
  storage is tested too.
* **Register file parity**, checked on every register an instruction
  actually reads.
* **Windowed watchdog** with a two step key sequence: catches servicing
  too late *and* too early, and locks its own configuration.
* **Clock monitor** in an independent reference clock domain, so it can
  report the loss of the clock it is watching.
* **Safety controller** — one sticky status bit per fault source, a
  configurable reaction per source (interrupt, warm reset, external
  error pin), a lockable configuration, and fault injection so that the
  detection paths themselves can be proven in the field.
* **Mixed-signal interface** — ADC sequencer with per-channel result
  range checking and conversion time-out, trim/DAC output, analog test
  bus control, and analog supervisor flag inputs routed into the safety
  controller. The analog domain becomes a monitored safety element
  rather than an unobserved black box.
* **APB expansion slot** for the SoC's own mixed-signal registers.

## Repository layout

| Path | Contents |
|------|----------|
| [rtl/core/](rtl/core/) | core: fetch, decode, ALU, multiply/divide, LSU, CSR, register file |
| [rtl/safety/](rtl/safety/) | lockstep, SEC-DED, safety controller, watchdog, clock monitor, memory BIST |
| [rtl/bus/](rtl/bus/) | interconnect, TCM, APB bridge |
| [rtl/periph/](rtl/periph/) | timer, interrupt controller, AMS interface |
| [rtl/common/](rtl/common/) | clock domain crossing primitives |
| [rtl/cdriscv_subsys.sv](rtl/cdriscv_subsys.sv) | subsystem top level |
| [tb/](tb/) | smoke bench and smoke program |
| [scripts/](scripts/) | ECC generator, memory image builder |
| [flow/](flow/) | LibreLane 3 hardening flow: config and wrapper |
| [doc/](doc/) | architecture, register map, safety manual draft, verification plan, integration guide |

## Physical implementation (RTL2GDS)

The subsystem hardens with **LibreLane 3** on the IHP SG13G2 PDK;
`flow/` holds the configuration and the hardening wrapper, and
`doc/integration.md` §8 is the integrator-facing summary.

```sh
cd flow && librelane --manual-pdk --pdk-root $PDK_ROOT config.json
```

**State: DRC clean, LVS matches, setup timing met at all three
corners** (V45). The flow runs floorplan → PDN → placement → CTS →
detailed routing → extraction → IR-drop → streamout → DRC → LVS.

| Gate | Result |
|---|---|
| Detailed routing | 0 violations |
| **DRC** (IHP KLayout signoff deck) | **clean** |
| GDS XOR (Magic vs KLayout streamouts) | agree |
| **LVS** (netgen) | **circuits match uniquely** — 96 645 devices, 50 485 nets |
| Setup, 3 corners | slow **+2.05 ns**, typ +13.29, fast +19.75 |
| **Hold** | **not closed**: 15 fast-corner paths, worst −0.40 ns. Resizer margin made it worse (19 paths at −0.32 before); LibreLane's Classic flow repairs timing pre-route only — see V45 |

**This is not a tapeout.** No clock-tree review, signal integrity, ESD,
packaging or test structures; the FMEDA still runs on assumed failure
rates. What it is: evidence that the RTL hardens, that the layout
matches the netlist that was verified, and that the timing claim
survives the corner that matters.

| | Reference run |
|---|---|
| Die | 2.9 × 2.9 mm (8.41 mm²), 36 % utilisation — deliberately roomy |
| Content | 49 649 standard cells, **4 SRAM macros**, 432 963 fill, 46 401 antenna diodes |
| Memories | `RM_IHPSG13_1P_2048x64` × 4, two banks per TCM, corner-placed with 10 µm halos |
| Clock | **40 ns (25 MHz)** |
| IR drop | worst-case 1.20 V — negligible |

**Why 25 MHz, and a correction.** The first full run was constrained at
20 ns and met it at the typical corner while missing **by 8.99 ns at
slow** (1.08 V, 125 °C), 3 636 register-to-register paths failing. The
earlier "closed at 50 MHz" claim came from a script that read one
Liberty file, and was wrong as a closure claim. The constraint is now
40 ns and `make fmax` reads all three corners, slow first, so the
binding number is the one you see. Sign off setup at slow, hold at
fast — finding V45.

Eleven environment and configuration obstacles were found bringing
this up, from an unparseable vendor SRAM model to the SRAM's third supply
pin (`VDDARRAY!`) and OpenROAD's undriven constant nets; each is fixed
in `flow/config.json` and explained in the findings. Two of them —
missing tie cells and the undriven constants — would have produced a
broken netlist for layout regardless of simulation, which is the
argument for running the physical flow at all.

## Documentation

* [doc/architecture.md](doc/architecture.md) — how it is built and why
* [doc/programming_manual.md](doc/programming_manual.md) — firmware view: ISA, traps, peripherals, safety duties, idioms
* [doc/register_map.md](doc/register_map.md) — address map, CSRs, every peripheral register
* [doc/integration.md](doc/integration.md) — integration manual: deliverables, checklist, ports, clocking, reset, CDC, boot, safety hooks, DFT, physical implementation
* [doc/safety_manual.md](doc/safety_manual.md) — mechanisms, assumptions of use, remaining gaps
* [doc/verification_plan.md](doc/verification_plan.md) — the objectives and their results
* [doc/verification_findings.md](doc/verification_findings.md) — the evidence log, V0–V44
* [doc/fmeda.md](doc/fmeda.md) — FMEDA: measured populations and coverage, assumed rates, derived metrics

## Building

```sh
make lint     # verilator --lint-only
make sw       # build the smoke program and its ECC encoded memory image
make sim      # iverilog + vvp, boots the smoke program
make synth    # yosys generic synthesis, area statistics
make ecc      # regenerate rtl/safety/cdriscv_ecc_secded.sv
```

Inside the IIC-OSIC-TOOLS container the tools need an explicit path:

```sh
export PATH="/foss/tools/bin:/foss/tools/verilator/bin:$PATH"
```

## Status

Every objective of [doc/verification_plan.md](doc/verification_plan.md)
has a result. The banner above audits the gate; the detail and every
number's provenance live in
[doc/verification_findings.md](doc/verification_findings.md) (phases
V0–V44, newest first). Summary, one line per area:

| Area | State | Evidence |
|------|-------|----------|
| Lint & structure | **clean** | `make lint lint-tb`, hard gate; waivers argued in [verif/lint/waivers.vlt](verif/lint/waivers.vlt) |
| Directed benches | **all pass** | 17 targets: blocks (ALU, SEC-DED, mul/div, clkmon), safety both halves, reactions, peripherals, traps, AMS, register walk, read-back, FENCE/FENCE.I, back-pressure |
| Co-simulation vs Spike | **O2 met** | 1 008 435 332 random instructions, 27 500 programs, zero mismatches on PC, instruction, register and memory writes (V40); plus directed and stall-sweep runs |
| Architectural suite | **85 of 85** | current `riscv-arch-test`, unmodified, built `-mno-relax` (V36); `make riscof` |
| Formal | **6 benches pass** | full proofs for SEC-DED (all 2³² words, every 1–2-bit error) and decoder (all 2³² encodings); BMC elsewhere; ungated config-parity contract proven; mutation tested |
| Coverage | **O6/O7 met** | 96.2 % line (100 % with [reviewed waivers](verif/coverage_waivers.md)), 96.2 % toggle, 100 % functional over 65 cover points (V40) |
| Fault injection | **0 SDC, 0 hangs, 0 latent** | ~10⁴ classified upsets; latent was **46.4 %** before the V37 configuration parity, zero after, detection median 2–4 cycles (V29/V33/V37); `make fi` |
| Timing | **closed at 50 MHz** | placed and buffered, reg2reg +1.83 ns, TNS 0; 81 MHz capability at tighter constraint (V39/V41); `make fmax` |
| Gate level | **O8 met** | zero-delay netlist cycle-identical to RTL; smoke + 12 architectural tests on the placed netlist with SDF, signatures bit-exact vs Spike (V42/V43); `make gate gate-sdf gate-arch` |
| FMEDA | **SPFM 99.6 % / LFM 91.4 %** | under stated assumed failure rates — see [doc/fmeda.md](doc/fmeda.md) for what is measured vs assumed (V44); `scripts/fmeda.py` |
| CI | **green** | [verify.yml](.github/workflows/verify.yml): full gate on every push, gate-level/timing/fault-injection nightly |

Twelve functional defects and two flow defects were found and fixed on
the way; four tool defects were reported upstream. The wrong guesses
are preserved in the findings next to the measurements that corrected
them.
