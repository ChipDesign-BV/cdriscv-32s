# cdriscv-32s verification plan

> **Status: execution has started at phase V0.** Every criterion below
> is a target until the README status table says otherwise.
>
> **Progress, 2026-08-20:** phase V0 is complete — `make lint`,
> `make lint-tb`, `make sw` and `make sim` all pass, and the subsystem
> boots and runs the smoke program to completion with the lockstep pair
> active. One design bug and six portability or flow issues were found
> and are logged in `verification_findings.md`. Everything from V1
> onwards is still ahead. The status table in the README is the
> authoritative summary.
>
> Scope: the design as it stands today — RV32IM_Zicsr_Zifencei, single or
> dual core, with the subsystem of `cdriscv_subsys.sv`. The ISA
> extensions discussed in `isa_extension_plan.md` are explicitly out of
> scope here and add their own verification work.

## 1. Objectives and sign-off criteria

Verification is done, for this stage, when all of the following hold.
Anything not on this list is not claimed.

| # | Objective | Sign-off criterion |
|---|-----------|--------------------|
| O1 | The core implements the specified ISA | RISCOF run of `riscv-arch-test` for RV32I, M, Zicsr, Zifencei and the M-mode privileged tests passes, against Spike or the Sail model as reference |
| O2 | The core matches a golden model on arbitrary code | ≥ 10^9 instructions of randomly generated code co-simulated against Spike with zero mismatches on retire PC, instruction, register write and memory access |
| O3 | Every block behaves as its header comment says | Block level bench per block, all directed tests in section 5 pass |
| O4 | Every safety mechanism fires when it should, and only then | Section 7 matrix complete: each mechanism has at least one test that triggers it and one that proves it stays quiet |
| O5 | No structural surprises for synthesis | Zero inferred latches, zero combinational loops, zero multiply-driven nets, lint clean with a documented waiver file |
| O6 | Code coverage | 100 % statement and branch, ≥ 95 % toggle, with a reviewed waiver for each exclusion |
| O7 | Functional coverage | The cross matrices in section 8 closed |
| O8 | The design behaves the same after synthesis | Gate level simulation of the smoke program and a subset of the arch tests, with SDF |
| O9 | Diagnostic coverage is measured, not asserted | Fault injection campaign of section 9 complete, results feed the FMEDA |

O1–O7 are the gate for "may be used in a project". O8–O9 are the gate
for "may be used in a safety context", together with the FMEDA that is
outside this plan.

## 2. Strategy

Four observations shape the approach.

* **The core is small and sequential.** One instruction in the execute
  stage, no forwarding, no speculation. That makes a golden-model
  co-simulation cheap to build and extremely effective: a single retire
  stream comparison covers the whole datapath. This should be the
  backbone of core verification, not a nice-to-have.
* **The safety mechanisms are the product.** A bug in the ALU produces
  wrong answers, which most tests catch. A bug in the watchdog or the
  lockstep comparator produces *silence*, which no functional test
  catches. Each mechanism therefore needs a test that deliberately
  breaks something and checks that the right fault bit sets, and a test
  that proves it does not fire spuriously.
* **Several units are exhaustively verifiable.** The SEC-DED code
  (39 bits), the decoder's illegal-instruction classification, the ALU,
  the multiplier/divider corner set. Where exhaustive is affordable, do
  exhaustive and stop arguing.
* **Formal is affordable on the control logic.** The fetch stage, the
  bus arbitration and the LSU handshake are small state machines with
  properties that are easy to state and hard to test exhaustively by
  simulation. Bounded model checking with SymbiYosys will find the
  corner cases faster than a constrained random bench.

## 3. Environment and tool bring-up

All open source, all available in the IIC-OSIC-TOOLS container except
where noted.

| Tool | Use | Bring-up work |
|------|-----|---------------|
| Verilator | lint, and the main simulation engine (C++ harness, fast enough for co-simulation and benchmarks) | write the C++ harness, memory model and plusarg handling |
| Icarus Verilog | second opinion on SystemVerilog constructs, and the existing `tb_cdriscv_subsys.sv` | none |
| cocotb | register-level tests for the APB peripherals, written in Python | pick the simulator backend, write an APB BFM |
| Spike (`riscv-isa-sim`) | golden model for O1 and O2 | **not in the container**: build it, add a step-and-compare hook |
| RISCOF + `riscv-arch-test` | O1 | write the DUT plugin (ELF to memory image, run, dump signature) |
| `riscv-dv` in pyflow mode | random program generation for O2 | constraint tuning for M-mode only, no PMP, TCM address ranges |
| SymbiYosys / yosys-smtbmc | formal properties, section 6 | write the SVA subset the flow accepts |
| Yosys | O5 structural checks, area tracking | reuse `make synth` |
| Verilator `--coverage` | O6 | annotate and review |

