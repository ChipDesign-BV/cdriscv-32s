# cdriscv-32s

**A 32-bit RISC-V core subsystem for safety-critical mixed-signal SoCs.**

**On the name.** The `s` denotes what the part is *designed for*, not what
it has been *certified as*. It is an architectural statement — dual-core
lockstep, SEC-DED memories, configuration parity, a watchdog and a clock
monitor are in the design because safety-critical use is the target — and
it carries no compliance claim whatsoever. The distinction is the same one
the banner below draws between "verified for project use" and "not
qualified for safety-critical use": intent is not qualification, and
neither implies the other. A reader who notices the tension between a
safety-oriented name and a disclaimer of any safety claim is reading
correctly; both statements are true because they describe different
things.

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
> the 25 MHz integration target across all three PVT corners** (setup
> +2.698 ns worst, hold +0.133 ns worst, TNS 0 on the routed netlist).
> An earlier closure figure against a shorter target was typical-corner
> only and was withdrawn in V45. Twelve
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

**State: DRC clean, LVS matches, setup and hold both met at all three
corners** — at **25 MHz on a 1330 x 2521 um rectangular die (3.353 mm²,
V52)** — the main configuration, and the one to design against. A
1.90 mm square (3.610 mm²) is also closed and is kept as the more
conservative alternative. The flow runs floorplan -> PDN -> placement ->
CTS -> detailed routing -> extraction -> IR-drop -> streamout -> DRC ->
LVS.

The rectangle is worth 7.1 % of the area against the square at the same
frequency and on the same fabric. It is not a geometry trick — die area is instance area over
utilization — it is that six macros in two full-width rows leave a
square with four corner regions the placer fills badly, and leave a
rectangle with two contiguous bands. Utilization goes 0.445 -> 0.587.

| Gate | Result |
|---|---|
| Detailed routing | 0 violations |
| Antenna, post-route | **0 nets, 0 pins** |
| **DRC** (IHP KLayout signoff deck) | **clean** |
| GDS XOR (Magic vs KLayout streamouts) | **0 differences** |
| **LVS** (netgen) | **circuits match uniquely** — 95 962 devices, 49 499 nets |
| Setup, 3 corners | slow **+2.698 ns**, typ +13.70, fast +20.05; TNS 0 |
| **Hold**, 3 corners | **closed** — fast **+0.133 ns**, typ +0.348, slow +0.704; TNS 0 |
| TCM split-macro mapping | **verified functionally** — 6 600-check equivalence vs the behavioural TCM, mutation-proved (V49); `make block-tcm` |
| Max slew / max cap | **not gated by the flow** — 791 slew pins (slow, up from 527) and 64 cap pins; see V46/V48 |

**Area (V48, V52).** The die is **1330 × 2521 µm (3.353 mm²)** at
**58.7 % placement utilization**, 71.7 % once the antenna diodes are in.
Three changes got there from the original 2.40 mm square: the TCM check
bits moved into their own `4096x8` macros so no array bit is wasted
(macro area 1.967 → 1.337 mm², −32 %), the die shrank around them
(2.40 mm → 1.90 mm square), and then the square became a rectangle one
macro row wide (3.61 → 3.353 mm², −7.1 %).

The floor is bracketed to **1.2 %**: 3.312 mm² fails and 3.353 mm² signs
off. It is set by antenna-diode legalisation — not routing congestion,
which sits at 19 % usage with zero overflow — because ~46 700 diodes each
need a free site beside the pin they protect. Treat it as a cliff: a
clean congestion report says nothing about whether the diodes will fit.

**This is not a tapeout.** No clock-tree review, signal integrity, ESD,
packaging or test structures; the FMEDA still runs on assumed failure
rates. What it is: evidence that the RTL hardens, that the layout
matches the netlist that was verified, and that the timing claim
survives the corner that matters.

| | Main configuration |
|---|---|
| Die | 1330 × 2521 µm (**3.353 mm²**) — 39.9 % SRAM macros, 17.4 % standard cells, 7.6 % antenna diodes, the rest fill and routing. Placement utilisation 58.7 %, 71.7 % with the diodes placed |
| Content | 95 958 standard cells (of which **12 666 are timing-repair buffers** and **46 689 are antenna diodes**), **6 SRAM macros**, 85 176 fill |
| Memories | per TCM: `RM_IHPSG13_1P_2048x32` × 2 (data) + `RM_IHPSG13_1P_4096x8` × 1 (check bits); banded, 10 µm halos |
| Clock | **40 ns (25 MHz)** |
| IR drop | worst-case 1.20 V — negligible |

**A correction worth keeping.** An early run met its constraint at the
typical corner while missing **by 8.99 ns at slow** (1.08 V, 125 °C),
3 636 register-to-register paths failing, because the script read a
single Liberty file. **One Liberty file is not a signoff.** The
constraint is 40 ns and `make fmax` reads all three corners, slow first,
so the binding number is the one you see. Sign off setup at slow, hold
at fast — finding V45.

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
* [doc/verification_findings.md](doc/verification_findings.md) — the evidence log, V0–V52
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
V0–V52, newest first). Summary, one line per area:

| Area | State | Evidence |
|------|-------|----------|
| Lint & structure | **clean** | `make lint lint-tb`, hard gate; waivers argued in [verif/lint/waivers.vlt](verif/lint/waivers.vlt) |
| Directed benches | **all pass** | 17 targets: blocks (ALU, SEC-DED, mul/div, clkmon), safety both halves, reactions, peripherals, traps, AMS, register walk, read-back, FENCE/FENCE.I, back-pressure |
| Co-simulation vs Spike | **O2 met** | 1 008 435 332 random instructions, 27 500 programs, zero mismatches on PC, instruction, register and memory writes (V40); plus directed and stall-sweep runs |
| Architectural suite | **85 of 85** | current `riscv-arch-test`, unmodified, built `-mno-relax` (V36); `make riscof` |
| Formal | **6 benches pass** | full proofs for SEC-DED (all 2³² words, every 1–2-bit error) and decoder (all 2³² encodings); BMC elsewhere; ungated config-parity contract proven; mutation tested |
| Coverage | **O6/O7 met** | 96.2 % line (100 % with [reviewed waivers](verif/coverage_waivers.md)), 96.2 % toggle, 100 % functional over 65 cover points (V40) |
| Fault injection | **0 SDC, 0 hangs, 0 latent** | ~10⁴ classified upsets; latent was **46.4 %** before the V37 configuration parity, zero after, detection median 2–4 cycles (V29/V33/V37); `make fi` |
| Timing | **closed at 25 MHz, 3 corners** | setup **+2.698 ns** (slow), hold **+0.133 ns** (fast), TNS 0, LVS matches uniquely (V52); the square alternative is +3.16 / +0.15 ns. `make fmax` |
| Gate level | **O8 met** | zero-delay netlist cycle-identical to RTL; smoke + 12 architectural tests on the placed netlist with SDF, signatures bit-exact vs Spike (V42/V43); `make gate gate-sdf gate-arch` |
| FMEDA | **SPFM 99.6 % / LFM 91.4 %** | under stated assumed failure rates — see [doc/fmeda.md](doc/fmeda.md) for what is measured vs assumed (V44); `scripts/fmeda.py` |
| CI | **green** | [verify.yml](.github/workflows/verify.yml): full gate on every push, gate-level/timing/fault-injection nightly |

Twelve functional defects and two flow defects were found and fixed on
the way; four tool defects were reported upstream. The wrong guesses
are preserved in the findings next to the measurements that corrected
them.
