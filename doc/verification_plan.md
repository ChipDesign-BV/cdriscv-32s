# cdriscv-32s verification plan

> **Status: nothing below has been executed.** The RTL has not been
> compiled, linted, simulated, synthesised or reviewed. This file is
> the to-do list that has to be worked off before the IP may be used.

## 0. Entry checks (not run)

| Step | Command | Expected |
|------|---------|----------|
| Lint the RTL | `make lint` | no errors, waivers documented |
| Lint with the bench | `make lint-tb` | no errors |
| Elaborate for simulation | `make sim` | compiles and boots the smoke program |
| Generic synthesis | `make synth` | no inferred latches, no combinational loops |

The smoke bench (`tb/tb_cdriscv_subsys.sv`) and the smoke program
(`tb/sw/start.S`) exist but have never been run; expect both to need
fixing before anything else can start.

## 1. Core: instruction set

* Run the RISC-V architectural test suite (`riscv-arch-test`) for
  RV32I, Zicsr, Zifencei and M, in machine mode.
* Run a random instruction generator against a golden model (for
  example Spike) with an RVFI-style comparison. The core exposes
  `retire_valid_o`, `retire_pc_o` and `retire_instr_o`; a full RVFI
  interface has to be added first.
* Directed tests for what the architectural suite covers weakly:
  * misaligned load, store and branch targets (all sizes, all offsets),
  * `mret` from every trap type, nested traps,
  * interrupt taken exactly at the boundary of a multi-cycle
    instruction (load, store, multiply, divide),
  * WFI with an interrupt already pending, and wake-up with
    `mstatus.MIE` clear,
  * `fence` and `fence.i` around a self-modifying store,
  * every division corner case: divide by zero, `INT_MIN / -1`,
    remainder signs.

## 2. Core: micro-architecture

* Fetch: redirect in the same cycle as a grant, in the same cycle as a
  response, and with the buffer full; a fetch error on a discarded
  response must not be reported.
* LSU: back pressure on `gnt`, error responses on read and write,
  byte enables for every size and alignment.
* CSR: read-only CSR write attempts, `CSRRS`/`CSRRC` with `rs1 == x0`,
  `CSRRW` with `rd == x0`, counter roll-over.

## 3. Memories and ECC

* Formal or exhaustive check of the SEC-DED code: every single bit error
  in the 39 bit code word is corrected, every double bit error is
  detected and never miscorrected. `scripts/gen_secded.py` checks the
  matrix properties at generation time; that is a construction argument,
  not a check of the RTL that was generated from it.
* Read-modify-write: every byte enable pattern, back to back accesses,
  an uncorrectable error found during the read half.
* BIST: fault-free run to completion on both TCMs, an injected stuck-at
  cell is found and reported at the right address, abort mid-run.

## 4. Safety mechanisms

* Lockstep: inject a fault into the checker core (force a net) and check
  that the mismatch is reported within one cycle of the delay, for every
  compared field. Check that no mismatch is reported during reset
  release, after a warm reset, and during WFI.
* Watchdog: time-out, service too early, wrong key, correct service,
  configuration locked.
* Clock monitor: system clock stopped, too fast, too slow, reference
  clock stopped (this case is *not* currently detected — decide whether
  it must be).
* Safety controller: every source to every reaction, lock behaviour,
  W1C behaviour, error pin in both modes.
* Fault injection self tests actually produce the expected fault bits.

## 5. Integration level

* Boot from reset with `MbistAuto` on and off.
* Warm reset while a bus transaction is outstanding.
* An APB slave that stalls with `pready` low for a long time.
* Unmapped access from both masters, simultaneously.
* Peripheral slot 15 driven by a slave that returns `pslverr`.

## 6. Physical and flow

* CDC report: only the intended crossings, all through
  `cdriscv_sync.sv`.
* Timing constraints, including false paths on the synchroniser inputs
  and the quasi-static clock monitor configuration.
* Gate level simulation with SDF after synthesis.
* DFT: scan insertion must not break the lockstep argument.

## 7. Before any use

Everything above, plus an FMEDA and a fault injection campaign as
described in `safety_manual.md`, section 5.
