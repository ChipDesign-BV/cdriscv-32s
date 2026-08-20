# cdriscv-32s

**A 32-bit RISC-V core subsystem for safety-critical mixed-signal SoCs.**

(c) 2026 ChipDesign B.V. — [Apache-2.0](LICENSE)

> [!CAUTION]
> **NOT VERIFIED YET — DO NOT USE YET.**
>
> Verification has started and is at phase V0 of
> [doc/verification_plan.md](doc/verification_plan.md). What that means
> concretely: the RTL lints clean and a smoke program boots and runs to
> completion in simulation. It does **not** mean the core is correct.
> No architectural test suite has been run, there is no comparison
> against a golden model, no coverage has been collected, and nothing
> has been synthesised. The first simulation already found a bug that
> broke every signed and unsigned comparison in the core
> ([V0-F2](doc/verification_findings.md)) — assume there are more.
>
> **Do not use yet** — not in a product, not in a tapeout, not as a
> reference, and above all not in anything that has to be safe. No
> functional safety claim of any kind is made: there is no FMEDA, no
> diagnostic coverage figure, no fault injection campaign, and no
> compliance with ISO 26262, IEC 61508 or any other standard.

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
  worst-case latency.
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
| Block benches: everything else | **not run** | plan section 5 |
| Architectural test suite | **not run** | plan objective O1 |
| Co-simulation vs Spike (`make cosim`) | **pass** | 208 instructions, identical PCs and register writes, mutation tested |
| Co-simulation with random programs | **not run** | plan objective O2; memory writes also not yet compared |
| Formal properties | **not run** | plan section 6 |
| Coverage | **not collected** | plan objectives O6, O7 |
| Synthesis | **not run** | |
| Gate level simulation | **not run** | |
| FMEDA / diagnostic coverage | **not started** | needs the fault injection campaign |
| Fault injection campaign | **not started** | plan section 9 |
| Safety manual | draft outline only | |