Two pieces of DUT-side infrastructure have to be built before O2 is
possible:

1. **An RVFI-style trace interface.** The core exposes only
   `retire_valid_o`, `retire_pc_o` and `retire_instr_o`. Co-simulation
   needs, in addition: `rd` address and write data, `rs1`/`rs2`
   addresses and read data, the memory address, write data, read data
   and byte enables, the trap flag and cause, and the resulting PC. Add
   these behind a `` `ifdef RVFI `` or, better, through a `bind`ing so
   the synthesised RTL is untouched. Note that anything added as a real
   core *output* must also be added to the lockstep compare vector and
   `OutW` — a verification-only bind avoids that trap entirely.
2. **A test harness memory model** that answers the OBI protocol with
   configurable latency and grant back-pressure, so the core is
   exercised against something less forgiving than the TCM.

## 4. Levels

| Level | Device | Bench | Purpose |
|-------|--------|-------|---------|
| L0 | all RTL | lint, elaborate, synth | O5 |
| L1 | individual modules | directed + reference model | O3 |
| L2 | `cdriscv_core` | arch tests, random co-simulation | O1, O2 |
| L3 | `cdriscv_subsys` | scenario tests, safety tests | O4 |
| L4 | `cdriscv_core`, `cdriscv_bus`, `cdriscv_if_stage`, `cdriscv_lsu` | formal | corner cases |
| L5 | netlist | gate level | O8 |
| L6 | `cdriscv_subsys` | fault injection | O9 |

## 5. Block level test lists (L1)

The lists below are deliberately weighted towards the places where I
know this RTL is thin. They are the minimum, not the whole bench.

### 5.1 `cdriscv_if_stage`

The riskiest block in the design: three concurrent state updates
(request accepted, response accepted, redirect) share one always block.

* Redirect in the same cycle as `gnt` — the in-flight fetch must be
  discarded, and the *stale* PC must never reach the execute stage.
* Redirect in the same cycle as `rvalid` — the arriving instruction must
  be dropped, not buffered.
* Redirect while the buffer holds a valid instruction and no fetch is
  outstanding.
* Two redirects in consecutive cycles.
* `gnt` held low for 1, 2 and 100 cycles.
* `instr_err_i` asserted on a response that is being discarded — must
  **not** be reported.
* `fetch_en_i` deasserted with a fetch in flight, then reasserted.
* Reset with a non-zero `boot_addr_i`.

### 5.2 `cdriscv_decoder`

* Compare `illegal_instr_o` against a reference decoder for 10^8 random
  32-bit words plus the full legal encoding space, walking `funct7`,
  `funct3` and `opcode`.
* Every reserved `funct7`/`funct3` combination in `OP`, `OP-IMM`,
  `LOAD`, `STORE`, `BRANCH`, `SYSTEM` and `MISC-MEM`.
* `instr[1:0] != 2'b11` always illegal (this is the check that Zca will
  later move into the decompressor).
* Proof obligation: when `illegal_instr_o` is set, every enable output
  is low. Cheap as a formal assertion.

### 5.3 `cdriscv_alu`

* Exhaustive over the operator set, random operands (10^7 per operator)
  against a Python model.
* Directed: shift amounts 0 and 31; `sra` of a negative value; `slt`
  versus `sltu` around `0x7fffffff`/`0x80000000`; `sub` overflow;
  `ALU_PASSB`.

### 5.4 `cdriscv_multdiv`

* Corner set, exhaustive: `{0, 1, -1, 2, INT_MIN, INT_MAX, 0xffffffff}`
  crossed with itself for all eight operations.
* Division by zero for all four division operations.
* `INT_MIN / -1` and `INT_MIN % -1`.
* `mulhsu` with a negative multiplicand and a large unsigned multiplier.
* Random 10^7 per operation against Python.
* **Latency invariant**: every operation takes exactly the same number
  of cycles, including division by zero. This is WCET evidence, so make
  it an assertion, not an observation.
