# cdriscv-32s

**A 32-bit RISC-V core subsystem for safety-critical mixed-signal SoCs.**

(c) 2026 ChipDesign B.V. — [Apache-2.0](LICENSE)

> [!CAUTION]
> **NOT VERIFIED YET — DO NOT USE YET.**
>
> This banner said "phase V0, no coverage collected, nothing
> synthesised" for far longer than it was true. It is now accurate as
> of phase V18 of [doc/verification_plan.md](doc/verification_plan.md),
> and the status table below is generated from runs that are in the
> repository.
>
> **What has been done.** The RTL lints clean and is co-simulated
> against Spike over millions of instructions; there are block benches,
> six formal property benches, seventeen simulation targets, 96 % line
> coverage (100 % with reviewed waivers), 100 % functional coverage
> over 65 cover points, 3 000 fault injections with no silent data
> corruption, synthesis to IHP SG13G2 cells with the software tests
> re-run on the netlist, and static timing. **Nine functional defects
> have been found and fixed**, several of which broke a safety
> mechanism outright.
>
> **Why it still says do not use.** No architectural test suite
> (RISCOF) has been run, so conformance to the RISC-V specification
> rests on Spike co-simulation of the programs that happen to exist. No
> FMEDA and no diagnostic coverage figure. No timing closure — static
> timing runs, but the reset nets have no buffer tree and no Fmax can
> be quoted. Nothing has been laid out and nothing has been near
> silicon. Every finding raised so far is now closed.
>
> **Do not use yet** — not in a product, not in a tapeout, not as a
> reference, and above all not in anything that has to be safe. No
> functional safety claim of any kind is made, and no compliance with
> ISO 26262, IEC 61508 or any other standard.

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
| [tb/](tb/) | smoke bench and smoke program (never run) |
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
* [doc/benchmark_plan.md](doc/benchmark_plan.md) — planned comparison against the Synopsys ARC-V RMX-100
* [doc/isa_extension_plan.md](doc/isa_extension_plan.md) — what `rv32im_zba_zbb_zbs_zicsr_zca_zcb_zcmp` would take

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
| Architectural test suite (`make riscof`) | **not run** | objective O1. RISCOF, the official `riscv-arch-test` suite, the target environment and a DUT plugin driving the Icarus bench are all in place — the flow works end to end, and **the DUT and the Spike reference behave identically** — both raise an illegal instruction at the same PC on the `c.nop` alignment padding the released suite emits unconditionally, which is correct for a target without the C extension. The blocker is the suite's test build, proven from both sides. **No conformance result exists.** See [verif/riscof/README.md](verif/riscof/README.md) |
| Static timing (`make sta`) | **hold met, setup pre-buffering** | OpenSTA against the SG13G2 library: hold worst slack **+0.184 ns**; setup dominated by unbuffered reset nets of 1 475–2 201 loads, where two cells take 70 ns of a 74 ns path and all the logic takes 0.4 ns. **No Fmax can be quoted before buffer insertion** — see [verification_findings.md](doc/verification_findings.md) |
| Gate level simulation (`make gate`) | **3 blocks + the whole subsystem** | objective O8: ALU, multiplier and SEC-DED plus `cdriscv_subsys` synthesised to real IHP SG13G2 cells with the TCMs black-boxed — **5 433 flops, 529 175 µm²** — and four software tests run on the netlist with **cycle counts identical to RTL**. Also an illegal-state recovery check that re-argues waiver W2a against the gates. Functional only: every delay in the library is zero, so this says nothing about timing |
| Peripheral read-back (`make rdback`) | **pass** | 26 checks over six blocks. Every APB read arm, unmapped offsets, and the first software-driven memory BIST run |
| FENCE / FENCE.I / writable CSRs (`make fence`) | **pass** | 10 checks. Neither fence instruction had ever executed despite the ISA string; `mcause`, `mtval`, `msafestat` had never been written. FENCE.I is documented as **not observable** on this core — see V12-O1 |
| Block bench: clock monitor (`make block-clkmon`) | **pass** | 17 checks. Owns the clock generator, so it can stop the system clock — the only way to reach the "clock lost" path. **Found three defects: V11-F1, V11-F2, V11-F3** |
| Block benches: everything else | **not run** | plan section 5 |
| Architectural test suite | **not run** | plan objective O1 |
| Co-simulation vs Spike (`make cosim`) | **pass** | 208 instructions: PCs, register writes **and memory accesses** all identical, mutation tested; Verilator and Icarus agree |
| Random program co-simulation (`make cosim-random`) | **pass** | **1000/1000 programs, 16 885 968 instructions** with memory accesses compared; an earlier 2000-program run compared 33 760 012 instructions without them |
| Co-simulation at scale | **not met** | objective O2 wants 10^9; the above is 3.4 % of it. Throughput is now ~43 000 instr/s, so the rest is machine time rather than rework. Memory accesses are now compared; CSR state that no instruction reads back is not |
| Formal: fetch stage (`make formal-if`) | **pass** | BMC to depth 20, 5 properties, mutation tested; bounded, not a proof |
| Formal: SEC-DED code (`make formal-ecc`) | **pass** | **proof** over all 2^32 data values and all error positions, mutation tested |
| Formal: interconnect (`make formal-bus`) | **pass** | 5 routing, arbitration and no-lost-response properties, mutation tested |
| Formal: decoder (`make formal-dec`) | **pass** | **proof** over all 2^32 encodings that a rejected instruction has no architectural effect |
| Formal: LSU (`make formal-lsu`) | **pass** | one access in flight, aligned addresses, byte enables vs a reference, completion only on a response |
| Formal: safety controller (`make formal-safety`) | **pass** | faults are sticky, the lock holds, the reset request cannot sustain itself (guards V7-F1) |
| CI workflow | written, **never run, not installed** | [ci/github-workflow-verify.yml](ci/github-workflow-verify.yml); needs a token with GitHub's `workflow` scope to install, then a first run |
| Line coverage (`make coverage`) | **96.3 %**, or **100 % with waivers** | **objective O6 met**: every exclusion has a reviewed waiver in [coverage_waivers.md](verif/coverage_waivers.md). The 14 waived lines are all `default:` arms over fully enumerated selectors. Earlier entries in this table reported a mixed line+toggle figure by mistake — see V7-M1 |
| Toggle coverage | 94.8 % | reported separately, as it should have been from the start |
| Functional coverage (`make coverage`) | **100 %** | **objective O7 met**: 65 `cover` points bound into the RTL, all hit. Found four safety mechanisms no test had provoked and two decoder lines wrongly waived — see [verification_findings.md](doc/verification_findings.md) |
| Synthesis (`make synth`) | **pass** | yosys via slang: no latches, no combinational loops, 52 614 cells with 64-word TCMs |
| Gate level simulation | **not run** | |
| FMEDA / diagnostic coverage | **not started** | the pilot campaign is a first input, not a coverage figure |
| Fault injection (`make fi`) | **3 000 upsets** | three workloads, 9 named state elements: **0 silent data corruption**, 0 hangs. 41.0 / 57.3 / 42.8 % detected on the arithmetic, trap and memory workloads — the spread is the point, detection depends on what the software makes live. Not a diagnostic coverage figure — see [verification_findings.md](doc/verification_findings.md) |
| Safety manual | draft outline only | |
