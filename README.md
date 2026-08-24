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
> **What this does not claim.** O8–O9 — gate-level simulation with SDF,
> and the fault-injection data feeding an FMEDA — are the plan's gate
> for use in a *safety* context, and they are open. No functional
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
| [flow/](flow/) | LibreLane starting point (never run) |
| [doc/](doc/) | architecture, register map, safety manual draft, verification plan, integration guide |

## Documentation

* [doc/architecture.md](doc/architecture.md) — how it is built and why
* [doc/register_map.md](doc/register_map.md) — address map, CSRs, every peripheral register
* [doc/integration.md](doc/integration.md) — ports, clocking, reset, CDC, boot sequence
* [doc/safety_manual.md](doc/safety_manual.md) — draft: mechanisms, assumptions of use, known gaps
* [doc/verification_plan.md](doc/verification_plan.md) — what must be done before this IP may be used
* [doc/verification_findings.md](doc/verification_findings.md) — running log of what verification has found



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

Verification progress against [doc/verification_plan.md](doc/verification_plan.md).
Findings are logged in [doc/verification_findings.md](doc/verification_findings.md).

| Item | State | Evidence |
|------|-------|----------|
| RTL written | yes | |
| Lint (`make lint`) | **pass** | hard gate, no `-Wno-fatal`; waivers justified in [verif/lint/waivers.vlt](verif/lint/waivers.vlt) |
| Bench lint (`make lint-tb`) | **pass** | |
| Software build (`make sw`) | **pass** | `rv32im_zicsr_zifencei`, ECC encoded memory image |
| Smoke simulation (`make sim`) | **pass** | boots, 395 cycles, lockstep active, no fault raised |
| Block bench: ALU (`make block-alu`) | **pass** | 453 840 vectors vs an independent model, mutation tested |
| Block bench: SEC-DED (`make block-ecc`) | **pass** | 209 308 checks, all 39 single and all 741 double bit error positions, mutation tested |
| Block bench: mul/div (`make block-multdiv`) | **pass** | 4800 vectors, constant 33-cycle latency asserted, V0-A1 invariant checked |
| Safety mechanisms, software half (`make safety`) | **pass** | 9 checks: injection self tests, sticky status, masking, software fault |
| Safety mechanisms, bench half (`make safety-bench`) | **pass** | 7 checks: forced faults in the checker core, clock stopped/slow/fast, each with a quiet case |
| Peripherals and interrupts (`make periph`) | **pass** | 8 checks: timer, all three interrupt causes, WFI, watchdog serviced and timed out, D-TCM memory BIST |
| Safety reactions (`make reaction`) | **pass** | 9 checks: clock monitor configured through its registers, configuration lock, reset request with self-recognised restart |
| Traps and illegal encodings (`make trap`) | **pass** | 21 checks: every exception cause with mcause/mepc/mtval, one reserved encoding per opcode group, and a negative control |
| AMS interface (`make ams`) | **pass** | 12 checks: limits and range faults, conversion time-out, trim output, analog test bus |
| Register walk (`make regwalk`) | **pass** | 16 checks: timer prescaler and roll-over, interrupt edge mode and claim, watchdog window mode, safety pin registers, the unread CSRs |
| Memory back-pressure (`make cosim-stall`) | **pass** | identical streams vs Spike at 0–90 % grant stall rates; **300/300 random programs, 2 828 026 instructions** at 35 % stall |
| Architectural test suite (`make riscof`) | **85 of 85 pass** | **objective O1 met.** Current `riscv-arch-test`, unmodified: 39 I, 8 M, 22 hints, 15 privilege, 1 Zifencei. Built with `-mno-relax`, which is what makes the suite usable on a core without the C extension. The 43 `pmp` tests are dropped: they gate PMP on a clause RISCOF does not evaluate, and this core has no PMP. See V35/V36 in [verification_findings.md](doc/verification_findings.md) and [upstream-issues.md](verif/riscof/upstream-issues.md) |
| Static timing (`make sta`, `make fmax`) | **closed at 50 MHz** | OpenROAD place + repair with the TCMs as four real IHP SRAM macros, path groups reported separately: at the 20 ns target **reg2reg +1.83 ns, in2reg +4.70 ns, reg2out +0.04 ns, TNS 0**. Capability when constrained at 10 ns: 81.0 MHz reg2reg (V39), limited by fetch decode into the I-TCM macro enable — those fix options are now optional headroom. Hold (unbuffered check) **+0.184 ns** |
| Gate level simulation (`make gate`) | **3 blocks + the whole subsystem** | objective O8: ALU, multiplier and SEC-DED plus `cdriscv_subsys` synthesised to real IHP SG13G2 cells with the TCMs black-boxed — **5 433 flops, 529 175 µm²** — and four software tests run on the netlist with **cycle counts identical to RTL**. Also an illegal-state recovery check that re-argues waiver W2a against the gates. Functional only: every delay in the library is zero, so this says nothing about timing |
| Peripheral read-back (`make rdback`) | **pass** | 26 checks over six blocks. Every APB read arm, unmapped offsets, and the first software-driven memory BIST run |
| FENCE / FENCE.I / writable CSRs (`make fence`) | **pass** | 10 checks. Neither fence instruction had ever executed despite the ISA string; `mcause`, `mtval`, `msafestat` had never been written. FENCE.I is documented as **not observable** on this core — see V12-O1 |
| Block bench: clock monitor (`make block-clkmon`) | **pass** | 17 checks. Owns the clock generator, so it can stop the system clock — the only way to reach the "clock lost" path. **Found three defects: V11-F1, V11-F2, V11-F3** |
| Co-simulation vs Spike (`make cosim`) | **pass** | 208 instructions: PCs, register writes **and memory accesses** all identical, mutation tested; Verilator and Icarus agree |
| Random program co-simulation (`make cosim-random`) | **pass** | **1000/1000 programs, 16 885 968 instructions** with memory accesses compared; an earlier 2000-program run compared 33 760 012 instructions without them |
| Co-simulation at scale | **in progress** | objective O2 wants 10^9 instructions; ~5 x 10^7 accumulated across recorded runs, and `scripts/o2_marathon.sh` is grinding the rest in resumable 500-program batches (cumulative count in `build/o2_marathon.log`; a mismatch stops the run and keeps the failing seed) |
| Formal: fetch stage (`make formal-if`) | **pass** | BMC to depth 20, 5 properties, mutation tested; bounded, not a proof |
| Formal: SEC-DED code (`make formal-ecc`) | **pass** | **proof** over all 2^32 data values and all error positions, mutation tested |
| Formal: interconnect (`make formal-bus`) | **pass** | 5 routing, arbitration and no-lost-response properties, mutation tested |
| Formal: decoder (`make formal-dec`) | **pass** | **proof** over all 2^32 encodings that a rejected instruction has no architectural effect |
| Formal: LSU (`make formal-lsu`) | **pass** | one access in flight, aligned addresses, byte enables vs a reference, completion only on a response |
| Formal: safety controller (`make formal-safety`) | **pass** | faults are sticky, the lock holds, the reset request cannot sustain itself (guards V7-F1) |
| CI workflow | **installed, green** | [.github/workflows/verify.yml](.github/workflows/verify.yml): lint+block, cosim, software, formal and coverage on every push, gate/timing/fault-injection nightly. Five environment failure layers were peeled to get here (checkout permissions, tool PATH, dash-vs-bash, `LD_LIBRARY_PATH`) — a green badge only means something because the first runs failed honestly |
| Line coverage (`make coverage`) | **96.0 %** | 357 of 372 source lines with every point covered; waivers in [verif/coverage_waivers.md](verif/coverage_waivers.md). **Objective O6 open**: the criterion is 100 % statement/branch with reviewed waivers, and the denominator just grew with the parity and counter modules |
| Toggle coverage | **92.5 %** | criterion is >= 95 %; part of objective O6, open |
| Functional coverage (`make coverage`) | **100 %** | **objective O7 met**: 65 `cover` points bound into the RTL, all hit. Found four safety mechanisms no test had provoked and two decoder lines wrongly waived — see [verification_findings.md](doc/verification_findings.md) |
| Synthesis (`make synth`) | **pass** | yosys via slang: no latches, no combinational loops, 52 614 cells with 64-word TCMs |
| FMEDA / diagnostic coverage | **not started** | the pilot campaign is a first input, not a coverage figure |
| Fault injection (`make fi`) | **~10 000 upsets, 0 SDC, 0 hangs, 0 latent** | V29 measured **46.4 % latent** — 1 207 of 2 600 runs finished correctly with a safety mechanism silently disabled, 12 configuration registers 100 % undetected. Every configuration register group now carries hardware parity latching STATUS bit 13 **ungated** (V37): same campaign, same seed — **latent 0**, all previously-latent elements detected at a 2-cycle median, contract formally proven. See [verification_findings.md](doc/verification_findings.md) |
| Safety manual | substantive draft | mechanisms, measured latencies, the configuration-parity story and its residual gaps, integration guidance; the FMEDA it feeds is not started |