* `kill_i` during an operation.

### 5.5 `cdriscv_lsu`

* Every combination of size (byte, half, word), address alignment and
  read/write; check `be`, the write data lane and the read data
  extraction and sign extension.
* `gnt` back-pressure of 0, 1 and 10 cycles.
* `err_i` on a read and on a write.
* Two accesses back to back with no idle cycle.

### 5.6 `cdriscv_csr`

* Read and write every implemented CSR; check the reset value.
* Write to a read-only CSR (`addr[11:10] == 11`) raises illegal.
* `CSRRS`/`CSRRC` with `rs1 == x0` must not write.
* `CSRRW` with `rd == x0`.
* Unimplemented address raises illegal.
* `mcycle` and `minstret` increment, roll over at 32 bits into the high
  word, and are writable.
* Trap entry and `mret`: `mstatus.MIE`/`MPIE` stacking, `mepc`,
  `mcause`, `mtval` for every cause in the table.
* Interrupt priority: external before software before timer.
* `msafestat` sticky and write-1-to-clear behaviour, including a fault
  arriving in the same cycle as the clear (the RTL re-ORs the event —
  confirm that is what happens).
* `msafectrl[1]` self-clears after one cycle.

### 5.7 `cdriscv_regfile`

* `x0` reads zero and is never written.
* Write then read the same register on consecutive cycles.
* Parity: force a stored bit, check `par_err_o` on the next read of that
  register through a port the instruction actually uses, and check it
  stays low for a register that is not read.

### 5.8 `cdriscv_ecc_secded`

Fully exhaustive, no sampling:

* All 39 single bit error positions over a set of data patterns
  (all-zero, all-one, walking one, walking zero, 10^5 random): corrected
  data equals the original, `err_single_o` set, `err_double_o` clear.
* All 741 double bit error pairs over the same patterns: `err_double_o`
  set, `err_single_o` clear, and — the property that actually matters —
  **the decoder never silently miscorrects**.
* Zero error: syndrome zero, both flags clear.
* The same properties are provable by formal, which is the better
  option since it also covers all data values.

### 5.9 `cdriscv_tcm`

* Read-modify-write for all 15 non-full byte enable patterns.
* Full word write path (no RMW).
* Back to back accesses, and a request presented while `gnt` is low
  during the RMW second cycle.
* A correctable error found during the read half of an RMW.
* An uncorrectable error found during the read half of an RMW — check
  what is written and that `err_o` is asserted (the RTL writes the
  merged word anyway; confirm the documentation says so).
* Fault injection input: single and double bit masks.
* BIST port takes priority and blocks the functional port.
* `InitFile` preload.

### 5.10 `cdriscv_mbist`

* Fault-free run to completion on a small depth (16 words) — check the
  full March C- access sequence against a reference model, address order
  included.
* Injected stuck-at-0 and stuck-at-1 cells, at the first, a middle and
  the last address: detected, with the correct `FAILADR`.
* A fault in a check bit only (this is what the raw port exists for).
* `abort` mid-run; restart after abort.
* `AutoStart` behaviour after reset.
* Element and address direction sequencing across the down-counting
  elements 4 and 5 — the address reload on the element boundary is the
  fiddly part of that RTL.

### 5.11 `cdriscv_bus`

* Both masters request the I-TCM in the same cycle: the data master
  wins, the instruction master's grant is withheld, and neither response
  is misrouted.
* Response ownership across a back-to-back accept: master A's response
  is delivered while master B's request is accepted in the same cycle.
* Unmapped access from the instruction master, from the data master, and
  from both in the same cycle.
* An error response from a slave (I-TCM uncorrectable) routed to the
  right master.
* Every address decode boundary: first and last word of each region,
  and the words immediately outside.

### 5.12 `cdriscv_apb_bridge`

* Read and write with `pready` immediate, delayed by 1, 10 and 100
  cycles.
* `pslverr` returned to the OBI port as `err_o`.
* `psel` decode for all sixteen slots, including the unmapped ones.
* Back-to-back transfers.

### 5.13 Peripherals

* **Timer**: prescaler 0 and N; `mtime` roll-over across the 32-bit
  boundary; `irq_o` asserts on `mtime >= mtimecmp` and clears on a
  `mtimecmp` write; writes to `mtime`.
* **Watchdog**: time-out; service in the window; service too early;
  wrong key; key A twice; key B without key A; lock, then attempt to
  disable; `reset_req_o` gated by the enable bit; a `PERIOD` write
  restarting the counter.
* **Clock monitor**: system clock stopped (the saturation path);
  measured value below `MIN`; above `MAX`; inside the window; the sticky
  clear pulse crossing domains; **reference clock stopped** — currently
  *not* detected, so the test exists to document the gap and force a
  decision.
* **Interrupt controller**: level source stays pending while high, edge
  source latches and needs a clear; `CLAIM` priority; clear of one
  source while another is pending; a source that sets in the same cycle
  as its clear.
* **AMS interface**: channel walk with sparse `CHMASK` (including
  `CHMASK == 0`); conversion time-out; result below `LIMIT.lo` and above
  `LIMIT.hi`; the `RESULT`/`LIMIT` array indexing across all eight
  channels (an off-by-N here was already found and fixed once by
  inspection, so it deserves a directed test); one-shot versus
  continuous; `dac_we_o` strobe timing; analog flags into `fault_o`.
* **Safety controller**: every source bit to every reaction; `ENABLE`
  masking; global enable; W1C; lock; error pin in level mode and in
  toggle mode (including that the toggle stops on a fault); `PIN_DIV`;
  the three self-test bits.

## 6. Formal properties (L4)

Small, high value, and cheap to run in CI. Bounded model checking to a
depth of 20–30 cycles is enough for all of these.

| Block | Property |
|-------|----------|
| `cdriscv_if_stage` | at most one outstanding fetch at any time — **done** |
| | after a redirect, no instruction is delivered whose PC does not belong to the new stream — **done**, as `p_pc_stream` |
| | a discarded response never sets `instr_valid_o` — **done**, covered by `p_pc_stream` |
| `cdriscv_lsu` | at most one outstanding data access — **done** |
| | `addr`/`we`/`be`/`wdata` are stable from request to grant — **done**, as an assumption on the core plus a byte-enable reference check |
| | `valid_o` pulses exactly once per accepted access — **done** |
| `cdriscv_bus` | every accepted request produces exactly one response, to the master that issued it — **done** |
| | a response is never produced for a master with no outstanding request |
| `cdriscv_core` | `rf_we` is never asserted for `x0` |
| | a trap and a retire never occur in the same cycle |
| | the FSM never leaves a wait state without the corresponding completion |
| `cdriscv_ecc_dec` | for any data and any single bit flip: output equals input — **done** |
| | for any data and any double bit flip: `err_double_o` and no correction — **done** |
| `cdriscv_decoder` | `illegal_instr_o` implies no enable is set — **done**, proven over all 2^32 encodings |
| `cdriscv_safety_ctrl` | a status bit, once set, only clears through a write of 1 to it — **done**, plus the lock and the reset request |

## 7. Safety mechanism matrix (L3, O4)

Each row needs a *trigger* test and a *quiet* test. The quiet test is
the one that catches a mechanism wired to a constant.

| Mechanism | Trigger | Quiet |
|-----------|---------|-------|
| Lockstep | force a net in the checker core; also use the `SELFTEST` injection | full program run, warm reset, WFI entry and exit, `Delay` = 0, 1, 2, 4 |
| I/D-TCM SEC-DED | injected single and double bit errors, functional and through `SELFTEST` | full program run with no injection |
| Register file parity | forced bit in a stored word | full program run |
| Memory BIST | injected stuck-at cell | fault-free memory |
| Watchdog | no service; early service; bad key | correct service for 10^5 cycles |
| Clock monitor | stop `clk_i`; shift its frequency by ±20 % | nominal ratio for 10^4 reference cycles |
| Bus error | fetch and load from an unmapped address | full program run |
| AMS | out-of-range result; ADC that never answers; asserted analog flag | in-range results |
| Core trap reporting | execute an illegal encoding | full program run |

Plus, for the whole subsystem: a fault that is *masked* by `ENABLE`
must not set the status bit, and a fault whose reaction is not selected
must not assert the pin, the interrupt or the reset request.

## 8. Coverage model (O6, O7)

Code coverage from Verilator. Functional coverage as explicit crosses,
collected in the C++ or cocotb harness:

* **Instruction cross**: every opcode × {rd = x0, rd ≠ x0} × {rs1 = x0,
  rs1 = rd, other} × operand corner (zero, all ones, `INT_MIN`,
  `INT_MAX`).
* **Trap cross**: every cause × {interrupts enabled, disabled} ×
  {`mtvec` direct, vectored} × {trap during the first instruction after
  a previous trap}.
* **Bus cross**: master × slave × {read, write} × {grant immediate,
  delayed} × {ok, error} × {other master idle, competing}.
* **Multi-cycle cross**: interrupt pending while in `ST_WAIT_LSU` and
  `ST_WAIT_MD`; redirect while a fetch is outstanding; warm reset while
  a bus transaction is outstanding.
* **Safety cross**: mechanism × reaction × {enabled, masked} ×
  {configuration locked, unlocked}.

### Block benches are worth more than their coverage number suggests

The clock monitor bench was written to reach one uncovered branch and
found three defects, none of which the passing software tests could
have reached. Two lessons for the rest of the plan:

* A module is worth a bench when part of it **cannot be driven from
  software running on the subsystem**. The clock monitor's stopped
  clock path is the clear case: software would have to stop the clock
  it runs on. The same argument applies to reset sequencing and to
  anything else in the reference clock domain.
* Coverage has to be measured over the same builds as the tests. The
  clock monitor bench runs under Icarus, coverage comes from the
  Verilator builds, and until a Verilator build of the bench was added
  to the merge the report went on showing tested lines as uncovered. A
  report that understates is no more useful than one that overstates.

### Functional coverage is where an unexercised mechanism shows up

Objective O7's model is `verif/cover/cdriscv_cover.sv`. Its first run
paid for itself: it showed that the ECC self-test had only ever been
exercised against one of its two target memories. No amount of line
coverage could have shown that, because the D-TCM tests execute exactly
the same RTL lines as the I-TCM ones would.

The rule that follows: **a mechanism with a target select, a mode bit or
a source index needs a cover point per value**, not one point for the
mechanism. The safety controller's fault sources are modelled that way
for the same reason — one point per source, so a source nothing
provokes shows up as a hole instead of hiding inside an "any fault"
point.

### Gate level: what it is worth and what it is not

Objective O8's flow is `make gate`. Two things about it are worth
fixing in the plan rather than rediscovering.

**Timing is analysed separately, by `make sta`, and it reports two
scenarios.** The raw one says what the netlist does as synthesised; the
second cuts the reset trees, as a clock is cut before CTS, and the
worst path is then split into the part caused by missing buffering and
the part caused by logic depth. That split is the point: depth is an
RTL problem buffering cannot fix, and fanout is a layout problem RTL
cannot fix, so a single worst-slack number conflates the two and
directs effort at whichever is not the cause.

**Gate level simulation is functional, not timing.** Every delay in the
SG13G2 Verilog models is zero. A gate level run of this kind confirms the netlist
computes what the RTL computed and that nothing goes X. Timing is a
separate job — static timing analysis against the same library — and
claiming otherwise from a passing gate simulation would be wrong.

**White box assertions do not survive it, and that is correct.** The
multiplier bench asserts an invariant about an internal accumulator
bit; synthesis reached the same conclusion and deleted the bit, so the
probe reads a don't-care. Any bench reused at gate level has to
separate its black box checks from its white box ones and report which
it ran. `+NOWHITEBOX` does that here.

## 9. Fault injection campaign (L6, O9)

This is what turns "we have safety mechanisms" into a diagnostic
coverage number, and it is the input the FMEDA needs.

* **Method**: single event upset model — invert one flip-flop for one
  cycle, chosen uniformly over all flops and over the run time, while a
  representative workload executes. Verilator with a DPI hook, or
  Icarus with `force`/`release`.
* **Sample size**: ≥ 10^4 injections per workload, three workloads
  (control loop, memory-heavy, arithmetic-heavy).
* **Classification** of each run: detected by which mechanism and after
  how many cycles; silent (result correct, no fault reported); silent
  data corruption (result wrong, no fault reported — the number that
  matters); hang.
* **Deliverable**: a per-mechanism detection rate and a latency
  distribution, plus the list of flops whose upset is never detected.
  Expect the safety controller's own status registers and the
  configuration registers to show up there — they are unprotected today,
  which is already recorded as a gap in `safety_manual.md`.
* Repeat on the gate level netlist for the flops that survive
  synthesis restructuring.

**Activation has to be measured, not assumed.** The first pilot run put
this beyond doubt. It reported `mepc` detected 0 times out of 41 and
`mstatus.MIE` 0 out of 37, which reads as a hole in the safety concept
and is nothing of the kind: workload A takes no traps and enables no
interrupts, so both bits hold their reset value for the entire run and
an upset in them cannot propagate anywhere. A fault that is never
activated is not a fault that was tolerated, and counting the two
together turns a workload gap into a design claim.

So the workload set is part of the fault list, not a detail of how it
was run:

| workload | what it makes live | file |
|----------|--------------------|------|
| A: arithmetic and memory | ALU, register file, LSU, both TCMs | `verif/fi/fi_workload.S` |
| B: traps and interrupts | `mepc`, `mstatus.MIE`, `mcause`, the trap path, the machine timer | `verif/fi/fi_workload_trap.S` |
| C: dense sub-word memory traffic | LSU byte lane select, sub-word load and store paths, D-TCM | `verif/fi/fi_workload_mem.S` |

Each workload declares the I-TCM word range of its live code
(`--ibase`/`--ispan`), because a fault dropped into an instruction that
has already executed — register initialisation, say — is invisible by
construction and would pad the silent count with faults that never had
a chance to do anything.

Workload B is checked against an independent Python model of the
checksum, which also recovers the number of traps and interrupts the
run actually took. That is what proves the state is live: the model
says 64 traps and 14 timer interrupts, and it reproduces workload A's
golden value exactly when told to take neither.

## 10. Continuous integration

Everything above only stays true if it runs on every change.

* **On push**: lint, elaborate, block level tests, formal properties,
  smoke program, synthesis structural check. Target under ten minutes.
* **Nightly**: full arch test suite, 10^8 instructions of random
  co-simulation, coverage collection and a coverage trend.
* **Weekly**: 10^9 instruction co-simulation, fault injection campaign,
  gate level run.
* Publish the coverage summary and the pass/fail table in the README
  status table, so that the repository never again claims more than has
  been run.

## 11. Order of work and effort

One engineer, familiar with the code. The first two phases are where
the surprises will be.

| Phase | Content | Effort |
|-------|---------|--------|
| V0 | Lint and elaborate; fix what falls out; Verilator harness and memory model; smoke program runs | 3–5 d |
| V1 | Block level benches and reference models (sections 5.1–5.7) | 5–8 d |
| V2 | Spike build, RISCOF plugin, RVFI bind, arch tests passing | 4–6 d |
| V3 | Random co-simulation, `riscv-dv` tuning, first 10^8 instructions clean | 3–5 d |
| V4 | Memory, ECC, BIST and bus benches (5.8–5.12) | 4–6 d |
| V5 | Peripheral and safety mechanism tests (5.13, section 7) | 5–7 d |
| V6 | Formal properties | 3–4 d |
| V7 | Coverage closure and waiver review | 4–6 d |
| V8 | CI setup | 2–3 d |
| V9 | Fault injection campaign | 5–8 d |
| V10 | Gate level | 3–5 d |
| | | **8–11 weeks** |

V0 to V3 (about three weeks) is the point at which the core can be
trusted for benchmarking; V0 to V8 is the "may be used in a project"
gate; V9 and V10 are the additional gate for a safety context.

## 12. Risks

| Risk | Mitigation |
|------|------------|
| V0 uncovers a structural problem in the fetch stage or the execute FSM that needs a redesign, not a fix | do V0 first, before anything is built on top of the current behaviour; timebox it and re-plan if it overruns |
| The lockstep bench produces false mismatches at reset release or after a warm reset, hiding real ones | test the reset release sequence explicitly and early, at every `Delay` value |
| Random co-simulation needs an RVFI interface that is easy to get subtly wrong, producing false confidence | build it as a `bind`, and validate it by deliberately breaking the core and checking the comparison fails |
| Coverage closure drags because of the unreachable states in the parameterised generate blocks | fix the parameter set that is actually shipped, waive the rest with a reason |
| Fault injection results are worse than assumed, and the safety architecture needs rework | run a small pilot campaign (10^3 injections) during V5, long before the full one |
