# cdriscv-32s verification findings

Running log of everything verification has turned up, newest phase
first. Each finding records what was wrong, how it was found, and what
was done about it. See `verification_plan.md` for the plan these come
from.

## Phase V43 — objective O8 is met: twelve architectural tests on gates with SDF (2026-08-25)

`make gate-arch` runs an architectural subset on the placed netlist
with its SDF annotated, and **twelve of twelve pass with signatures
bit-identical to the recorded Spike references**: add, sub, xor, sltu,
jalr, lw-align and sw-align from I; mul and div from M — the 33-cycle
iterative unit grinding through 24 364 and comparable annotated cycles
— misalign-lh and ebreak from privilege, exercising the trap machinery
on gates; and FENCE.I, the self-modifying-code path that had found
design bugs twice before. Together with V42's smoke run this meets
O8's criterion in full: the smoke program and an architectural subset,
gate level, with SDF.

The port of the arch environment onto the subsystem memory map is
`verif/gate/arch/` (linker script and model hooks — with V35's lesson
baked in, `RVMODEL_DATA_SECTION` after the signature), and the runner
compares each signature word-for-word against the riscof-recorded
reference, which is legitimate because the trap handler's relative
encoding cancels the link base. Tests must fit the 16K TCMs; the ones
that cannot (the megabyte-spanning jal above all) are covered at RTL
by `make riscof` and are stated as out of gate-level scope rather than
silently absent.

Two harness defects found on the way, both instructive:

* The first privilege-test run failed with the program restarting 187
  times: without `-Drvtest_mtrap_routine=True` the tests compile
  without their trap handler, the misaligned load traps to **mtvec's
  reset value — address zero** — and execution silently begins again.
  The macro set is part of a test's identity, and the runner now takes
  it from riscof's own generated Makefile instead of guessing. (The
  RTL subsystem reproduced the failure identically, which is what
  exonerated the gates in one run.)
* The M tests initially failed to assemble because the runner
  hardcoded `-march=rv32i…`. Reported as SKIP by the harness, fixed as
  the script bug it was.

**With O8 met, every objective except O9's FMEDA handoff is closed.**
The gate for safety-context use now rests on feeding the fault
campaign's measured results — per-element detection, 2-cycle
configuration-parity latency, mechanism attribution — into an FMEDA
with real failure rates, which requires an owner for the safety case.

## Phase V42 — gate-level simulation with SDF runs, and found a flow defect (2026-08-25)

`make gate-sdf` is new, and it is the first half of objective O8: the
OpenROAD placed-and-repaired netlist — SRAM macros, inserted buffers,
resized gates — simulating the smoke program with its own SDF
annotated, cell delays and timing checks live, at the 20 ns target
clock. **PASS in 301 cycles by this bench's count**, program loaded
into the four macro banks and retiring from address zero.

### The find: OpenROAD leaves constants undriven

The first run was all X, and the trail was worth walking. Annotation
was exonerated (all X without SDF too), the cell models were exonerated
(a single flip-flop resolves correctly under `-gspecify`), the macro
preload was exonerated (bank contents verified in-simulation). The
probe that settled it read a flop's pins directly: clock toggling,
**RESET_B = X**. Six buffers upstream sat the reset synchroniser, its
data input wired to a net named `one_` — and `one_`, along with
`zero_`, had **no driver anywhere in the netlist**: 950 references,
zero drivers. OpenROAD's resizer names constant nets expecting tie
cells, and this flow never inserted any, so every constant in the
design — including the `1'b1` that feeds the reset synchroniser — was
X, and the netlist was dead on arrival.

`insert_tiecells` for the SG13G2 tiehi/tielo cells is now part of the
flow, which matters beyond simulation: a netlist with undriven
constant nets would have been just as wrong handed to layout. This is
the second time gate-level work has caught a flow defect that RTL
verification could not see (the first was V17's silently-ignored
blackbox), and it is the standing argument for O8 existing at all.

### The accepted limitation, stated

Icarus cannot create intermodpath delays for SDF `INTERCONNECT`
entries sourced at top-level port bits, and follows the failure with
an assertion (`vvp` SIGABRT). `scripts/sdf_sim_filter.py` therefore
strips the 120 829 INTERCONNECT entries for simulation and keeps the
606 000 lines of IOPATH cell delays and timing checks. Nothing is
thereby unverified: the interconnect delays this removes are exactly
the placement-estimated numbers OpenSTA analyses in `make fmax`, so
wire timing is checked in the tool built for it and functional timing
behaviour in the simulator. The SRAM macros' own SDF cells do not
annotate either (their flat dotted instance names defeat Icarus's
scope lookup); their timing lives in the behavioural model and, again,
in STA.

### What O8 still needs

The criterion is the smoke program *and a subset of the architectural
tests* on gates with SDF. The bench and flow now exist; running a
handful of arch tests through them is the remaining work, bounded by
simulation runtime rather than by unknowns.

## Phase V41 — timing closure at the reduced 50 MHz target (2026-08-24)

The integration target was reduced from 100 MHz to 50 MHz by the
integrator's decision, and at 20 ns the placed-and-buffered netlist
**closes: worst slack +0.04 ns, total negative slack zero.** By group:
reg2reg +1.83 ns, in2reg +4.70 ns, reg2out +0.04 ns — the last with
the placeholder 6 ns output budget still in place, so even the number
that belongs to the integration clears.

Two readings of the result, both worth keeping. At the 50 MHz
constraint the resizer stops optimizing the moment timing is met, so
the +1.83 ns reg2reg slack is what closure looks like, not what the
netlist can do; the 10 ns runs of V39 remain the capability statement,
**81 MHz** on the design's own paths. And the V39 fix options for the
I-TCM enable path — registered or predicted enable decode, macro
floorplanning — go from required to optional headroom: nothing needs
them at 50 MHz, and they are on record if the target ever moves back
up.

The area moved from 2.582 to 2.580 mm² between the 10 ns and 20 ns
runs: the resizer downsized once it no longer needed the drive
strength. Slower targets are cheaper, which everyone knows and a
measurement still says better.

## Phase V40 — the O1–O7 gate is met (2026-08-24)

The two objectives that were open are closed, and with them the gate
the verification plan defines as "may be used in a project".

**O2: 1 008 435 332 instructions, zero mismatches.** Fifty-five
batches of five hundred randomly generated programs — 27 500 programs
— co-simulated against Spike with retire PC, instruction, register
writes and memory accesses compared, overnight at roughly 18.7 million
instructions per eight-minute batch. Not one divergence in a billion
instructions. After the architectural suite, the directed benches and
the formal proofs, this is the volume argument: the core does what
Spike does on code nobody wrote.

The marathon that produced the number deserves its own accounting,
because **the harness failed four times before the design failed
zero times**:

1. `grep -c` prints 0 *and* exits 1 on no match, so an `|| echo 0`
   fallback produced `"0\n0"`, an integer test failed silently, and
   the first launch exited after writing one log line.
2. The runner's retire-compare bound was fixed at 20 000 regardless of
   program length; 38 000-instruction programs made all 500 seeds of a
   batch "fail" identically. All-seeds-fail is the signature of a
   broken harness, not a broken core, and so it was.
3. The runner ends its output with a bare `[random] PASS` line;
   `tail -1` caught only that, the success pattern failed, and the
   script stopped nine hours behind a green result.
4. A liveness check `pgrep`-matched its own command line and reported
   a dead marathon as running.

Each is the same failure shape: a check that was never itself checked.
They are recorded because the campaign's credibility rests on the
harness stopping for real mismatches — which is now demonstrated the
only way it can be: the fixed harness ran 55 straight batches and
stopped exactly when told to, at the target.

**O6: 96.2 % line, 96.2 % toggle, 100 % functional.** Closed with
stimulus, not waivers. The toggle report's gaps were a map of missing
tests: the V37 parity network toggled in no coverage-collected bench,
so every register group got a deposit-and-attribute check in
`tb_safety` (all seven `CFG_SRC` bits now proven to name their own
group, including `mtvec` climbing out of the lockstep pair); the
external fault and interrupt inputs were tied off in every bench, so
they are driven and their synchroniser path checked; the CSR
illegality paths (write to a read-only CSR, read of an unimplemented
one) had no test, so the trap test grew two cases. Line's remaining
14 misses are the reviewed W2 defensive arms — 100 % with waivers —
and the residual untoggled set is structurally constant by design
(seven `pslverr_o` tied to zero, tied-off expansion-port inputs, the
I-TCM BIST port that cannot run under software executing from the
I-TCM).

**Consequence.** The RTL STATUS banners, the README caution and the
safety manual language changed together in this commit, from "not
verified — do not use" to what is now true: verified to the O1–O7
gate, may be used in a project, **not qualified for safety-critical
use** — O8 (gate-level with SDF), O9's FMEDA handoff, and the 100 MHz
performance target remain open, and no ISO 26262 or IEC 61508 claim
of any kind is made.

## Phase V39 — the counter path is fixed, proven equivalent, and the whole suite re-run (2026-08-22)

V38's blocker is closed. `mcycle` and `minstret` are now
`cdriscv_counter64` (rtl/common): four 16-bit segments whose carries
are **predicted one cycle early into flip-flops from comparisons
only** — after this cycle's update a segment reads all-ones iff it was
written with `ffff`, incremented from `fffe`, or held at `ffff`. No
adder feeds a prediction and no prediction feeds an adder
combinationally, so the longest path through a counter is one 16-bit
incrementer.

The first attempt did not survive synthesis, and that is worth
recording. The obvious split — `if (&low) high++` — is logically half
the depth, and abc recognises `&low` as the carry-out of `low + 1`,
shares the chain, and quietly rebuilds the same 64-bit ripple: measured
75.9 → 77.0 MHz, critical path still `rd_ptr_q → minstret_q[63]`. A
structural intention that synthesis is free to undo is not a fix; the
prediction register is, because nothing can legally merge across a
flip-flop.

**Equivalence is proven, not argued.** Both the intermediate and the
final form were checked against the original flat `q <= q + 64'd1` CSR
file with yosys `equiv_make`/`equiv_induct` (8-step induction, 472 of
472 points, software writes included — a write and an increment in the
same cycle behave identically, per half). The counters are
architecturally invisible, and the re-run suite agrees.

Re-verified on the final RTL, all green: lint and lint-tb; sim, sw,
block, cosim, cosim-random, safety, periph, trap, fence, regwalk, ams,
rdback, reaction; all six formal benches; fi-arith (0 latent, 0 SDC,
0 hang); **riscv-arch-test 85 of 85**.

### The timing result, grouped honestly

`make fmax` now reports path groups separately, because the previous
single number was set by the SDC's placeholder 30 % IO budget rather
than by the design. (The first grouped run also printed a slack of
exactly 0.000 for every group — a Tcl query bug, `[$path slack]`
failing silently — caught because a number that clean deserved
suspicion, and fixed with `get_property`.)

| group | worst slack | Fmax | limited by |
|---|---|---|---|
| **reg2reg** | **-2.348 ns** | **81.0 MHz** | fetch request decode into the I-TCM macro's `A_MEN` enable |
| in2reg | +1.107 ns | meets 100 | placeholder input budget |
| reg2out | -2.589 ns | (79.4) | placeholder output budget on `retire_valid_o` |

Counter paths: gone from the top of every group. 75.9 → **81.0 MHz**
on the design's own paths, and the remaining limiter is a different
kind of problem: the request/grant/bank-enable decode from
`u_if.rd_ptr_q` into the SRAM macro's memory-enable pin, part logic,
part wire to a macro corner, part the macro's own setup. The candidate
fixes — registering the TCM enable decode (costs a fetch cycle),
precomputing enables a cycle early the same way the counters now do, or
simply floorplanning the macros nearer the core — are implementation
decisions, recorded here for whoever makes them. The 100 MHz target
remains open by 2.35 ns, and it is no longer the performance counters'
fault.

## Phase V38 — a placed and buffered Fmax: 76 MHz, and the path is the performance counter (2026-08-22)

`make fmax` is new: the subsystem synthesised with its TCM storage
mapped to four real IHP SRAM macros (two RM_IHPSG13_1P_2048x64 banks
per TCM, `verif/gate/cdriscv_tcm_macro.sv`), floorplanned at 45 %
utilisation, placed, and repaired by OpenROAD's resizer against
placement-estimated parasitics — 5 955 buffers inserted, 917 gates
resized, 121 pin swaps — before any slack is reported. No CTS and no
routing; the ideal clock carries a 250 ps uncertainty in their place.

The number: **worst setup slack −3.18 ns at a 10 ns period, an Fmax
estimate of 75.9 MHz** in the typical corner (1.20 V, 25 °C), design
area 2.58 mm², 46 % utilisation.

Two things this run settles:

**The unbuffered `make sta` number was not a number.** The same design
through plain abc with ideal nets reported slacks that meant nothing —
903 fanout violations, 163 slew violations, nets driving dozens of
loads for free. Buffering is not a refinement of that estimate; it is
the difference between an estimate and an anecdote. `make sta` stays in
the Makefile as a fast smoke check, and `make fmax` is the number to
quote.

**The critical path is not where anyone was looking.** Not the ALU,
not the multiplier, not the ECC encode into the TCM — the worst three
paths all start at `u_if.rd_ptr_q` and end in `u_csr.minstret_q[61..63]`:
the 64-bit retired-instruction counter increments in a single cycle,
and abc built the carry as a ripple of nand4/nor4 cells the resizer
can buffer but not shorten. mcycle has the same structure and is one
retire-qualification behind. The fix is standard and cheap — stage the
upper-word increment on the registered carry-out of the lower word, one
extra flop and one cycle of visible-only-to-itself latency — and it is
*design* work, so it is recorded here rather than done in a
verification phase. Until it is done, 76 MHz is the honest ceiling; the
target in the architecture notes is 100 MHz, so this finding is a
blocker for the performance claim, not for function.

The TCM macro model is stated honestly: 39 of 64 bits used per bank,
bank select on address bit 11, and the macro's read register standing
in for the RTL's `rd_cw` flop. The ECC encoders and decoders — which
the plain gate flow silently excluded along with the black-boxed TCM —
are inside the timing picture here, and they are not the problem.

## Phase V37 — configuration parity: latent falls from 46.4 % to zero (2026-08-22)

The decision V29 left open has been made and implemented: every
configuration register group in the subsystem now carries one hardware
parity bit, and the same 2 600-injection campaign that measured the
problem measures the fix.

| outcome | V29: unprotected | V30: software check | **V37: hardware parity** |
|---------|-----------------|---------------------|--------------------------|
| detected by a mechanism | 646 (24.8 %) | 1 773 (68.2 %) | **1 832 (70.5 %)** |
| detected by software only | — | 95 (3.7 %) | — |
| silent, configuration intact | 747 (28.7 %) | 621 (23.9 %) | 768 (29.5 %) |
| **latent** | **1 207 (46.4 %)** | 111 (4.3 %) | **0** |
| SDC / hang | 0 | 0 | 0 |

Same fault list, same seed, same workload A — no software check in the
loop at all. **Not one of 2 600 upsets left a mechanism silently
disarmed.** The twelve elements that were 100 % latent are now 100 %
detected, and the detection latency table puts every one of them at
**2 cycles, median and worst** — against a median of 4 and a worst of
69 for the pre-existing mechanisms (V33), and against a detection
interval bounded by the software checking period in the V30 approach.

### What was built

`cdriscv_cfg_parity` (rtl/common) captures one parity bit per register
group the cycle after any architectural write — from the stored value,
so the baseline cannot disagree with the register it guards — and
compares continuously ever after. Instantiated seven times: safety
controller (ENABLE, REACT_*, CTRL, PIN_DIV), watchdog (CTRL, PERIOD,
WINDOW), clock monitor (ENABLE, MIN, MAX), interrupt controller
(ENABLE, MODE), timer (MTIMECMP, ENABLE, PRESCALER), AMS interface
(everything but the self-clearing sequencer enable), and `mtvec` in
the CSR file, with the core's error passed through the lockstep wrapper
and into both compare vectors.

The mismatches land in **STATUS bit 13, and that bit is latched and
reacted UNGATED** — not masked by `ENABLE`, not masked by
`CTRL.enable`, interrupt and error pin hardwired rather than taken from
`REACT_*`. This is the structural answer to the V30 circular
dependency, where the register the fault disabled was the one that
would have recorded it: a fault that may have corrupted the reaction
configuration is not left asking that same configuration for permission
to report. The safety controller's own `CTRL.enable` — previously
detectable only by software with nowhere to deliver the report — is now
90 of 90 hardware-detected at 2 cycles. A new RO register `CFG_SRC`
(0x28) says which of the seven groups raised it.

Three properties in the formal bench pin the contract down so it
cannot regress silently: `p_cfg_ungated_latch` (a parity error latches
bit 13 no matter what the configuration says), `p_cfg_hard_irq` and
`p_cfg_hard_any` (bit 13 raises the interrupt and the fault flag
unconditionally). All prove.

### What is accepted and written down rather than closed

* An upset landing in the one cycle between a write and its parity
  capture is folded into the baseline. One cycle per configuration
  write, against a mission time of everything else.
* Fields the hardware itself updates cannot be parity-guarded by this
  scheme and are excluded: the AMS sequencer's self-clearing enable,
  and the CSRs the trap machinery writes (`mepc`, `mcause`,
  `mstatus`). Those are dynamic state, covered by lockstep at the point
  of use — and the campaign classes them silent-ok, not latent.
* One parity bit per group detects every single-bit upset but not all
  double-bit upsets. The single-event-upset model is the one the
  campaign uses; multi-bit config upsets are out of scope and stated
  so.
* Software scrubbing (V30, `fi_workload_check.S`) is no longer needed
  for detection, but remains documented in the safety manual as
  defence in depth; the one thing it uniquely adds is coverage of
  double-bit upsets within a group.

The `silent-ok` count rising from 747 to 768 is not noise worth hiding:
elements like `mepc`, `mscratch` and the watchdog counter are dynamic,
their upsets get overwritten before mattering, and runs that used to
fall in other buckets now classify cleanly. Zero SDC and zero hangs,
as in every campaign on this list.

One reporting note: `scripts/fi_campaign.py` did not know bit 13 by
name when this campaign ran, so its "which mechanism reported" table
under-attributes — the by-target table and the 2-cycle latency
signature carry the evidence. The map is fixed for future runs.

## Phase V36 — the suite pin is gone: current riscv-arch-test, 85 of 85 (2026-08-22)

`make riscof` now runs the **current** `riscv-arch-test`, not the pinned
3.5.3 tree, and passes **85 of 85**: 39 from I, 8 from M, 22 hints, 15
privilege, 1 Zifencei. Three consecutive runs, identical.

The `c.nop` blocker that forced the 3.5.3 pin at V34 has a one-flag
workaround that needs no change to the suite at all: **`-mno-relax`**. The
`LA` macro brackets its alignment in `.option rvc` so the assembler pads with
compressed nops; it is *linker relaxation* that keeps that padding in the
executed stream. Turn relaxation off and the padding is resolved away. On
`add-01.S`: six 16-bit encodings become zero, and Spike configured as `rv32i`
goes from one illegal-instruction trap to none.

That is also, it turns out, exactly how upstream fixed it. The history is
worth recording because it is easy to misread:

* #442 (2024) and #659 report the bug.
* #891 fixes it on the `act4` branch by jumping over the second alignment.
* #950 *removes* that jump 19 days later, when it enables `.option norelax`
  across the suite.

Read as a diff, #950 looks like a regression that dropped a fix. Measuring
four variants under Spike `rv32i` shows it is not: `.p2align` with no jump
traps once, and the same thing with `norelax` traps zero times. `norelax`
addresses the cause rather than stepping around the symptom, and `act4`
is correct today. **I had drafted the opposite conclusion — "the #891 fix has
regressed on act4" — from reading the diffs, and it was wrong.** The test
that settled it took two minutes.

The branch that is *not* fixed is `old-framework-3.x`, which has neither the
jump nor `norelax` — and that is the branch carrying the suite RISCOF
consumes. Hence `-mno-relax` in both plugin compile commands.

Removing the pin exposed two more selection defects, neither about this core:

**43 pmp tests select on a core with no PMP.** They gate PMP with
`verify (PMP['implemented'])`, but RISCOF selects on `check` clauses only —
`riscof/framework/test.py:315` iterates `part_dict['check']` and nothing
reads `verify`. So all 43 select on any RV32 core with I and Zicsr. This core
implements no PMP and has no U mode. `make riscof` now generates the test
list, drops the pmp group with a message saying how many it dropped, and runs
the rest.

**`cebreak-01.S` selects on cores without C**, already noted at V34: its
regex is `.*I.*Zicsr.*.C*`, and `C*` matches zero occurrences. With the pin
gone this is no longer worked around by deleting the file; it is simply one
of the tests the current tree does not mis-select, because the current tree
has fixed it.

One honest note on the numbers. The first run with the pin removed reported
85 passed and 43 failed, and among the failures were `xori-01` and one hints
test — which then passed on every subsequent run. That first run had all 128
tests in flight across 8 workers, each with a 512K-word memory image. The two
stray failures were contention in the bench, not the core; they have not
recurred in three runs since. They are recorded rather than quietly dropped
because a test that fails once and passes three times is exactly the kind of
result that deserves to be written down instead of forgotten.

The four defects are written up with minimal reproductions in
[verif/riscof/upstream-issues.md](../verif/riscof/upstream-issues.md), ready
to file.

## Phase V35 — the three misaligned-load failures were the bench, not the core; 62 of 62 pass (2026-08-22)

The three failures left open by V34 — `misalign-lh-01`, `misalign-lhu-01`,
`misalign-lw-01` — are a defect in this repository's RISCOF environment. The
core is architecturally correct. With the environment fixed the suite is
**62 passed, 0 failed**, and objective O1 is met.

Each failing test differed from the reference in exactly one signature word.
The trap record the arch-test handler writes is four words — vector+mode,
`mcause`, `mepc` relative to `rvtest_prolog_done`, `mtval` relative to an
anchor — and for `misalign-lh-01` it read:

| word | field | DUT | reference |
|---|---|---|---|
| 4 | vector + mode | `0000008f` | `0000008f` |
| 5 | `mcause` | `00000004` | `00000004` |
| 6 | rel `mepc` | `00000108` | `00000108` |
| 7 | rel `mtval` | `fffffe55` | `ffffffe5` |

`mcause` 4 is load-address-misaligned and both agree. Rel `mepc` 0x108 over
`rvtest_prolog_done` at 0x8000000c is 0x80000114, which is the `lh` itself, and
both agree. So the core took the right trap on the right instruction. Only the
address disagreed, and by a constant 0x190 = 400 bytes across all three tests.

The faulting address is not in dispute either. The load is `lh a1,1365(a0)`
with `a0` = 0x8000031c, giving 0x80000871, and running the same ELF under Spike
with `-l --log-commits` prints `tval 0x80000871` — the value the core produces.
What differs is what the handler subtracts from it. For `mcause` 4 the handler
anchors `mtval` on `mtrap_sigptr`, and the distance from the faulting datum to
that anchor is not the same in the two builds:

```
              rvtest_data   mtrap_sigptr   gap
DUT build      80000870      80000a1c      0x1ac = 428
Spike build    80002070      8000208c      0x01c =  28
```

400 bytes of ours, sitting between the data and the signature. They come from
`verif/riscof/cdriscv/env/model_test.h`, which expanded `RVMODEL_DATA_SECTION`
inside `RVMODEL_DATA_BEGIN`, ahead of `begin_signature`. On RISC-V `.align 8`
means 2⁸ = 256 bytes, not 8, and that block contains two of them:

```
rvtest_data      80000870
rvtest_data_end  80000880
begin_regstate   80000900     <- 256-byte aligned
end_regstate     80000a00     <- 256 bytes further on
begin_signature  80000a10
```

Spike's environment expands the same block inside `RVMODEL_DATA_END`, past
`end_signature`, where its padding cannot land between the data and the anchor.
The fix is to do the same. One line moved; all three tests pass.

Two things are worth keeping from this.

The first is that the framework's relative encoding is not as
layout-independent as it looks. It removes the load offset, but the anchor is
`mtrap_sigptr`, so any difference in how much the DUT environment places
between `rvtest_data` and the signature is silently folded into the recorded
`mtval`. Only exceptions whose `mtval` is a data address are affected, which is
why the misaligned **loads** failed while the misaligned **stores** and every
branch and jump test passed — their anchors are elsewhere. Three failures out
of sixty-two looked like a narrow defect in the core. It was a property of the
whole environment that only three tests were positioned to expose.

The second is the shape of the diagnosis. V34 recorded the failure as open and
declined to guess, and the guess that was available at the time — the reference
values looked like sign-extended bytes and the DUT's like sign-extended
halfwords, so perhaps the load-size decode was wrong — was entirely wrong. The
values were never data. They were addresses, and the byte pattern was
coincidence. Reading the two ELF symbol tables took less time than testing that
hypothesis would have taken.

## Phase V34 — RISCOF runs, 59 of 62 pass, and three failures worth chasing (2026-08-22)

Objective O1 has a result. Following the decision to try an older suite
release before patching anything: **`riscv-arch-test` 3.5.3, the newest
release that predates the compressed-padding change** — the `.option
rvc` around `.align` entered the suite in late 2022 and 3.6.0
(2023-01-25) is the first release carrying it.

**59 tests passed, 3 failed**, over 62 selected: 38 from I, 8 from M,
15 from privilege, 1 Zifencei.

Nothing in the suite was modified.

### What it took to get there

Five things, none of them about the core:

* **The suite is much bigger than any other bench here.** `jal-01.S`
  spans **437 928 words** because JAL has a ±1 MiB range and the test
  exercises the extremes; `beq-01.S` needs 57 296. The bench I-TCM is
  now 524 288 words for RISCOF only. Undersized, the image is silently
  truncated at load and the symptom is a bus error around cycle 90,
  which says nothing about the cause — it cost three iterations to
  recognise.
* **`-march=rv32i` does not assemble `fence.i`.** Finding V0-F3
  arriving from a third direction: RISCOF passes the ISA the *test*
  declares, and a 2022 suite predates the Zicsr/Zifencei split. Both
  plugins now append the extensions.
* **`jobs` defaults to 1** in the plugin template. One test that never
  halts then blocks the whole run behind it — the first five tests
  finished in five seconds and the sixth sat on the cycle limit.
* **The cycle bound was 8 000 000.** A test that has not finished in
  400 000 is not going to; bounding it turns a hang into a failure,
  which is a result.
* Two tests are excluded, both for reasons external to the design:
  `cebreak-01.S`, a C extension test **selected by a typo in the
  suite** — its regex is `.*I.*Zicsr.*.C*`, and `C*` matches *zero*
  occurrences of C, so it selects on cores without the extension (the
  other 26 C tests use `.*C.*` correctly, and current releases have
  fixed it); and `jalr-01.S`, which modern binutils rejects with
  `illegal operands 'la x0,5b'` — loading an address into `x0`.

### The three failures: misaligned loads

`misalign-lh-01.S`, `misalign-lhu-01.S` and `misalign-lw-01.S` fail.
`misalign-sh-01.S` and `misalign-sw-01.S` **pass**.

Loads and stores behaving differently is a specific enough asymmetry to
be worth chasing rather than dismissing. The signatures differ in
**3 words of 72**:

```
word 9   DUT fffffe4d   reference ffffffdd
word 13  DUT fffffe4e   reference ffffffde
word 17  DUT fffffe4f   reference ffffffdf
```

The reference values look like sign-extended *bytes* (`0xdd`, `0xde`,
`0xdf`); the DUT's look like sign-extended *halfwords* (`0xfe4d`,
`0xfe4e`, `0xfe4f`). The core does detect misalignment —
`cdriscv_core.sv` raises `EXC_LOAD_MISALIGN` on a word access with
`addr[1:0] != 0` and a half access with `addr[0] != 0` — so this is not
a missing check. It is something about what is left behind afterwards.

**This is open and unexplained**, and it is exactly what the
architectural suite exists to find: three of 62 tests, one coherent
class, not visible to any test written from the same understanding of
the design as the RTL.

> **Resolved by V35.** The defect was in this repository's RISCOF environment,
> not in the core: 400 bytes of `.align 8` padding ahead of the signature. The
> paragraphs here stand as written at the time, including the sign-extension
> guess, which was wrong.

**No conclusion about conformance is drawn here.** 59 of 62 is not a
pass, the three that fail are a real disagreement with the golden
model, and the next phase's job is to find out which side is right.

## Phase V33 — how long a fault goes unreported (2026-08-22)

V32 needed detection latency for one fault class and the campaign now
records it for all of them. Coverage says whether a fault is found;
latency says whether it is found in time, and a fault tolerant time
interval is spent on the second.

2 700 injections, 734 of them detected:

| state element | runs | median | 90th | worst |
|---------------|-----:|-------:|-----:|------:|
| safety controller `STATUS` | 103 | 1 | 1 | 1 |
| lockstep delay pipeline | 103 | 3 | 3 | 3 |
| fetch program counter | 96 | 4 | 4 | 22 |
| core state machine | 87 | 4 | 4 | 37 |
| fetch buffer word | 71 | 4 | 28 | 35 |
| LSU address offset | 3 | 5 | 5 | 5 |
| register file parity bit | 19 | 6 | 52 | 55 |
| register file word | 38 | 12 | 50 | 60 |
| register file write path | 117 | 12 | 35 | 40 |
| D-TCM word | 42 | 32 | 61 | 69 |
| I-TCM word | 55 | 38 | 64 | 69 |
| **all** | **734** | **4** | **34** | **69** |

**Every fault this list covers is reported within 69 cycles — 690 ns at
100 MHz — and the median is 4.**

### The shape of it is the design's structure, visible in the numbers

The fast end is everything compared or checked continuously. The safety
controller's own status register reports in **one** cycle, because a
flipped status bit *is* a fault bit. The lockstep delay pipeline takes
three: the comparator's own storage, caught by the comparator.

The slow end is memory. I-TCM and D-TCM upsets take a median of 32 to
38 cycles and up to 69, because ECC checks a word **when it is read**,
and a corrupted word sits there until the program comes back to it.
That is not a weakness in the ECC — it is what a read-triggered check
means, and it is the number to use rather than an assumption that ECC
is instantaneous.

Between them sits everything detected *indirectly*: the register file
and its write path, at a median of 12 and a worst of 60. Those are
faults that have to propagate to something compared before anything
notices, which is exactly what V4-F3 described and V32 measured.

### What it is worth, and what it is not

It bounds diagnostic latency for the fault classes that **are**
covered. For an FTTI argument that is the useful half: a fault in this
list, if it is going to be reported at all, is reported inside 690 ns.

It says nothing about the 46 % that are latent. Those have no latency
because they are never detected, and averaging them in — or quietly
omitting them and quoting 69 cycles as *the* diagnostic latency —
would be the same kind of error as quoting a detection rate without its
fault list.

The honest pair of numbers for this fault list and this workload:
**24.8 % detected, all within 69 cycles; 46.4 % latent, never.**

## Phase V32 — V4-F3 answered, and the answer is "do not make the change" (2026-08-22)

V31 showed the compare-vector recommendation was mis-scoped: the
campaign injects into the register file's *storage*, and a write-port
comparator cannot see that. The obvious repair was to add the fault
class the change actually addresses. Target 26 does that — a
one-cycle transient forced onto `rf_wdata` in the main core, applied
on a cycle that really writes a register.

(The first version applied it at an arbitrary cycle and had no effect
on any of five samples, because most cycles do not write a register.
It waits for `rf_we` now.)

**400 write-path transients: 400 detected. None missed.**

So the comparator adds nothing for this fault class either — not
because the fault is harmless, but because lockstep already catches all
of it. The corrupted register is read within a few instructions, the
wrong value reaches a compared output, and the mismatch fires.

### Which turns the question from coverage into latency

| | write-path transients |
|---|---|
| detected today | 400 / 400 (100 %) |
| detection latency, min | 5 cycles |
| median | 10 cycles |
| 90th percentile | 34 cycles |
| worst observed | 41 cycles |
| latency with the write port compared | 0–1 cycles |

Every one is detected later than one cycle, so the change would improve
every case. At 100 MHz it removes **up to about 410 ns** of detection
latency on a fault class that is already fully covered.

### The recommendation, reversed

**Do not add `rd_addr` and `rf_wdata` to the lockstep compare vector.**

Thirty-seven bits of compare vector, on the delay pipeline as well as
the comparator, buys no coverage — 0 of 2 600 storage upsets, 0 of 400
write-path transients — and removes a worst-case 410 ns from a
detection latency that is already sub-microsecond. Unless the fault
tolerant time interval being claimed is tight at that scale, which for
a control loop it will not be, the trade is not worth making.

If the FTTI *is* that tight, the number to argue from is the 41-cycle
worst case measured here, not the 14 cycles the `tb_safety`
characterisation happens to show — that test measures one injection,
this measures four hundred.

**V4-F3 is closed.** It was a correct observation about the design —
the register write port genuinely is not compared — and the mitigation
it proposed is not worth making. Those are different statements, and
running them together for twenty-eight phases is the mistake this pair
of findings corrects.

### What the campaign gained

Detection latency is now recorded for every run, not just outcome. A
diagnostic argument needs both: coverage says whether a fault is found,
latency says whether it is found in time, and an FTTI budget is spent
on the second.

## Phase V31 — the compare-vector recommendation was mis-scoped (2026-08-22)

V4-F3 has been open since phase V4 and I have restated it in nearly
every status since: *the lockstep compare vector carries the bus and
the retire information but not the register file write port, so a
corrupted register write is only detected indirectly — add `rd_addr`
and `rf_wdata` to the vector.* Four measurements were offered in
support: the characterisation test in `tb_safety`, and the register
file's detection rate across three workloads.

`tb_fi` now contains the comparator that change would add — the main
core's register write delayed by `LockstepDly` and compared against the
checker's, which is exactly what the RTL would have to do — so the
question can be answered with a number instead of an argument.

**Over 2 600 injections it would have caught nothing. Not one.**

### Why, and why the argument was wrong

The campaign injects into `rf_q`: the *stored word*. Both cores wrote
the same correct value; the corruption happened afterwards, in the
array. A comparator on the write port sees two identical writes and
has nothing to say.

The characterisation test in `tb_safety` forces
`u_core_check.rf_wdata`: the *write path*. That is a different fault,
and a write-port comparator would catch it immediately — which is
precisely why that test detects the fault indirectly at 14 cycles
today, and would detect it at 0 or 1 with the change.

So both halves of the evidence were real and they were about different
faults. **I connected them and recommended a fix for the one they did
not share.** The three-workload detection rates — 43, 45 and 31 per
cent — are storage upsets, and the proposed change does not address
storage upsets at all.

### What actually covers the stored word

Parity. `RfParity` is on, every read of a written register checks it,
and the register file parity mechanism reported 42 of 107 register-file
injections in one campaign. The remainder are the registers that are
never read again before being overwritten — dead values, where the
corruption has no consequence to detect.

### The recommendation, restated correctly

Adding `rd_addr` and `rf_wdata` to the compare vector is worth
something, and it is not what I have been claiming:

* it closes **write-path** faults — a fault between the ALU or load
  result and the register file input — which nothing currently detects
  directly, and which the `tb_safety` characterisation demonstrates;
* it adds **nothing** for corruption of the stored word, which parity
  already covers and which is what the injection campaign samples;
* the fault list contains no write-path target, so **the campaign
  cannot presently size the benefit**. That is the next thing to add if
  the decision needs a number.

Thirty-seven bits of compare vector for a fault class the campaign does
not yet sample is a thinner case than "four independent measurements
agree", which is what I said. The finding stands; the sizing does not.

## Phase V30 — measuring what the mitigation is worth (2026-08-22)

V29 found that twelve configuration registers are 100 % latent and the
safety manual's answer was to tell integrators to re-read the
configuration periodically. That was advice, not evidence.
`fi_workload_check.S` is the same advice written down and executable —
workload A's arithmetic, plus a read-back of every configuration
register each iteration, raising the software fault through
`msafectrl` on a mismatch.

Same fault list, same seed, 2 600 injections each:

| outcome | A: no check | D: with the check |
|---------|------------|-------------------|
| detected by a mechanism | 646 (24.8 %) | 1 773 (68.2 %) |
| detected by software | — | 95 (3.7 %) |
| silent, configuration intact | 747 (28.7 %) | 621 (23.9 %) |
| **latent** | **1 207 (46.4 %)** | **111 (4.3 %)** |
| SDC / hang | 0 | 0 |

**Latent falls from 46.4 % to 4.3 %.** Eleven of the twelve elements
that were 100 % undetected are now caught every time — the safety
controller's `ENABLE`, `REACT_IRQ` and `REACT_RST`, `mtvec`, the clock
monitor's enable and window, the interrupt controller's `ENABLE`, the
timer's `MTIMECMP`, the AMS channel mask.

### The two things that did not come out clean

**The watchdog's `CTRL.enable` is still 111 of 111 latent**, and that
is a gap in the *check*, not in the mitigation. The workload writes and
verifies the watchdog's `PERIOD` but never its `CTRL`. An earlier run
made the same point more loudly: with only four blocks checked, the
watchdog, the timer and the AMS mask all stayed 100 % latent, and adding
their read-backs moved two of the three to 100 % detected.

**A read-back check covers exactly what it reads back.** That sounds
obvious written down; it is worth 111 undetected upsets when it is not.

**The safety controller's own `CTRL.enable` is detected only by
software — 94 runs, and zero by any hardware mechanism.** This is a
circular dependency, and it is the most interesting thing in the
campaign. The software notices the corruption and raises the software
fault, which the safety controller would latch — except that the
register the fault disabled *is the controller's enable*. The report
has nowhere to go.

Before this was classified separately those 94 runs looked like
**silent data corruption**: the workload exited with its own error code
rather than the golden checksum, and nothing had latched a fault, so
the classifier called the result wrong. It was not wrong; it was a
correct detection with no channel to report on.

**Integration consequence:** software that checks the safety
configuration needs a reporting path that does not run through the
safety controller. An error pin driven directly, or a watchdog that is
simply not serviced, will survive the case where the controller itself
is the casualty.

### The cost

The check is eleven loads and eleven compares per iteration, guarding
about twenty instructions of work. The workload grows from 4 448 cycles
to 9 120 — **roughly double**. That is the price of the mitigation at
this checking interval, and the interval is a free parameter: checking
every tenth iteration would cost a tenth as much and lengthen the
window in which a disarmed mechanism goes unnoticed by the same factor.

Choosing that interval is an FTTI argument and belongs to whoever is
making the safety case. What this phase provides is the two endpoints:
**46.4 % latent unchecked, 4.3 % checked every iteration.**

## Phase V29 — every mechanism is armed by an unprotected register (2026-08-22)

V28 added the safety controller's configuration to the fault list and
found 29 % of upsets latent. This phase completes the set — the clock
monitor's window and enable, the interrupt controller's enable, the
timer's compare value, the AMS channel mask — and the figure is worse
because the earlier list was still partial.

**Twenty-six elements, 2 600 injections:**

| outcome | count | share |
|---------|-------|-------|
| detected | 646 | 24.8 % |
| silent, result correct, configuration intact | 747 | 28.7 % |
| **latent — correct result, configuration corrupted** | **1 207** | **46.4 %** |
| silent data corruption | 0 | 0 % |
| hang | 0 | 0 % |

**Twelve elements are 100 % latent. Not one injection out of 1 207 was
detected:**

| element | latent / injections |
|---------|--------------------|
| safety controller `ENABLE` | 99 / 99 |
| safety controller `REACT_IRQ` | 95 / 95 |
| safety controller `REACT_RST` | 101 / 101 |
| safety controller `CTRL.enable` | 107 / 107 |
| watchdog `CTRL.enable` | 113 / 113 |
| clock monitor `CTRL.enable` | 102 / 102 |
| clock monitor `MIN` | 107 / 107 |
| clock monitor `MAX` | 94 / 94 |
| interrupt controller `ENABLE` | 110 / 110 |
| machine timer `MTIMECMP` | 97 / 97 |
| AMS channel mask | 90 / 90 |
| `mtvec` | 92 / 92 |

### The single sentence this reduces to

**Every safety mechanism in this subsystem is armed by a register, and
not one of those registers is protected.** An upset in any of them
switches the mechanism off, or moves its threshold, and the design goes
on producing correct results with nothing to say it has been
disarmed.

### The detection rate is a property of the fault list

| fault list | elements | detected |
|------------|---------|----------|
| original (datapath only) | 9 | 41.0 % |
| plus safety controller and watchdog | 20 | 31.9 % |
| plus every other mechanism's configuration | 26 | **24.8 %** |

The design did not change between those three rows. The number fell by
sixteen points because the list stopped excluding the least protected
state. Any diagnostic coverage figure quoted without its fault list is
worth nothing, and this is the demonstration.

### What it corresponds to

This is the shape of the ISO 26262 **latent fault metric** — faults in
a safety mechanism that are not themselves detected. `safety_manual.md`
lists that metric as not computed, and it still is not: computing it
needs a full FMEDA with failure rates per element, not injection counts
over a hand-picked list. But the qualitative finding is now firm and
measured: **the latent fault metric for this design, computed today,
would be poor**, and the reason is a single structural gap rather than
a scatter of small ones.

### Not fixed here

The fix is a design change — parity on the configuration registers, or
a periodic read-back-and-compare in software, or shadow registers with
a comparator. Which one is an architecture decision with area, software
and diagnostic-interval consequences, and it is not made in a
verification phase.

What verification has done is turn "the configuration registers are
unprotected" from a remark someone wrote after reading the RTL into a
number with a fault list attached: **1 207 of 2 600, and twelve
elements at 100 %.**

## Phase V28 — the fault list was flattering the design (2026-08-22)

Every report of this campaign so far has carried the same caveat: the
fault list is nine named state elements, not the design's flops. This
phase extends it to **twenty**, and the result is that the previous
numbers were not merely incomplete — they were **biased**.

The nine original targets were all datapath: register file, fetch
buffer, program counter, CSRs the workload uses, the memories. The
eleven added are the state that *watches* the datapath — the safety
controller's own configuration, the watchdog's, the lockstep delay
pipeline, the core's state machine.

**Detection over 2 000 injections falls from 41.0 % to 31.9 %** simply
by asking about the second group. Nothing changed in the design.

### "silent-ok" was hiding the worst outcome the campaign can produce

The bigger finding is what the old classification called those runs.

An upset in `safety_ctrl.enable_q` does not corrupt a result. It
switches a fault source off. The workload then runs to completion,
produces exactly the right checksum, reports no fault — and the
mechanism that was supposed to be watching is gone. The campaign
called that **silent-ok**, which is the most misleading label
available: the workload passing is not evidence of anything when the
thing that would have complained is the thing that was hit.

The bench now emits a signature of the safety configuration and the
driver classifies a run whose configuration changed as **latent**:

| outcome | count | share |
|---------|-------|-------|
| detected | 638 | 31.9 % |
| silent, result correct, configuration intact | 780 | 39.0 % |
| **latent — result correct, safety configuration corrupted** | **582** | **29.1 %** |
| silent data corruption | 0 | 0 % |
| hang | 0 | 0 % |

Six elements are **100 % latent**, every injection, no exceptions:

| element | latent / injections |
|---------|--------------------|
| safety controller `ENABLE` | 98 / 98 |
| safety controller `REACT_IRQ` | 102 / 102 |
| safety controller `REACT_RST` | 104 / 104 |
| safety controller `CTRL.enable` | 98 / 98 |
| watchdog `CTRL.enable` | 89 / 89 |
| `mtvec` | 91 / 91 |

`mtvec` belongs in that list for a slightly different reason: it is not
a detector, but an upset in it sends the *next* trap to the wrong
address, and nothing notices until a trap happens. Same shape of
problem — the damage is real and deferred.

`safety_ctrl.status_q` is the mirror image: **101 of 101 detected**.
Flipping a status bit sets a fault bit, so the register that records
faults reports its own corruption. So does the lockstep delay pipeline,
100 of 100 — the comparator's own storage is fully covered by the
comparator.

### What this does and does not change

It does not change the design. `safety_manual.md` has said since the
first draft that the safety controller's configuration registers are
unprotected — that note was written from reading the RTL. **This is the
first time it has been measured**, and it is worth more as a number
than as a remark: 29 % of upsets in this fault list produce a run that
looks perfect and is not.

It does not mean the design is worse than it was. It means the
published detection rate was measured over a fault list that excluded
the least protected state, and reporting 41 % from that list was
flattering.

And it sharpens what the campaign is for. Zero SDC across every run so
far is a real result about the datapath. It says nothing about latent
faults, because SDC and latency are different failure modes and only
one of them was being counted.

### The obvious next question

Protecting configuration registers — parity or a periodic
read-back-and-compare by software — is a design decision, not a
verification one, and is not made here. What verification can now say
is what it would be worth: **582 of 2 000**.

## Phase V27 — W2a argued against gates for all six machines (2026-08-22)

The AMS sequencer and the core complete the set. **No state machine in
coverage waiver W2a now rests on the RTL argument alone**: each has
been forced into every encoding its synthesised state register allows,
on a netlist mapped to real SG13G2 cells, and each recovers.

| machine | encodings | criterion |
|---------|-----------|-----------|
| multiplier | 4 | returns to idle (V16) |
| APB bridge | 16 | returns to idle |
| LSU | 8 | returns to idle, bus responses tied high |
| BIST | 16 | returns to idle **or** the measured terminal state |
| AMS sequencer | 4 | returns to idle, conversion valid tied high |
| core | 8 | state defined **and** still fetching |

### The core needed a different question asked

Its RTL enum is two bits with all four values used — `ST_RUN`,
`ST_WAIT_LSU`, `ST_WAIT_MD`, `ST_SLEEP` — so the `default:` arm really
is unreachable in the RTL, and W2a's entry for it looks like the
weakest of the six.

Synthesis makes it the most interesting. yosys re-encodes the machine
to **three** bits, so the netlist has unused encodings the RTL never
had. Waiver W2a's whole premise — that the arms exist for states the
design should not be in — arrives at the gate level even for a machine
that had no such states in the source.

But every value of the *driven* bits maps to a legal state, so
"recovers to a legal state" is true by construction and worth nothing
as a check. What the bench asserts instead is that the state never goes
X, and that the core is **still fetching** two hundred cycles later
rather than wedged. That is the property that matters and it is not
automatic.

### On the generator

`scripts/gen_fsm_bench.py` now also carries the module's parameters
across as localparams, because port widths depend on them and a bench
without them will not elaborate — the AMS interface has
`AdcW`-dependent ports and failed on exactly that.

Two of the six benches needed hand-finishing after generation: the BIST
to measure its terminal state, the core to check fetching rather than a
state value. That ratio seems about right for a generator whose job is
to remove the port wiring, not to guess the acceptance criterion.

### What is still not proven

These are standalone netlists. `FSM_OPT` re-encodes differently in
context — the multiplier's state is two bits alone and three inside the
subsystem — so this establishes that yosys's FSM optimisation **does
not delete the recovery**, which was the risk W2a named, and not that
the shipped netlist's encodings behave identically. Checking that needs
a bench that locates the re-encoded register in the flattened netlist
rather than assuming its name, which V24 showed is not straightforward.

## Phase V26 — W2a for the BIST, by measuring instead of assuming (2026-08-22)

`make gate-fsm-mbist` forces the synthesised BIST controller into all
sixteen encodings of its state register; every one recovers. **Four of
the six machines waiver W2a covers are now argued against gates** — the
multiplier, the APB bridge, the LSU and the BIST. The AMS sequencer and
the core remain.

Two things made this one work that had defeated it in V25.

**A small-depth build.** At the real `Depth=4096`, forcing the state
restarts a march over the whole array and the settle window would have
to be tens of thousands of cycles per encoding. Synthesised at
`Depth=16` the march finishes in about two thousand, and the state
machine is identical either way — only the address counter's range
changes.

**Measuring the terminal state instead of assuming it.** The check
first reported encodings 12 to 15 settling at `100` rather than idle
`000`. That is `BS_DONE`: a forced state restarts the march, the march
completes, and the machine stops in the state it is supposed to stop
in. Both `BS_IDLE` and `BS_DONE` are quiescent and defined, and both
are a successful recovery.

So the bench runs one normal BIST first, records where the machine
comes to rest, and accepts either that or idle.

### The criterion, finally stated properly

Three phases of false failures — the tied-off LSU bus, the BIST's
terminal state, the flattened subsystem's escaped identifiers — all
came from the same mistaken criterion: **"the machine must return to
idle"**. W2a never claimed that. It claims the `default:` arms return
an upset machine to a *defined* state rather than leaving it stuck.

The right question is whether the machine reaches a state it can
legitimately hold. Idle is usually such a state; it is not the only
one, and requiring it turns correct behaviour into a reported defect.

The generator also masks the comparison to the bits a flip-flop
actually drives, because yosys declares the state wire at its RTL width
and optimises constant bits away — for the BIST the undriven bit is
bit 0, so a four-bit declaration reads `000z` at reset.

## Phase V25 — W2a for a third machine, and a bench that lied twice (2026-08-22)

`make gate-fsm-lsu` forces the synthesised LSU into all eight encodings
of its state register; every one recovers to idle. Three of the six
machines waiver W2a covers are now argued against gates: the
multiplier, the APB bridge and the LSU.

`scripts/gen_fsm_bench.py` generates these benches from the module's
own port list, since most of a bench like this is port wiring and the
RTL already says what the ports are.

### The first two runs were wrong, in opposite directions

The generated LSU bench reported **four of eight encodings failing**.
None of them was a defect.

With every input tied low, the LSU is forced into a state that has
issued a bus request, and then waits — correctly and for ever — for a
grant and a response that a tied-off environment never sends. The
machine is in a *legal* state doing exactly what it should. The bench's
criterion, "must return to idle", called that a recovery failure.

Tying `data_gnt_i` and `data_rvalid_i` high lets the implied
transaction finish, and all eight encodings then recover. **The
environment mattered as much as the netlist**, and the generator now
takes a list of inputs to hold high for that reason.

The BIST failed for a different reason and is not fixed: forcing its
state restarts a march over the whole array, so it needs either a
small-depth build or a settle window of tens of thousands of cycles
rather than the eight this bench allows. Its bench was deleted rather
than left reporting failures that mean nothing.

### Why this keeps happening

Three benches in two phases have now reported failures that were
artefacts:

* the subsystem-wide version, defeated by escaped identifiers and
  optimised-away declaration bits (V24);
* the LSU, defeated by a tied-off bus;
* the BIST, defeated by a settle window three orders of magnitude too
  short.

The pattern is the same each time: **the check was right and the
environment was not**, and the failure looked like a design problem
because that is what a failing check looks like. The cost of getting
this wrong is not a missed bug — it is a phantom one, and phantom bugs
in a safety argument are expensive to chase.

So the rule this leaves behind, for anyone extending the remaining
three: before believing a recovery failure, check that the machine is
not simply waiting for something the bench never sends.

## Phase V24 — W2a re-argued for a second state machine (2026-08-22)

`make gate-fsm-apb` forces the synthesised APB bridge into all sixteen
encodings of its four-bit state register, one per reset. Every one
returns to idle, none produces X, and the bridge then services a read
correctly. **The illegal-state recovery survives synthesis for the APB
bridge**, as it does for the multiplier (V16). Two of the six machines
waiver W2a covers are now argued against gates rather than RTL; the AMS
sequencer, the LSU, the BIST and the core are not.

### The method, and why the obvious version of it fails

The natural move is one bench over the flattened subsystem netlist,
covering all six machines at once. That was tried and abandoned, and
the reason is worth recording because it will catch anyone else
reaching for the same idea.

**Synthesis does not leave the state register where the RTL put it.**
yosys runs `FSM_DETECT`, `FSM_EXTRACT` and `FSM_OPT` — the log says
`Extracting FSM '\state_q' from module '\cdriscv_apb_bridge'` — which
pulls the machine out and re-encodes it. The consequences:

* the width changes with context: the multiplier's state is **two bits
  synthesised standalone and three bits inside the subsystem**, so the
  number of unused encodings differs between the two;
* after flattening, what survives is an **escaped identifier whose name
  contains dots**, so `dut.u_apb.state_q` binds to nothing and
  `dut.\u_apb.state_q` — trailing space and all — binds to a wire;
* that wire is declared at the RTL width with constant bits optimised
  away, so a four-bit declaration can have three flops and one
  permanently floating bit. A bench comparing the whole vector reads X
  where it should read a state.

The first version of the subsystem bench reported 80 of 84 encodings as
failures, every one of them an artefact of the above rather than
anything about the design. It was deleted rather than committed.

So the check runs against a standalone netlist per module, where
`u_dut.state_q` is an ordinary driven wire. That costs one synthesis
run per machine and is worth it.

### A caveat on what this proves

The standalone netlist is not the netlist that ships. `FSM_OPT` is
free to re-encode differently in context — it demonstrably does, given
the two-versus-three-bit result — so passing standalone does not
strictly prove the recovery survives in the assembled subsystem. What
it does establish is that yosys's FSM optimisation **does not delete
the recovery**, which was the specific risk W2a named. Checking the
shipped netlist directly needs the bench to find the re-encoded state
register rather than assume its name, and that is the remaining work.

## Phase V23 — separating fanout from logic depth (2026-08-22)

V18 reported that setup timing could not be turned into an Fmax,
because the reset nets swamp every path. That was true and it left the
useful question unanswered: **would the logic meet timing once the
trees exist?** Depth is an RTL problem that buffering cannot fix;
fanout is a place-and-route problem that RTL cannot fix. They need
separating before either can be acted on.

`make sta` now reports two scenarios and splits the second one.

### Scenario one, as synthesised

Unchanged: worst slack **−65.670 ns**, dominated by a flip-flop driving
up to 2 201 reset pins with no buffering.

### Scenario two, reset trees cut

`verif/sta/ideal_reset.sdc` false-paths the three reset nets, exactly
as a clock is treated before clock tree synthesis. Worst slack improves
to **−29.575 ns** — still nowhere near closing, and still for the same
reason: there are *more* unbuffered high fanout nets behind the reset
ones.

This scenario has an honest cost, stated in the file: `check_rst_n` is
not only a reset. The lockstep comparator uses it as an enable, so
cutting it removes a real data path too. That is why both scenarios are
reported and neither is called *the* answer.

### The split, which is the actual result

The worst logic path is 54 cells and 39.4 ns:

| | cells | delay | share |
|---|---|---|---|
| unbuffered fanout | 7 | 32.408 ns | 82 % |
| ordinary logic | 47 | 7.012 ns | 18 % |

Three cells alone — an `a21oi`, an `inv` and a `nor2` in sequence —
take 23.5 ns. The other 47 gates average **0.149 ns**, which is what a
gate in this library should cost.

**So the pipeline is not too deep.** Forty-seven levels of logic in
7.0 ns is comfortably inside a 10 ns period once the setup time and a
clock tree are allowed for. What stands between this netlist and
timing closure is buffering, and buffering is a place-and-route job.

### What this still is not

It is not an Fmax and it is not permission to quote one. There is no
placement, so no interconnect delay is modelled at all — every number
here is cell delay only, and real wires will make the 7.0 ns worse by
an amount only layout can say. It also assumes buffering fixes all
seven of the fat cells, which is likely but not demonstrated.

What it does support is a narrower claim worth having: **the design
does not need re-pipelining.** If the logic depth had come out at
30 ns, no amount of place-and-route would have saved it and the RTL
would have needed splitting. It came out at 7.

`scripts/sta_path_split.py` does the split, on the crude but adequate
rule that a cell taking more than a nanosecond in this library is not
doing logic, it is driving a crowd.

## Phase V22 — V0-F1 closed, and the fix withdrew a waiver (2026-08-21)

The last open finding is closed. **`FAILDATH` at `+0x10` returns the
seven ECC check bits of the failing code word**, so a failure in the
check-bit half of the array — the part only the raw test port can reach
— can now be diagnosed. Before this, `FAILDAT` returned bits [31:0] and
the check bits were invisible.

### Why it sat open, and why the proposed fix would not have worked

V0-F1 proposed exactly this register and queued it for "phase V4 when
the BIST bench is written". Had it been implemented as proposed it
would have been broken on arrival: each BIST controller decoded sixteen
bytes — `psel_hit_o = psel_i && (paddr_i[7:4] == RegBase[7:4])` — so
`+0x10` was **outside the range the controller answers to**, and the
new register would have returned a bus error rather than the check
bits.

The claim is now thirty-two bytes, `paddr_i[7:5]`. The two controllers
stay where they were, the I-TCM one owning `0x00..0x1f` and the D-TCM
one `0x40..0x5f`, and they still do not overlap.

Worth noting for its own sake: a proposed fix written eighteen phases
earlier, against a decode nobody had re-read since, did not survive
contact with the decode.

### The fix withdrew waiver W2c

W2c waived `cdriscv_mbist.sv:253` — the read decode's `default` — on
the grounds that a word access could only ever produce `0x0`, `0x4`,
`0x8` or `0xc`, all of which had arms. Widening the claim to
thirty-two bytes makes `0x14`, `0x18` and `0x1c` reachable, so the
justification is simply false now. The line is covered by a test rather
than waived.

W2's own "what would invalidate this waiver" section listed the decode
changing. It was right to, and **one new register was enough to do
it** — which is the argument for writing that section at all.

Fourteen lines remain waived, down from fifteen. Line coverage 96.0 →
**96.3 %**, still 100 % with waivers, functional coverage still 100 %.

### Tests

`rdback_test.S` reads `FAILDATH` after a clean BIST, which exercises
the new decode and the new read arm, and reads `+0x14` to cover the
default that W2c used to waive. `tb_safety` checks that the **whole**
39-bit code word is captured on a failure — `fail_data_q ===
39'h55_5555_5555` against the forced read data — because check bits
sliced out of a truncated capture would be meaningless.

One honest limit: no test reads `FAILDATH` through the bus *after a
real failure*. Software cannot make a BIST fail, and the bench that can
force one has no APB master. The two halves are covered separately —
the register decodes and returns its slice, and the capture holds all
39 bits — which is weaker than one end-to-end check and is said here
rather than left to be assumed.

## Phase V21 — the reference model traps too, and V20 needs correcting (2026-08-21)

One command settled the RISCOF question, and it invalidates something I
reported last phase.

Spike, running the same test:

```
core   0: 0x800002c8 (0x00000001) c.nop
core   0: exception trap_illegal_instruction, epc 0x800002c8
core   0:           tval 0x00000001
```

**The reference model traps at exactly the same address, on exactly the
same instruction, as the DUT.** Both ELFs contain 18 instructions at
non-word-aligned addresses; the compressed padding is in both, and both
models correctly refuse it.

### Correcting V20: those 128 signatures are not references

V20 reported "the Spike reference now runs — 128 signatures" as a fixed
blocker. That was wrong, and wrong in the way that matters: Spike was
not completing the tests. It was trapping on the padding, spinning in
the trap path, and `--instructions=500000` was dumping whatever
happened to be in the signature memory when the bound expired.

A signature file existed, had a plausible size, and contained
plausible-looking words. None of that made it a reference. **A file
being produced is not the same as a result being produced**, and I
counted the former as the latter.

### What this actually establishes

Positively, and it is worth something: **the DUT and the reference
model agree.** Presented with a 16-bit encoding on a target that does
not implement the C extension, both raise an illegal instruction
exception at the same PC with the same `tval`. That is the
specification working, on both sides.

So the core is not at fault here, and neither is Spike. The test build
is: `env/arch_test.h` enables `.option rvc` around its `.align`
directives so the assembler can pad with `c.nop`, unconditionally, and
that padding lands in the straight-line instruction stream rather than
somewhere control flow skips.

`UNROLLSZ` is a documented `#ifndef` knob and is **not** the answer —
tried it: `-DUNROLLSZ=2` takes the count of non-word-aligned
instructions from 18 to 3 073, because tighter alignment means more
blocks need padding and each `c.nop` shifts everything after it. The
obvious lever makes it worse.

### Status: unchanged, and now for a well understood reason

No conformance result, and the README still says "not run". What is
established is narrower and firmer than V20 claimed:

* the DUT plugin, the target environment, the signature dump and the
  whole flow work end to end;
* the DUT and the reference model behave identically on this suite;
* the blocker is the suite's test build on a target without the C
  extension, proven from both sides rather than inferred from one.

Resolving it means either finding the supported way to build this suite
for a non-C target, or raising it upstream. Patching `arch_test.h`
locally would produce a passing run whose result no longer came from
the official suite, which is the only reason to run the official suite.

## Phase V20 — RISCOF: reference model working, DUT blocked on RVC padding (2026-08-21)

Four blockers down, one left, and the last one is the interesting one.

### Fixed: the Spike reference now runs — 128 signatures

> **Wrong, corrected in V21.** Spike was not completing these tests. It
> traps on the same compressed padding the DUT does, and the bound was
> dumping memory from inside the trap loop. The 128 files are not
> reference signatures. The rest of this section — why the bound is
> needed at all — still stands.

**This Spike never acts on the HTIF `tohost` write.** The test's halt
loop spins for ever and no signature is written, which looked like "the
reference model is slow" in V19 and was nothing of the kind. Bounding
the run with `--instructions=500000` makes Spike stop and dump.

That is safe rather than a fudge: the signature region is filled before
the halt loop is reached, so stopping inside the loop dumps a complete
signature. Verified on `add-01.S`, which produces the same 592 words
bounded or not. The bound is far above any architectural test's length,
so a test that genuinely runs away is still caught.

**128 reference signatures** now generate in a few minutes.

### Fixed: three DUT-side bugs, all mine

* **Make ate the shell substitutions.** The plugin builds a command
  string that is written into a Makefile, where `$(...)` is a *make*
  variable reference, not shell command substitution. Every
  `$(riscv32-unknown-elf-nm ...)` expanded to nothing, so `--pad-to`
  swallowed the next argument and objcopy failed with "bad number:
  my.elf". They need `$$(...)`. I had escaped `$$1` for awk and missed
  this.
* **The tests do not fit in the instruction memory.** `add-01.S` alone
  spans 5 780 words against the 4 096 the subsystem defaults to. The
  overflow does not announce itself — the image is truncated at load
  and the symptom is a bus error a hundred cycles in. `tb_cosim` now
  takes `ItcmWords` as a parameter and the RISCOF build overrides it to
  16 384; every other run keeps the default.
* **The bench aborted on the first safety fault.** Right for
  co-simulation, where the DUT and the model must agree instruction by
  instruction. Wrong for architectural tests, which take traps
  deliberately: the core-trap bit sets, and the run has to continue to
  its own halt because **the signature is the pass criterion**, not the
  absence of a fault. The abort is now disabled exactly when a
  signature is being collected, and the fault is still reported.

### The remaining blocker: the suite emits compressed padding

The DUT now executes the test properly and traps at `0x800002c8`:

```
800002c4:  e9840413   addi s0,s0,-360
800002c8:  0001       nop            <-- c.nop, a 16-bit instruction
800002ca:  00000013   nop
```

That `c.nop` is alignment padding, and it is deliberate. From
`riscv-arch-test/riscv-test-suite/env/arch_test.h`:

```
.option rvc             // temporarily allow compress to allow c.nop alignment
.align MTVEC_ALIGN
.option pop
```

Three places in the released suite do this, unconditionally. The ELF's
own attribute says `rv32i2p1` — no C extension — and the padding is
compressed anyway.

On a core that implements C this is harmless. **This core does not
implement C**, it is RV32IM_Zicsr_Zifencei, so the padding is an
illegal instruction — and it is not skipped over, it sits in the
straight-line instruction stream between two test instructions and gets
executed.

So the core is behaving correctly: an RV32I core *must* trap on a
16-bit encoding. The trap is the specification working, not a defect.

**Not resolved, and deliberately not worked around.** Patching
`arch_test.h` to emit 4-byte padding would make the run pass, and would
also mean the result no longer came from the official suite — which is
the entire value of running it. The options are to establish whether
the suite offers a supported way to build for a non-C target, or to
raise it upstream. Neither is a code change here.

**So there is still no conformance result, and the README still says
"not run".** What changed is that the blocker is now understood and is
one line in a third-party header rather than an unexplained slowdown.

## Phase V19 — RISCOF, objective O1 (2026-08-21, INCOMPLETE)

The architectural test suite is the one gap that mattered most: every
conformance statement so far has rested on Spike co-simulation of the
programs that happen to exist in this repository, which answers "does
it agree with Spike here" rather than "does it implement the
specification".

**The infrastructure is in place and it does not yet produce a
result.** That distinction is the whole of this entry.

### What was built

* `riscof` installed — it needs `cython<3` and `--no-build-isolation`,
  because its dependency chain hits the PyYAML/Cython-3 breakage.
* The official `riscv-arch-test` suite cloned, release
  `ctp-release-e9514aa-2025-12-28`. 1.7 GB, so it is fetched rather
  than vendored and is in `.gitignore`.
* `cdriscv_isa.yaml` corrected from the template's RV32IMC to this
  core's **RV32IM_Zicsr_Zifencei** — misa bitmask `0x1100`, not
  `0x1104`. The template would have run compressed-instruction tests
  against a core that has no C extension.
* `env/model_test.h` and `env/link.ld` for the target: no console, so
  the IO macros are empty and the signature is the only output;
  everything at `0x8000_0000` where the co-simulation bench maps the
  I-TCM.
* `riscof_cdriscv.py` drives the existing Icarus bench — objcopy to a
  flat image padded to `end_signature`, `mkimage.py` to the 39-bit ECC
  hex, then `vvp`. Signature bounds and the `tohost` address come from
  the ELF symbol table through `nm`, so none of them is assumed.
* **`tb_cosim` gained a signature dump.** `+TOHOST` makes it watch for
  the halt store; `+SIGBEGIN`/`+SIGEND`/`+SIGFILE` dump the region
  straight out of the I-TCM array. The SEC-DED encoding is systematic,
  `cw = {parity, data}`, so the data half is the low 32 bits. All of it
  is plusarg gated: without `+SIGFILE` nothing happens, and the
  existing co-simulation still passes unchanged.

Two integration problems worth recording because they are not in any
documentation:

* Both plugins hardcode a `riscv32-unknown-elf-*` toolchain prefix.
  This environment ships `riscv64-`, which targets rv32 through
  `-march`/`-mabi`. Symlinks fix it without patching a vendor plugin.
* **The shipped Spike plugin is a stub.** Its run command is
  `execute += self.ref_exe + ''` — the executable name and nothing
  else, which puts a bare `spike` on the command line and produces a
  usage dump. It has to be filled in with
  `--isa=... +signature=... +signature-granularity=4`.

### Why there is no result

**The reference model is the blocker, not the DUT.** Spike takes
minutes per test in this environment rather than milliseconds, so a
full run does not finish. One reference signature was produced and is
complete — 592 words for `add-01.S` — which says the flow is right and
the throughput is not.

Whether that is a Spike build problem here, an interaction with
`+signature-granularity`, or something in the test environment's HTIF
handling has not been established. The DUT side has therefore never
run end to end at all, because RISCOF runs the reference first.

**So: no conformance claim can be made, and none is made.** The README
status table says "not run" and will keep saying it until a run
completes. Infrastructure that is 90 % built is worth exactly as much
as infrastructure that is 0 % built, when it comes to what the IP can
claim.

## Phase V18 — static timing, and what it actually says (2026-08-21)

`make sta` runs OpenSTA against the same SG13G2 library the netlist is
mapped to. This closes the caveat that has been attached to every gate
level claim so far — "this says nothing about timing" — by going and
finding out.

**Hold is met: worst slack +0.184 ns.**

**Setup is not, and the number is not what it looks like.** Worst slack
is −65.670 ns against a 10 ns period, total negative slack −272 µs. A
frequency cannot be read off that, because of what the path is:

```
_56826_/Q  (dfrbpq)   36.737 ns   <-- reset flop driving 1708 reset pins
_34990_/X  (and2)     33.424 ns   <-- and the gate after it
_35638_/X  (a21o)      3.456 ns
_47370_/Y  (nand2)     0.137 ns
_47377_/Y  (a21oi)     0.096 ns
_47438_/Y  (nor3)      0.059 ns
_47439_/Y  (a22oi)     0.106 ns
                      ------
                      74.016 ns arrival
```

Two cells contribute 70.2 ns. **All of the actual logic contributes
0.4 ns.** The design is not deep; the netlist has no buffer tree.

### The reset distribution is the whole problem

| net | flip-flop reset pins driven |
|-----|----------------------------|
| `core_rst_n` | 2 201 |
| `g_lockstep.u_core.check_rst_n` | 1 708 |
| `rst_n_sync` | 1 475 |
| `ref_rst_ni` | 107 |

Each is a single driver into one to two thousand loads, with no
buffering anywhere. 11 727 fanout and slew checks are violated. The
library's own maximum fanout is 8.

**This is a place and route job, not an RTL one.** A reset tree is
built the same way a clock tree is, and no RTL change removes the need
for it. What this analysis is therefore good for is: hold is met, the
logic depth is not the limit, and the fanout table above is the list of
nets that need a tree. What it cannot give is an Fmax, and quoting
−65 ns as "the design misses timing by 65 ns" would be wrong.

`check_rst_n` is worth a second look for a different reason: it is not
only an asynchronous reset but also a data signal, since the lockstep
comparator uses it as its enable (`assign compare_en = check_rst_n;`).
That is why it turns up in a register-to-register data path at all. The
behaviour is correct; the implication is that its buffer tree has a
timing requirement as well as a skew one.

### boot_addr_i has to be tied for the design to map

Synthesising the subsystem standalone leaves **64 flip-flops unmapped**
— exactly two cores' worth of 32-bit program counter. `fetch_pc_q`
resets to `boot_addr_i`, and `boot_addr_i` is a top level *port*, so
the flop needs a reset that loads a data value. No standard cell does
that: a library reset is to a constant.

Tying `boot_addr_i` to a constant, which is what an SoC does, maps all
5 497. So this is a synthesis-context artifact rather than a design
defect — but it has two consequences that had to be recorded rather
than smoothed over:

* **The V17 netlist was not fully mapped.** Sixty-four of its flops
  were behavioural Verilog that yosys emitted because it could not map
  them. The gate level simulation was therefore not entirely gates. The
  claim in V17 is corrected accordingly; the cycle-identical result
  stands, since behavioural flops simulate correctly, but "the whole
  subsystem in cells" was an overstatement.
* **The integration guide now says it.** `boot_addr_i` must be tied to
  a constant at the SoC level. Driving it from a register would leave
  the core's program counter unmappable.

### Two tool limits, recorded because they cost time

OpenSTA's structural Verilog reader rejects two things yosys emits by
default: the flattened hierarchical debug wires, declared `reg`
(`opt_clean -purge` removes them), and parameter overrides on a black
box instance — `cdriscv_tcm #(.Depth(32'd4096), .InitFile(""))` — which
`scripts/sta_netlist_fixup.py` strips, since neither parameter carries
timing.

The STA netlist is therefore built separately from the simulation one.
That is a real divergence and worth being explicit about: the two
differ in the `boot_addr_i` tie and in cosmetic net naming, nothing
else, and both come from the same synthesis script.

### Next

Buffer insertion, which means OpenROAD's `repair_design` or a full
place and route. Only after that is an Fmax number meaningful.

## Phase V17 — the whole subsystem at gate level (2026-08-21)

The subsystem now goes through the gate flow, not just three blocks,
and **the software tests run on the netlist with the same cycle counts
as on the RTL**:

| program | RTL | gate |
|---------|-----|------|
| smoke | 301 | 301 |
| `safety_test` | 267 | 267 |
| `trap_test` | 397 | 397 |
| `fence_csr_test` | 193 | 193 |

Cycle-identical is a stronger statement than functionally equivalent.
It says synthesis changed no sequential behaviour anywhere on those
paths — not the lockstep delay, not the fetch buffer, not the trap
sequencing.

Synthesised size, memories excluded: **5 433 flip-flops, 529 175 µm²**
in SG13G2, about 0.53 mm².

> **Corrected in V18.** Sixty-four further flops — two cores' worth of
> program counter — did not map to library cells and were left as
> behavioural Verilog, because `fetch_pc_q` resets to the `boot_addr_i`
> *port* and no standard cell resets to a data value. So this netlist
> is 5 433 mapped cells plus 64 behavioural flops, not 5 497 cells.
> The cycle-identical result below stands; "the whole subsystem in
> cells" was an overstatement. See V18. That is the dual-core lockstep, the safety
controller, the watchdog, the clock monitor, the AMS interface, the
BIST controllers, the interrupt controller and the bus.

### The memories have to be black boxes, and saying so in yosys is not enough

The TCMs are 4 096 × 39 arrays. Synthesised as logic they are a third
of a million flip-flops: a first attempt mapped **325 107** before it
was killed. In silicon they are compiled SRAM macros that a netlist
instantiates rather than contains.

The obvious move — `blackbox cdriscv_tcm` inside yosys — does nothing,
and does it quietly. The slang front end specialises parameterised
modules, so the instances are `$paramod\cdriscv_tcm\Depth=...` and the
command matches no module at all. No error, no warning; the run simply
carried on synthesising the memories, and the only symptom was that it
was slow. **A no-op that looks like a long-running job is a bad failure
mode**, and the reason this is written down rather than quietly fixed.

`verif/gate/cdriscv_tcm_bb.sv` is a stub with identical ports,
substituted for the real file at read time, which cannot silently miss.
Simulation binds the real module back in its place, so the memory
behaves exactly as at RTL while everything around it is gates — and
`dut.u_itcm.mem` is still a valid path, which is what lets the existing
testbench preload the program unchanged.

### What a netlist cannot be asked to do

Two testbench assumptions broke, both of them reasonable at RTL and
both wrong against a netlist:

* **Parameter overrides.** The bench instantiates the subsystem with
  `#(.Lockstep(1'b1), .ItcmWords(4096), ...)`. A netlist is one
  configuration; synthesis has already resolved those. The overrides
  are now compiled out under `GATE_LEVEL`. They happen to be the RTL
  defaults, which is what makes the two runs comparable — if they ever
  diverge, the gate flow has to pass matching `-G` options to synthesis
  rather than the bench overriding anything.
* **One white box reference.** `dut.u_safety.status_q` has no
  hierarchical path after flattening. The memories keep theirs only
  because they are black boxes. Same lesson as V16's `acc_q[32]`: a
  bench reused at gate level has to know which of its checks are about
  the RTL and which are about the design.

### Still not done

No timing, as before — the models are zero-delay and this says nothing
about whether the netlist closes. The longer programs (`periph`, `ams`,
`regwalk`, `reaction`) are not in the gate run; they take up to two
million cycles at RTL and the gate netlist is far slower per cycle.
And the five state machines other than the multiplier's still have
their W2a recovery argument resting on the RTL alone.

## Phase V16 — gate level simulation, objective O8 started (2026-08-21)

The RTL is now synthesised to real IHP SG13G2 standard cells and the
**same block benches re-run against the netlist**. Passing on the RTL
and passing on the gates are different claims: synthesis restructures
logic, re-encodes state, and deletes anything it can prove unreachable.

| block | cells | area | result |
|-------|-------|------|--------|
| `cdriscv_alu` | combinational | 8 543 µm² | 453 840 vectors pass |
| `cdriscv_multdiv` | 174 flops | 25 040 µm² | 4 800 vectors, constant 33-cycle latency |
| `cdriscv_ecc_enc` | combinational | 1 132 µm² | with the decoder below |
| `cdriscv_ecc_dec` | combinational | 2 306 µm² | 209 308 checks, all 39 single bit and all 741 double bit errors |

**This is a functional gate level simulation and not a timing one.**
Every delay in the SG13G2 Verilog models is `(0.0,0.0)` — they are
placeholders for back-annotation. What this checks is that the netlist
computes what the RTL computed and that nothing goes X. Timing needs
static timing analysis against the same library and is not done.

### The specify-strip that silently produced an all-X netlist

Icarus rejects the cell models as shipped — "ifnone with an
edge-sensitive path is not supported" — so the `specify` blocks have to
go. Deleting them is not enough, and getting it wrong is silent in the
worst way.

The sequential models read their data, clock and reset from
`delayed_D`, `delayed_CLK` and `delayed_RESET_B`, and **those nets are
driven by the timing checks inside the specify block**. Remove the
block and nothing drives them: every flip-flop clocks X for ever. The
first attempt did exactly that, and all 4 800 multiplier vectors
returned `xxxxxxxx`.

`scripts/strip_specify.py` now ties each `delayed_X` to `X` as it
removes the block, which is the standard zero-delay transformation. The
ALU passed either way, being combinational — a design with no
sequential logic would have hidden this completely.

### Synthesis independently confirmed invariant V0-A1

With the netlist computing correctly, the multiplier bench still
reported 168 000 invariant violations. The invariant is V0-A1: the top
bit of the accumulator never carries information.

The netlist contains

```verilog
assign acc_q[32] = 1'hx;
```

with flops for the other thirty-two bits. **yosys reached the same
conclusion the invariant asserts** — bit 32 carries nothing — and
removed it, so the bench's white box probe was reading a don't-care.

A hand-written invariant and an optimiser arriving at the same
conclusion by different routes is about as good as confirmation gets.
The check is now guarded by `+NOWHITEBOX`; the RTL run still makes it,
the gate run states plainly that it did not.

The general point: **a white box assertion is an assertion about the
RTL, not about the design.** Any bench reused at gate level has to
separate the two, and say which it checked.

### W2a re-argued against the netlist, and it holds

Waiver W2a keeps the state machines' `default:` arms on the grounds
that they are unreachable in simulation but are what returns the
machine to a defined state after an upset. The waiver itself says that
argument has to be re-made against the netlist, because synthesis may
notice the state is unreachable and optimise the recovery away.

`verif/gate/tb_gate_fsm.sv` is that check, on real cells. The
multiplier's three states are encoded in two flip-flops, so exactly one
encoding is unused. Forced into each in turn:

| encoding | next state |
|----------|-----------|
| `00` (idle) | `00` |
| `01` (compute) | `01` |
| `10` (finish) | `00` |
| **`11` (unused)** | **`00`** |

None produced X, the unused encoding returns to idle, and after being
forced through the illegal state the netlist still computes 7 × 6 = 42.
**The recovery survives synthesis**, so W2a stands at gate level for
this module.

### What is not done

Three blocks, not the subsystem. The full subsystem cannot go through
this flow as it stands: the TCMs are 4 096 × 39 arrays that synthesis
would turn into a hundred and sixty thousand flip-flops. That needs the
memories black-boxed and behavioural models bound in their place, which
is the next step for O8. The other state machines named in W2a — the
AMS sequencer, the APB bridge, the LSU, the BIST — have not been
checked this way yet, and neither has the core.

## Phase V15 — the last three cover points, and a waiver that was wrong (2026-08-21)

The three functional coverage holes left by V14 were all mechanisms
software cannot provoke: it cannot corrupt its own register file
parity, cannot make a passing BIST fail, and cannot watch the reset it
is about to be given. All three now have checks in `tb_safety`, and
**functional coverage is 100 %, 65 of 65 points.**

Each check was mutation-tested: remove the parity force, the BIST read
data corruption, or the watchdog reset enable, and the corresponding
check fails.

Getting there turned up three things worth recording.

### A BIST failure is only reported when the BIST finishes

`fault_int[FLT_MBIST]` is `done && fail`, not `fail`. A failing BIST
runs the whole march to completion and reports at the end rather than
stopping at the first bad word. The check waits for `done_o`
accordingly. Worth knowing for anyone sizing a start-up self-test
budget: a failing memory costs the same time as a healthy one.

The first version of that check also sampled `status_q` in the cycle
the wait loop exited, and reported a clean status with `done` and
`fail` both set. The status latches on the *next* edge.

### The watchdog counter resets to 0xffff_ffff

Enabling the watchdog and waiting for a time-out is a four billion
cycle proposition from reset. The check deposits a small count and lets
it run down; the reload from `PERIOD` only happens after the first
time-out.

### Coverage was being measured over Verilator's own source

Adding a Verilator build of the safety bench dropped reported line
coverage from 94.4 % to 87.9 %, with the denominator jumping from 302
lines to 405. Nothing had regressed. The new build pulled in
Verilator's `verilated_std.sv`, and the report counted it as design
code — it excluded files named `tb_*` but nothing else.

**A file now counts as RTL if and only if it is in the repository's
`rtl` tree.** This is the same mistake as V7-M1 in a new costume:
a coverage number is only as good as the denominator, and the
denominator has to be defined by something other than a naming
convention.

Corrected figures, and the denominator is larger than before because
the fourth build instruments lines the other three never compiled:

| metric | value |
|--------|-------|
| line | 96.0 % (358 of 373), 100 % with reviewed waivers |
| toggle | 94.8 % |
| functional | **100 %** (65 of 65) |

### W2 was wrong, and it was wrong in the way waivers usually are

Reconciling the waiver document against the actual uncovered lines
showed it claimed seventeen and its tables accounted for fourteen. The
three unlisted lines were the decoder's illegal-instruction defaults,
and checking them gave three different answers:

* `cdriscv_decoder.sv:252` really is unreachable — the OP-IMM `funct3`
  case lists all eight values. Now waived properly.
* `cdriscv_decoder.sv:322` is **reachable**: a SYSTEM instruction with
  `funct3 = 100` leaves `csr_op` undecodable.
* `cdriscv_decoder.sv:327` is **reachable**: the top level opcode
  default, which any unknown opcode reaches.

So two lines had been waived as unreachable without anyone checking, in
a document whose entire purpose is to be that check. Both are now
covered — `fence_csr_test.S` executes `0x00004073` and `0x0000000b` and
requires each to trap. Fifteen lines remain waived, and the count now
reconciles.

A waiver list that does not add up against the uncovered count is not a
review. The arithmetic is the cheapest part of it, and it was the part
that was skipped.

## Phase V14 — functional coverage, objective O7 (2026-08-21)

Line and toggle coverage say which of the RTL ran. They cannot say
which *situations* were reached, and that is what a verification plan
is actually asking. A design can sit at 100 % line coverage having
never taken an interrupt, never seen a bus error and never run a
division by zero.

`verif/cover/cdriscv_cover.sv` is 65 cover points over the core, the
fetch stage, the TCMs, the safety controller and the watchdog. They are
`cover` statements rather than covergroups because Verilator implements
those and merges them into the same database as line and toggle
coverage, so one `make coverage` measures all three — reported
separately, which is the standing correction from V7-M1.

Everything attaches with `bind`. A bind port expression is elaborated
in the scope of the target module, so `retire`, `trap_cause` and
`fault_latched` can be sampled without adding a single port to the RTL.

### What it found immediately: four unexercised safety mechanisms

**Functional coverage 92.3 % on the first run, 60 of 65 points.** The
five misses were the interesting part, and four of them were safety
mechanisms no test had ever provoked:

| point | meaning |
|-------|---------|
| `cp_flt_itcm_cor` | I-TCM single bit ECC error never reported |
| `cp_flt_itcm_unc` | I-TCM double bit ECC error never reported |
| `cp_flt_rf_parity` | register file parity fault never provoked |
| `cp_flt_bist` | memory BIST has never failed |
| `cp_wdog_reset` | watchdog has never requested a reset |

The two I-TCM points are the clearest miss. The ECC self-test has a
target select bit — `SELFTEST[3]`, added when V4-F1 was fixed — and
every test had exercised it with that bit clear. **Half the mechanism
was unverified**, and nothing in the line coverage could show it,
because the D-TCM tests execute exactly the same RTL lines.

`safety_test.S` now runs both self-tests against the I-TCM as well,
corrupting two words of data that live in instruction memory and are
never executed. Retargeting either injection back to the D-TCM fails
the new checks, so they are not passing by accident.

**Functional coverage 92.3 → 95.4 %.** Three points remain uncovered
and each is a real hole: register file parity, BIST failure and
watchdog reset. All three need a fault the software cannot inject
itself, so each needs bench support.

### V4-F3 has now been asserted wrongly in both directions

Adding two checks to `safety_test.S` broke the lockstep characterisation
test in `tb_safety`, and the way it broke is worth recording.

That check injects a corrupted register write into the checker core and
measures how long the mismatch takes to surface. It originally asserted
detection *did* happen and passed at 2 cycles. V2-P1 moved the timing,
the corrupted register stopped being one the program went on to read,
and the same injection went undetected for 20 000 cycles — so it was
rewritten to assert the opposite. Now two extra checks in the software
shifted the injection onto a register the program reads almost at once,
and detection came back at 14 cycles.

**Both versions were asserting an accident.** What is invariant is
neither outcome but the mechanism: the register write port is not in
the compare vector, so detection can only be indirect — it waits for
the wrong value to reach an address, a branch or a store. Fourteen
cycles or never, depending entirely on the program.

The check now asserts that detection is **not immediate**: a direct
comparison would flag the corruption in the same cycle or the next, so
any latency of two or more is indirect by definition, and never
detected at all is the same finding in its worst form. The measured
latency is printed either way, because that is the characterisation.
Add `rd_addr` and `rf_wdata` to the compare vector and the latency
drops to 0 or 1 and this check fails, correctly.

A second bench bug came out of the same failure: the measurement
started 200 cycles after reset, which had quietly landed on top of
`safety_test.S`'s own lockstep self-test. The status bit was already
set before the corruption was injected, and the bench was measuring the
previous test's leftovers. It now clears the status, checks the clear
took, and injects during register initialisation where the software has
provoked nothing.

### Coverage now stands at

| metric | value |
|--------|-------|
| line | 94.4 %, 100 % with reviewed waivers (O6 met) |
| toggle | 92.3 % |
| functional | 95.4 %, 62 of 65 points (O7 model in place) |

## Phase V13 — peripheral read-back, and objective O6 reached (2026-08-21)

Coverage showed a whole class of lines that had never executed: the
**read** arms of the APB decoders. Software had written plenty of these
registers and read a few, so most of the read multiplexer had never
been selected — and a read arm that decodes to the wrong register is
invisible to every test that only writes.

`verif/core/rdback_test.S` writes a distinctive value to each register,
reads it back and compares, across the timer, watchdog, interrupt
controller, safety controller, BIST and AMS interface. Each block also
gets a read and a write at an offset inside its own slot that decodes
to nothing.

Line coverage **87.1 → 94.4 %**, and eight modules are now at 100 %:
the bus, clock monitor, CSR file, subsystem, TCM, timer, watchdog and
interrupt controller.

### Slot 5 does not behave like the others

The first run failed with an unexpected trap. The unmapped offset that
reads as zero everywhere else raises a **bus error** in the BIST slot,
because the two controllers there each claim only sixteen bytes —
`psel_hit_o = psel_i && (paddr_i[7:4] == RegBase[7:4])` — and the
subsystem raises a slave error for anything in the slot that neither
claims.

That is correct behaviour, so the test now asserts it: the access must
trap with `mcause` 5, load access fault. Checking it is worth more than
routing around it, and the register map now says so.

### A check that could not fail, and the BIST run that fixed it

Reaching the BIST's own undecoded read arm needs a byte access, since a
word access can only produce offsets 0, 4, 8 and 0xc. The obvious check
— byte read at `0x41`, expect zero — passes, but it also passes when
moved to a *mapped* offset, because every BIST register reads zero
until a BIST has run. It discriminated nothing.

So the test now **runs the D-TCM BIST**, which no software test had
ever done. `STATUS` then reads non-zero, the pair of reads means
something, and moving the byte read to a mapped offset is caught.
The BIST completes clean over 4 096 words in about 62 000 cycles.

(The arm still did not get covered, for a reason that turned out to be
a genuine unreachability — see waiver W2c.)

### Objective O6, with the waivers written

The remaining seventeen lines are **all** `default:` arms whose
selector is already fully enumerated. They are now covered by waiver W2
in `verif/coverage_waivers.md`, in three groups with separate
arguments: state machine recovery arms, mux arms over selectors with no
spare encoding, and one APB decode arm the bridge makes unreachable by
forcing `paddr[1:0]` to zero.

The state machine arms are the ones worth arguing about. They are
unreachable in simulation and **must not be deleted**: an upset can put
a state register into an unused encoding, and these arms are what
returns it to a defined state. Deleting them to reach 100 % would trade
a safety property for a coverage number. The evidence that they work is
the fault injection campaign's zero hangs across 3 000 injections, not
any functional test.

W2c was checked rather than assumed. The byte read that should have
reached it is in the test, and the line stayed uncovered — because the
bridge drives `paddr_o = {addr_q[11:2], 2'b00}` and a byte read at
`0x41` arrives as a read of `0x40`.

So **objective O6 is met**: 100 % line coverage with a reviewed waiver
for every exclusion, 94.4 % without any waiver at all.

### Mutation checks

Removing the timer `MTIMECMP` store fails at check 1, the AMS `CHMASK`
store at check 21, pointing the unmapped read at a mapped offset fails
at check 3, and moving the BIST byte read to a mapped offset fails at
check 21 — but only after the BIST run gave it something to compare
against. Before that it passed, which is exactly the failure mode this
project keeps running into: a check that cannot fail.

## Phase V12 — FENCE, FENCE.I and the writable CSRs (2026-08-21)

Coverage again, and again an uncomfortable gap: the core calls itself
RV32IM_Zicsr_Zifencei in its own header and **no test had ever executed
a FENCE or a FENCE.I**. Nor had anything written `mcause`, `mtval` or
`msafestat`, all of which are writable. `verif/core/fence_csr_test.S`
covers both, plus a MISCMEM encoding that is neither FENCE nor FENCE.I
and must trap.

Line coverage 84.8 → 87.1 %, `cdriscv_csr.sv` to 100 %, the decoder
79.2 → 86.4 %.

### V12-O1 — FENCE.I cannot be shown to matter on this core

The obvious test is self-modifying code, and the address map allows it:
the I-TCM is "instruction fetch and data", so a store can patch an
instruction. Patch a routine, `fence.i`, call it, check it returns the
new value. It passes.

It also passes with the `fence.i` replaced by a `nop`, which means the
check never depended on it. The routine was far enough away never to
have entered the fetch buffer.

Moving the patched word closer was the obvious repair and it was also
wrong. Probing directly, with the patched word as the immediate
successor of the store:

| between store and target | result |
|--------------------------|--------|
| nothing | stale buffered word runs |
| `fence.i` | patched word runs |
| **`nop`** | **patched word runs** |
| two `nop`s | patched word runs |

The no-op control is the whole story. The window in which a stale
instruction survives is exactly one instruction wide, and inserting the
FENCE.I closes that window by occupying the slot — whatever the FENCE.I
itself does. A test built on this would have been reported as proof
that FENCE.I flushes the fetch buffer, and it would have proved
nothing.

So the honest position: **FENCE.I is not observable through
self-modifying code on this core.** There is no instruction cache, only
a short fetch buffer. The instruction is still doing real work — under
bus back-pressure the fetch runs further ahead of execution, and then
the redirect is what saves the program — but that is an argument from
reading the RTL, not something a software test on this design
demonstrates. The test says so in the source, at length, where the
missing check would otherwise be.

What the test does establish: FENCE and FENCE.I decode rather than
trapping, retire, redirect without corrupting the register file, and
the I-TCM data write path works.

### The CSR checks

`mcause` written with all ones must read back `0x8000001f` — only the
interrupt flag and the low five code bits exist, and asserting the mask
rather than the value catches a register that is wider than the
specification allows. `mtval` round-trips a full word. `msafestat` is
write-one-to-clear over whatever the safety logic has posted, so the
check is that clearing never *sets* a bit that was not there, which
stays honest whether or not an event happens to be live.

Each assertion was mutation-checked: removing the store fails at check
5, removing `csrw mtval` fails at check 8. Removing the `fence.i`
changes nothing, as documented above.

## Phase V11 — the clock monitor (2026-08-21)

Coverage put this module on the list rather than any suspicion about
it: the branch reporting a *stopped* system clock had never executed.
It cannot be reached from software running on the subsystem, for the
obvious reason — the software would have to stop the clock it is
running on — so it needed a bench that owns the clock generator.
`verif/block/clkmon/tb_clkmon.sv` overrides `HbDiv` and `CntW` to small
values so the counter saturates in tens of reference cycles rather than
2^24; the logic under test is identical, only the constants differ.

The bench was written to cover one branch. It found three defects, all
in the same corner: the handover between the two clock domains.

### V11-F1 — the sticky status could not be cleared

`STATUS[0]` is documented write-one-to-clear. One write never cleared
it. The write reaches the reference domain as a pulse and takes the
round trip through both synchronisers — about twenty system cycles — to
bring the fault level back down, and for every one of those cycles

```systemverilog
if (sys_fault) sts_range_q <= 1'b1;
```

re-set the bit the write had just cleared. Measured directly: after one
write `ref_fault_q` is 0, `sys_fault` is 0 and `sts_range_q` is still 1.
A second write clears it, because by then the level has gone.

So the register behaved neither as documented nor as anything software
could reasonably guess. `sts_range_q` now latches the *rising edge* of
the synchronised fault, so a write clears it even while the level is
still on its way down.

### V11-F2 — a spurious fault on every reconfiguration

The first heartbeat edge after enabling ends a period that began before
the monitor was watching. Its count is a fragment, and it was being
compared against the window like any other measurement.

From cold this happened to be harmless — the fragment measured 4
against a window of 2 to 8. After a disable and re-enable it was not,
and the register map instructs software to disable the monitor before
changing `MIN` or `MAX`, so the false fault would land on every
reconfiguration. The first edge after enable now only starts the first
real period.

### V11-F3 — the window crosses domains unsynchronised, and my first fix was wrong

`min_q` and `max_q` are written in the system domain and used in the
reference domain, as multi-bit buses with no synchroniser. The module
header claimed the only crossings were single bits and the measurement
result; that was simply not true.

Calling them quasi-static is not sufficient on its own. "Written while
`CTRL.enable` is 0" is true in the system domain several reference
cycles before the reference domain sees the disable, and a measurement
completing inside that window is judged against a window half old and
half new. The bench caught this as a fault appearing on a monitor that
had just been switched off.

**The first fix for it was wrong, and the reaction test caught it.**
Refreshing the reference domain's copy only while it can see
`CTRL.enable` low requires software to hold the monitor disabled long
enough for that level to cross — several reference cycles, which at a
1 MHz reference is hundreds of system cycles. Real software disables,
writes the window and re-enables in a handful of instructions, so the
disable never crossed, the copy was never refreshed, and the monitor
silently went on judging against the old window. `reaction_test.S`
failed at check 5 within minutes of the change: a window the clock
cannot possibly meet did not trip it.

The window is now captured at the boundary that *starts* each
measurement period. A period is always judged against the window in
force when it began, a write landing part way through cannot be half
applied, and no disable has to be observed for a new window to take
effect. A write racing the capture itself can still garble the window
for a single period, so the quasi-static rule stays in the register
map — but it is now an ordinary recommendation rather than a
requirement software cannot actually meet.

### An observation, not a defect

`ref_saturate` is `ref_cnt_q >= ref_max_q` and is tested before the
range comparison, so `ref_cnt_q > ref_max_q` in the range check can
never be true — the counter is stopped and the fault raised the moment
it reaches the limit. A clock that is too slow is therefore reported
through the saturation path rather than the range path. The behaviour
is right, and the consequence worth knowing is that `COUNT` reads `MAX`
after such a fault rather than the true, larger measurement. That is
now in the register map.

### What this says about the rest

Three defects in one module, all of them in the crossing between the
two clock domains, none of them reachable by the software tests that
were already passing. The module was not suspected — it was picked
because a coverage report said one branch had never run. That is worth
remembering for the modules still carrying coverage waivers.

## Phase V9 — fault injection campaign (2026-08-21)

`make fi` injects single event upsets and classifies what happens:
detected by a safety mechanism, silent but correct, **silent data
corruption**, or hang. The SDC count is the one that matters — a fault
that changes the result and reports nothing is precisely what the
safety mechanisms exist to prevent, and it is the input an FMEDA needs.

The workload computes a deterministic checksum over arithmetic, memory
traffic and branches, and publishes it, so a corrupted run is
detectable by comparison rather than by inspection.

**The fault list is a named set of nine state elements**, not every
flop in the design: register file word and parity bit, fetch buffer
word, fetch PC, `mepc`, `mstatus.MIE`, LSU address offset, and an
I-TCM and a D-TCM word. That limitation is printed at the top of every
report, because a diagnostic coverage figure means nothing without the
fault list it was measured over. A full flop-level campaign needs a
harness that can enumerate the netlist, which this is not.

### Results: 300 upsets

| outcome | count | share |
|---------|-------|-------|
| detected by a safety mechanism | 112 | 37.3 % |
| silent, result still correct | 188 | 62.7 % |
| **silent data corruption** | **0** | **0 %** |
| hang | 0 | 0 % |

**No upset produced an undetected wrong answer.** Every fault either
was reported or left the checksum intact.

By state element, and this is where it gets interesting:

| state element | detected | silent | reading |
|---------------|----------|--------|---------|
| fetch program counter | **28 / 28** | 0 | lockstep catches every one |
| fetch buffer word | 24 / 29 | 5 | |
| I-TCM word | 22 / 28 | 6 | ECC |
| core register file word | **13 / 30** | 17 | see below |
| D-TCM word | 14 / 34 | 20 | |
| register file parity bit | 9 / 38 | 29 | a parity bit upset is harmless unless its word is read |
| LSU address offset | 2 / 35 | 33 | only live during an access |
| `mepc` | **0 / 41** | 41 | dormant: this workload takes no traps |
| `mstatus.MIE` | **0 / 37** | 37 | dormant: this workload uses no interrupts |

Which mechanism reported: lockstep 76, I-TCM ECC corrected 22, register
file parity 18, D-TCM ECC corrected 14, bus error 13, core trap 7. A
single fault often sets several.

### Workload B: the same faults, with the trap path alive

The two worst rows above were not design results, so the next step was
to write a workload that makes those bits live and inject into it
again. `fi_workload_trap.S` takes an `ecall` every iteration, at a
fixed program counter, and runs the machine timer with its interrupt
enabled. The handler folds `mepc` into the checksum and returns
through it, and counts interrupts into the checksum too, so losing
either changes the answer.

Whether the workload really does what it claims is checked against an
independent Python model of the checksum, which recovers the number of
traps and interrupts from the result: **64 traps and 14 timer
interrupts**. The same model reproduces workload A's golden value
exactly when told to take neither, which is a pleasant cross-check on
both.

300 further upsets, same fault list, same seed:

| state element | workload A | workload B |
|---------------|-----------|-----------|
| `mstatus.MIE` | 0 / 37 | **35 / 38** |
| `mepc` | 0 / 41 | **12 / 34** |
| fetch program counter | 28 / 28 | 38 / 38 |
| I-TCM word | 22 / 28 | 28 / 28 |
| fetch buffer word | 24 / 29 | 20 / 30 |
| core register file word | 13 / 30 | 18 / 40 |
| D-TCM word | 14 / 34 | 11 / 26 |
| register file parity bit | 9 / 38 | 10 / 34 |
| LSU address offset | 2 / 35 | 1 / 32 |
| **total** | 112 / 300, 37.3 % | **173 / 300, 57.7 %** |

Mechanisms on workload B: lockstep 134, I-TCM ECC corrected 28, bus
error 27, register file parity 20, D-TCM ECC corrected 11, core trap 8.

**Still zero silent data corruption and zero hangs**, now over 600
injections across two workloads.

`mstatus.MIE` going from 0 to 35 out of 38 settles it: the bit was
never a hole in the safety concept, it was dead state. It is caught
because losing the bit changes whether an interrupt is taken, which
changes the program counter, which is compared. `mepc` improves to
12 of 34 rather than to near-total, and that is the honest number: an
upset in `mepc` only matters between trap entry and the `mret` that
consumes it, perhaps a dozen cycles per trap, and outside that window
the next trap overwrites it. Narrow exposure, not weak detection.

Two rows did not move and are the ones to look at next. The register
file sits at 45 % on workload B against 43 % on workload A — the same
answer twice, from a workload that stresses it quite differently,
which is V4-F3 yet again. The LSU address offset is 1 of 32, and for
the same reason as `mepc`: those two bits are only live during an
access. Unlike `mepc`, nothing overwrites them in between, so this one
deserves a workload that keeps the LSU busy before it can be called
narrow exposure rather than a gap.

### Workload C: settling the LSU row

The one row workload B left open was the LSU address offset, detected
once in thirty two. Those two bits select the byte lane and are live
only while an access is in flight, so the low number could be narrow
exposure — or a real gap, since unlike `mepc` nothing overwrites them
in between. The two cases are told apart by raising the exposure and
seeing whether detection follows.

`fi_workload_mem.S` is almost nothing but loads and stores, at every
width and alignment the ISA allows, in both sign extending and zero
extending forms. Its checksum is reproduced exactly by an independent
Python model of the memory, which is a free cross-check on the LSU's
sub-word paths as well as a golden value.

| state element | A: arithmetic | B: traps | C: memory |
|---------------|--------------|----------|-----------|
| **LSU address offset** | 2 / 35 (6 %) | 1 / 32 (3 %) | **10 / 39 (26 %)** |
| I-TCM word | 22 / 28 | 28 / 28 | 34 / 34 |
| fetch program counter | 28 / 28 | 38 / 38 | 31 / 32 |
| core register file word | 13 / 30 (43 %) | 18 / 40 (45 %) | 19 / 36 (53 %) |
| register file parity bit | 9 / 38 | 10 / 34 | 11 / 37 |
| fetch buffer word | 24 / 29 | 20 / 30 | 18 / 32 |
| D-TCM word | 14 / 34 | 11 / 26 | 10 / 23 |
| `mepc` | 0 / 41 | 12 / 34 | 0 / 30 |
| `mstatus.MIE` | 0 / 37 | 35 / 38 | 0 / 37 |
| **total** | 112 / 300 (37.3 %) | 173 / 300 (57.7 %) | 133 / 300 (44.3 %) |

Detection on the LSU offset rises roughly eightfold when the workload
keeps the LSU busy, so that row is narrow exposure and not a gap.
`mepc` and `mstatus.MIE` drop back to zero on C, which takes no traps
and enables no interrupts — the same effect as on A, now seen a second
time and from a workload written for an unrelated reason.

**900 injections across three workloads, still zero silent data
corruption and zero hangs.**

That leaves exactly one row that does not respond to what the software
does: the core register file, at 43, 45 and 53 per cent across three
workloads that stress it very differently. Three independent
measurements and a characterisation test now say the same thing, and
they say it about the one piece of state that is not in the lockstep
compare vector.

### A trap the campaign setup was one bound away from

Workload C runs for 2 416 cycles. The injection window was initially
set to 3 300, so roughly a quarter of the runs would have scheduled
their deposit after the workload had already exited — no injection at
all, result correct, no fault reported, filed as silent-ok. The
campaign would have reported a *lower* detection rate and called it a
result.

The bench now reports whether the deposit actually happened, and the
driver counts a run that never injected separately, excludes it from
the percentages, and prints a warning. A campaign that silently counts
faults it never injected is worse than no campaign, because the number
still looks like a number.

### V10 — scaling the campaign to 3 000, and what scaling exposed

1 000 injections per workload, seed 11.

| state element | A: arithmetic | B: traps | C: memory |
|---------------|--------------|----------|-----------|
| fetch program counter | 112 / 113 | 126 / 127 | 106 / 106 |
| I-TCM word | 82 / 118 | 113 / 113 | 119 / 119 |
| fetch buffer word | 97 / 122 | 92 / 124 | 74 / 112 |
| D-TCM word | 56 / 114 | 48 / 104 | 64 / 121 |
| core register file word | 37 / 90 | 51 / 110 | 30 / 97 |
| register file parity bit | 22 / 112 | 20 / 94 | 17 / 115 |
| `mstatus.MIE` | 0 / 85 | **100 / 112** | 0 / 124 |
| `mepc` | 0 / 121 | **20 / 110** | 0 / 113 |
| LSU address offset | 4 / 125 | 3 / 106 | **18 / 93** |
| **total** | 410 / 1000 (41.0 %) | 573 / 1000 (57.3 %) | 428 / 1000 (42.8 %) |

**3 000 injections, three workloads, still zero silent data corruption
and zero hangs.** The fetch program counter is 344 of 346 across all
three, and the I-TCM is 314 of 350.

The conclusions from the 300 run pilot all survive: activation is what
drives the `mepc` and `mstatus.MIE` rows, the LSU offset responds to a
workload that keeps the LSU busy, and the register file does not
respond to the workload at all.

The individual pilot figures did not survive nearly as well. The
register file on workload C read 53 % over 300 runs and 31 % over
1 000; the same row on A moved 43 → 41 % and on B 45 → 46 %. A single
row of a 300 run campaign is worth about ±15 points, which is worth
remembering before any of these numbers is quoted as a rate.

### The campaign could destroy its own results

Scaling to 1 000 broke the driver. One simulation exceeded the 600 s
subprocess timeout, `TimeoutExpired` propagated out of the thread pool,
and the campaign died having thrown away 999 completed results.

Worse, it reported success. Every simulation recipe in the Makefile
ends in `| tee somelog`, and a shell pipeline exits with the status of
its *last* command, so `vvp ... | tee` returns 0 however the simulation
ended. Verified directly: `vvp` alone exits 1 on `$fatal`, `vvp | tee`
exits 0. Eleven recipes were written that way — every block bench and
every software test. **A failing test reported a passing `make`, and
the CI workflow would have gone green on it.** `.SHELLFLAGS` now
carries `pipefail`; with the same deliberately failing simulation,
`make` goes from exit 0 to exit 2. The whole suite was then re-run
under the fixed gate and everything passes, so nothing had been hiding
behind it — but that was luck, not design.

The driver now catches the timeout, classifies that run `sim-timeout`,
and reports the rest.

**A diagnosis I got wrong.** I first put the overrun down to a hung
core running to the bench's 400 000 cycle give-up point, roughly ninety
times any workload's length. That was wrong. Re-running the identical
seed and fault list with the give-up point at 400 000 produced results
identical to the 50 000 run target for target, took no unusual time and
did not crash. Nothing hangs, and the cutoff was never the cause. The
overrun was one simulation losing a race with machine load, and it did
not reproduce. What changed for the better is that it can no longer
take a campaign down with it; the tighter cutoff is worth keeping on
its own merits, but it fixed nothing.

### What these numbers do and do not say

**They are not a diagnostic coverage figure**, and should not be quoted
as one. Three reasons, all of which have to travel with the numbers:

* The two worst-looking rows, `mepc` at 0/41 and `mstatus.MIE` at 0/37,
  are not evidence that those faults are tolerated. They are evidence
  that **this workload never activates them** — it takes no traps and
  enables no interrupts, so those bits are dead state for the whole
  run. Workload B, below, confirms it: the same faults on a workload
  that uses the trap path are detected 35 times out of 38. Measuring
  activation, not just outcome, is the missing piece, and it is a
  property of the workload set rather than of the design.
* The fault list is nine named elements, not the ~5 000 flops the
  design synthesises to.
* 3 000 runs across three short workloads is still short of the 10^4
  per workload the plan asks for, and short workloads at that. The campaign driver now
  runs simulations concurrently, which is what makes that number
  reachable; the fault list is drawn from the seeded generator before
  any of them start, so the results do not depend on `--jobs`. Workload
  A was re-run through the concurrent driver and reproduced the serial
  numbers exactly, target by target.

**The register file row is the one to act on.** 13 of 30 detected,
against 28 of 28 for the fetch PC. That is finding V4-F3 measured
rather than argued: the fetch PC reaches a compared signal immediately,
while a corrupted register is only caught if the value is read again.
Two independent methods now say the same thing — the characterisation
test in `tb_safety`, and this campaign — and both point at adding
`rd_addr` and `rf_wdata` to the lockstep compare vector.

### Two bench bugs, one of which would have been very expensive

**The injector silently did nothing.** The first version deposited the
flipped bit inside `always @(posedge clk)` — the same edge on which the
DUT's own flops assign. The order between the two is undefined, so the
corruption was usually overwritten before anything could see it. Every
run came back clean.

That is the worst possible failure mode for a fault injector: it
reports **perfect detection** and there is nothing in the output to
suggest anything is wrong. It was caught only because the same
injection gave different results for different bit positions, which a
working injector would not do. The deposit now happens on the falling
edge, where it survives to be read.

**The D-TCM was not preloaded**, so the workload's sub-word stores —
read-modify-write — read uninitialised memory and X propagated into the
safety status. That is finding V4-F2 met from the other side, and it is
the second time an unwritten TCM has cost time.

### Method note

A *deposit* is used rather than `force`/`release`: the bit is written
and then left, so the next clock edge may overwrite it exactly as in
silicon. A held force models a stuck-at, which is a different fault
model and would flatter the detection numbers.


## Phase V6 complete — LSU and safety controller (2026-08-21)

The last two blocks on the plan's formal list are done, so **all six
targets in section 6 now have properties**: fetch stage, SEC-DED,
interconnect, decoder, LSU, safety controller. `make formal` runs six
benches.

### LSU — pass

The load/store unit drives its bus outputs combinationally from the
core's request, which means the core owes it stability: address, size
and write data must not move while an access is in progress. That
obligation is written into the wrapper **as an assumption**, so it is
visible rather than implied — if the core ever breaks it, the proof
stops applying and someone can see why.

What the LSU owes in return is asserted: never two accesses in flight,
word-aligned bus addresses, byte enables that match the size and offset
against an independently written reference, and a completion reported
only when a response actually arrives.

Mutation tested: unshifted halfword byte enables and an unaligned bus
address are both caught by the property meant for them.

### Safety controller — pass, after two rounds of counterexample

Two claims the safety manual makes are structural, and this is where
they stop being prose:

* a latched fault does not go away by itself — it clears only through a
  write of 1 to its own bit,
* once the configuration is locked it stays locked, and none of the
  reactions can be changed.

The third property took two counterexamples to state correctly, and
both were the tool teaching me the contract rather than finding a bug:

1. *"the reset request is a one-cycle pulse"* — **false in six steps**.
   Two different fault bits latching on consecutive cycles each ask for
   their own reset, so the request can legitimately be high twice
   running. Bounded by the number of fault bits, and harmless.
2. *"...unless the status changed"* — **also false**. Software writing
   `REACT_RST` while a fault is already latched asks for a reset the
   previous configuration had not asked for.
3. *"...unless the status **or the reaction configuration** changed"* —
   **passes**. Which is the real requirement: the request cannot
   sustain *itself*. With nothing latching and nothing reconfigured, it
   must fall.

That third form is exactly finding V7-F1 — the level-driven request
that held the core in reset for ever — and the mutation test confirms
it: **re-introducing V7-F1 is now caught by `p_reset_req_no_repeat`.**
That bug is guarded by a property rather than only by a test, so it
cannot come back unnoticed.

Also mutation tested: a lock that fails to protect `ENABLE` is caught
by `p_lock_enable`.

### On properties that fail three times before they are right

Each of those counterexamples looked at first like a possible bug, and
each was the specification being sharpened instead. That is the normal
shape of writing properties for a design one already believes is
correct, and it is worth saying because the failures are not wasted
work: the final property is stronger and *narrower* than the one first
written, and it says something true rather than something hopeful.


## Phase V6 continued — the decoder, over every encoding (2026-08-21)

`make formal-dec` proves, over **all 2^32 instruction encodings**, that
an instruction the decoder rejects has no architectural effect: no
register write, no memory access, no control transfer, no CSR access,
no system side effect. The decoder is combinational, so depth 2
quantifies over the whole input space, and it takes 0.3 seconds.

This is the property that matters for safety. If a reserved encoding
raised `illegal_instr_o` *and* set `rf_we`, the core would take an
illegal instruction trap and corrupt a register on the way — a silent
data corruption reachable by a bit flip the ECC miscorrected, or by a
wild jump into data. No simulation can rule that out across the whole
encoding space; this does.

Two further properties: a memory access is never also a multiply, and a
branch is never also a jump.

### Mutation testing, and an equivalent mutant

| mutation | result |
|----------|--------|
| illegal no longer clears `rf_we` | caught by `p_illegal_no_rf` |
| illegal no longer clears `csr_access` | caught by `p_illegal_no_csr` |
| the `instr[1:0] != 2'b11` check removed | **not caught — and correctly so** |

The third is an *equivalent mutant*, not a gap. Every valid RISC-V
opcode has bits [1:0] = 11, so an encoding that fails that test also
fails to match any case item and lands on the opcode `default`, which
already reports illegal. Removing the explicit check does not change
the function.

Worth knowing rather than just noting: that check is **redundant
defensive code** today. It is kept because it states the intent, and
because it becomes load-bearing the moment compressed instructions are
added — at which point 16-bit encodings must be *accepted* rather than
rejected, and that line is where the change starts.

### Reserved encodings in simulation too

`make trap` now also executes one reserved encoding per opcode group —
BRANCH, LOAD, STORE, OP-IMM, OP and MISC-MEM — plus a **negative
control**: a legal `ORI` that must *not* trap. Without the negative
control, a decoder that rejected everything would pass the whole
illegal-instruction section.

Decoder line coverage 57 % → 79 %, total **80.3 % → 82.5 %**.

### A process note: check that a new gate actually runs

I added `formal-dec` to the `formal` target's dependencies, but the
edit that was supposed to add the target *itself* did not apply — the
anchor text I matched on had changed. `make formal` then quietly ran
three of the four sub-targets, and my check counted three passes.

I nearly wrote "four formal runs pass" on the strength of an edit I had
not verified landed. Counting the gates that actually ran, rather than
the gates I meant to add, is the check that caught it.


## V2-P1 — the fetch bubble, FIXED (2026-08-21)

The performance finding from phase V2 is now addressed in the RTL, on
the owner's instruction.

**What was wrong.** The fetch stage buffered one instruction and only
issued the next request when that buffer was being emptied. With a one
cycle memory that is a bubble on every instruction — request at T, data
at T+1, execute at T+2 — so **CPI could not go below 2** whatever the
program did.

**The fix, in two parts.** Either alone is insufficient:

* A request may now be issued in the same cycle as the response to the
  previous one arrives. That is the ordinary OBI overlap of an address
  phase with a response phase, and it keeps **at most one transaction
  in flight**, which is what the bus's one-owner-bit-per-slave routing
  requires. Without this the fetcher can only issue every second cycle
  and no buffer depth helps.
* The buffer holds two instructions, so a response always has somewhere
  to land. With one entry the fetcher could not safely run ahead: if
  the execute stage stalled on a multi-cycle instruction, the arriving
  word would overwrite the one waiting.

**Measured, same programs, same bench:**

| program | before | after |
|---------|--------|-------|
| ALU loop, dependent chain | 4405 cycles, **CPI 2.20** | 2406 cycles, **CPI 1.20** |
| the RV32IM co-simulation program | 8823 cycles, CPI 4.41 | 6824 cycles, CPI 3.41 |

Exactly **1999 cycles saved on 2000 instructions** in both: one bubble
per instruction, removed. The residual 0.20 on the ALU loop is the
taken-branch redirect, about two cycles each, which is the next thing
in the backlog. The co-simulation program stays higher because it is
seventeen 33-cycle multiplies and divides plus loads.

**Cost:** 52 614 → 53 155 cells, **+1.0 %**, for the second buffer
entry and its pointers, doubled by the lockstep pair. No latches, no
combinational loops.

### Evidence after the change

| check | result |
|-------|--------|
| random regression, 30 % memory back-pressure | **400/400 programs, 5 629 928 instructions** match Spike |
| formal, all three benches | pass, including `p_pc_stream` on the rewritten stage |
| seven software tests | pass |
| block benches, directed and stalled co-simulation | pass |
| synthesis | no latches, no combinational loops |
| line coverage | 79.9 % → **80.3 %** |

`p_pc_stream` passing on the new stage is the strongest single piece of
evidence: it says the fetch stage still delivers exactly the sequential
stream that began at the last redirect, and it is checked against a
reference model over every interleaving to depth 20.

The withdrawn waiver closed itself by measurement rather than argument.
`cdriscv_if_stage` now reports **27 line points covered and 0
uncovered**, and the branch W1 used to excuse — a redirect coinciding
with a fetch response — executes **57 217 times** in the coverage
stimulus. It went from unreachable to one of the busiest lines in the
block, which is exactly what the waiver predicted would happen.

### What the change broke, and what that says

Three things failed as a direct result, and each was informative.

**1. `p_no_outstanding_at_redirect` — failed exactly as designed.**
That assertion was written last hour to encode why waiver W1 held: with
a one-deep buffer no fetch can be in flight at a redirect. The waiver
said in as many words that deepening the prefetch would make it fail.
It did. The property is removed and **W1 is withdrawn**: those three
lines of the redirect path are now live, not unreachable.

An assumption written as an assertion is an assumption that tells you
when it stops being true.

**2. The bus formal assumption needed loosening.** `a_instr_single`
assumed a master never requests while a transaction is outstanding.
The fetch stage now does exactly that in the response cycle, so the
assumption was updated to permit it — otherwise the bus proof would
have been verifying a master that no longer exists. The data master
keeps the stricter rule, because the LSU still waits for a full
response.

**3. A safety test was passing for the wrong reason (V4-F3, revised).**

`tb_safety` check 3 injected a fault into the checker core's register
write data and asserted it was detected. It passed, at 2 cycles, and
that was recorded as evidence that indirect detection is prompt.

**It was luck.** The check forced the value for one arbitrary cycle and
relied on a register write happening to be in progress; when the fetch
timing moved, the coincidence stopped. Making the injection
deterministic — wait for `rf_we`, then corrupt — the same fault is
**still undetected after 20 000 cycles**, because the corrupted
register is simply never read again.

That is a much stronger statement of V4-F3 than the original: a
corrupted register write is not detected late, it may **never** be
detected at all. The earlier "2 cycles" figure has been withdrawn from
the safety manual.

The check is now a characterisation test: it asserts the weakness, and
is written to fail if `rd_addr` and `rf_wdata` are ever added to the
lockstep compare vector — at which point it should be rewritten to
assert prompt detection.

**This materially changes the FTTI argument** and is the strongest
reason yet to extend the compare vector, which remains a decision for
the owner.


## Phase V6 continued — formal on the interconnect (2026-08-21)

`make formal-bus` checks `cdriscv_bus`. Its risk is bookkeeping rather
than arithmetic: two masters, three slaves and an error responder, with
one owner bit per slave deciding where each response goes. **A
misrouted response hands one master another master's data** — a value
that looks entirely plausible and is wrong, which is precisely the
class of fault a functional test can miss.

Five properties pass to depth 20, with the slaves modelled concretely
(grant when idle, answer one cycle later, which is what the TCM does):

| property | what it says |
|----------|--------------|
| `p_no_spurious_instr` / `p_no_spurious_data` | a master is never handed a response it did not ask for |
| `p_data_wins_itcm` | the data master wins I-TCM arbitration, so the fetcher cannot starve it |
| `p_no_double_itcm` | both masters are never granted the same slave in one cycle |
| `p_no_lost_instr` / `p_no_lost_data` | a granted request is always answered, never dropped |

Mutation tested, both caught by the property meant for them:

| mutation | caught by |
|----------|-----------|
| I-TCM response owner inverted | `p_no_spurious_instr` |
| arbitration lets both masters through | `p_data_wins_itcm` |

### The fourth property — RESOLVED, and it was the harness

The property *a granted request is always answered* failed at step 4
and was left in place, disabled, as an open question: too strong, or a
real dropped response?

**It was neither. It was my harness.** The property was guarded on
`rst_ni` alone, so at the first cycle out of reset `$past()` reached
back into the reset window — where the bus's registers were held clear
but the free inputs were not. It fired on a "grant" that never
happened. Guarding on `$past(rst_ni)` as well makes it **pass to depth
20**.

It has teeth, too. Two mutations that drop a response are both caught
by it:

| mutation | caught by |
|----------|-----------|
| unmapped fetch response never delivered | `p_no_lost_instr` |
| error responder ignores the fetcher | `p_no_lost_instr` |

So `cdriscv_bus` now has **five properties passing**, four of them with
mutation evidence, and the log has no open items again.

### Formal harness pitfalls, three times over

This is the third false result caused by the harness rather than the
design, and they are worth naming together because each looked
convincing:

| # | Symptom | Cause | Tell |
|---|---------|-------|------|
| 1 | `p_single_outstanding` fails at step 1 | BMC starts from an arbitrary state; reset was left free | failure in the *first* step, before anything can have happened |
| 2 | SEC-DED "proven" in 0.3 s | depth 1 never reaches the clock edge, so nothing was checked | a proof that arrives suspiciously fast |
| 3 | `p_no_lost_instr` fails at step 4 | `$past()` reaching into the reset window | failure at the first active cycle, and only there |

The common shape: **anything that happens at the very start of a
bounded run, in either direction, should be suspected of being about
the harness.** Two of the three were false failures and one was a false
pass, which is why the mutation test matters in both directions — it
catches the false pass, and re-reading the counterexample catches the
false failure.

### A frontend note

`cdriscv_bus` cannot be read by yosys' built-in Verilog frontend at all
— it rejects the size cast in the address decode function — so the
formal run uses yosys-slang, as synthesis already does. Three of the
four flows in this project now depend on that plugin.


## Phase V7 continued — waiver W1, and a guess disproved (2026-08-21)

The three unreachable lines in the fetch stage got a proper argument
instead of a plausible one, and the process is the point.

**The guess.** Reading the RTL, I reasoned that with a one-deep buffer
no fetch can ever be outstanding at a redirect, so those lines are dead
code. That reasoning was written into the waiver.

**Formal disproved it in five steps.** Stated as a property —
`p_no_outstanding_at_redirect` — bounded model checking immediately
produced a counterexample: a redirect arriving while the buffer is
*empty* leaves a fetch in flight. The block handles that correctly, so
the lines are defensive rather than dead, and a different execute stage
reusing this block would need them.

**The real argument.** `cdriscv_core` only redirects in a cycle where
it holds a valid instruction: every redirect comes from a trap or a
retire and both require `instr_valid`. Added as an assumption, the
property **passes** to depth 20. So the lines are unreachable *in
context*, not in general — a materially different claim, and the honest
one.

**The assumption is now checked rather than assumed.** `tb_cosim.sv`
asserts `redirect |-> instr_valid` on every co-simulation cycle, so
every directed and random run discharges it. Verified across the
directed program, a 60 % stall run, and 40 random programs.

The waiver in `verif/coverage_waivers.md` now carries the whole chain:
reachable in general, unreachable in context, the in-context assumption
checked in simulation, the general case covered by `p_pc_stream`, and
the lines deliberately retained because finding V2-P1's deeper prefetch
would make them live again — at which point the invariant assertion is
*expected* to fail, which is why it exists.

The general lesson: a plausible structural argument about RTL is a
hypothesis. Writing it as a property costs a few lines and either
proves it or hands back the case you missed.


## Phase V7 continued — memory back-pressure (2026-08-21)

The TCM always grants immediately, so **the wait-for-grant paths in the
LSU and the fetch stage had never run in any test**. Every load, store
and fetch in every program so far took the fast path.

`make cosim-stall` holds memory grants off on a configurable share of
cycles. Putting the injector in the co-simulation bench is the point:
back-pressure must change the **timing and nothing else**, and
comparing against Spike is what checks that.

**Result: identical retired streams at 0, 10, 30, 60 and 90 % stall
rates** — PCs, register writes and memory accesses. The core is
insensitive to memory timing, which is now demonstrated rather than
assumed. `cdriscv_lsu` line coverage 44 % → 56 %, `cdriscv_bus` reaches
100 %.

### Regression under back-pressure

**300 of 300 random programs match, 2 828 026 instructions**, with
grants held off on 35 % of cycles. Random programs against a random
memory schedule, checked instruction by instruction against Spike.

That combination is worth more than either half alone: the random
programs vary what the core does, the stall injector varies when the
memory answers, and the comparison holds the result fixed. Nothing in
the core's behaviour may depend on memory timing, and now that has been
run rather than argued.

### The injector was wrong first, in an instructive way

The first version forced the TCM's **grant output** low. Every stall
rate then produced an apparent core deadlock: the RTL retired five
instructions and stopped.

That was not a design bug. An output port and the net connected to it
are distinct, and a `force` on one need not follow to the other, so the
*bus* saw a grant while the TCM did not accept — the access was issued
and then lost, and the master waited for a response that could never
come. The design was fine; the bench had manufactured a protocol
violation.

Forcing the memory's **request input** low instead keeps both sides
consistent: the TCM does not accept, and its grant falls out low
through the ordinary port connection.

Worth keeping as a general point: a bench that drives a signal in the
middle of a handshake can break the protocol it is trying to test, and
the failure looks exactly like a design bug. The tell was that *every*
stall rate failed, including 10 % — a real deadlock corner would be
rare, not universal.

### W1 — the first coverage waiver

Three lines in `cdriscv_if_stage` remain unreachable in simulation: the
branch taken when a redirect coincides with a fetch response. The TCM
answers one cycle after a grant and the core needs at least two cycles
per instruction, so an outstanding fetch has always completed before
the next redirect. Delaying grants moves the response as a block but
never lands it on the redirect cycle; that needs variable *response*
latency, which the bench does not model. Four stall rates from 15 % to
90 % were tried.

Bounded model checking does cover it — `p_pc_stream` explores exactly
those interleavings to depth 20, and its mutation test kills the
matching bug at step 6. So it is written up in the new
`verif/coverage_waivers.md` as covered-by-formal, with a to-do for a
variable-latency memory model.

That file is the start of the O6 sign-off argument. Its rule: a waiver
states what covers the line instead, or it is not a waiver.


## Phase V7 continued — a correction, and the register walk (2026-08-21)

### V7-M1 — the coverage figure was mislabelled (measurement error, CORRECTED)

**The numbers reported in this log for the last four entries — 62.5 %,
75.1 %, 80.0 %, 83.4 %, 86.0 % — were not line coverage.** They were a
mixture of line and toggle coverage, and the toggle points dominated.

Verilator's `--coverage` enables line *and* toggle points, and
`--annotate` marks a source line uncovered if **any** point attached to
it is uncovered. Declaration lines carry toggle points, so
`output logic pslverr_o` — a signal legitimately tied to zero, which
therefore never toggles — counted as an uncovered "line". Adding up
declarations and statements together produces a number that is neither
metric.

What tipped me off was reading the actual uncovered lines instead of
the totals: the list was full of port declarations, which are not
statements and cannot be "executed".

Corrected, with `--filter-type` splitting the database:

| metric | value |
|--------|-------|
| line coverage | **70.3 %** at the point the mixed figure said 86.0 % |
| toggle coverage | 90.2 % |

Both are now reported separately, by `make coverage`, with their proper
names. The *trend* across the last four entries was real — every test
did close real gaps — but the absolute number was wrong and was
published in the README for several hours. The README now carries both
figures.

The lesson generalises past this project: a coverage tool will happily
add up whatever points it has, and the label on the total is the
reader's assumption, not the tool's promise. Read the uncovered list,
not the percentage.

### Register walk — **pass**

`make regwalk` touches the registers and modes the functional tests
never reach: the timer's prescaler and 64-bit roll-over, the interrupt
controller's edge mode, pending latch and claim, the watchdog's window
mode and a wrong service key, the safety controller's reaction and pin
registers including toggle mode, and the CSRs no program happens to
read. Sixteen checks, all passing.

**Line coverage 70.3 % → 79.6 %.**

Remaining, and now genuinely small:

| module | line coverage | what is left |
|--------|---------------|--------------|
| `cdriscv_decoder` | 66 % | reserved encodings in the remaining opcodes |
| `cdriscv_clkmon` | 68 % | the reference-domain saturation path |
| `cdriscv_lsu` | 44 % | back-pressure on `gnt`, which the TCM never applies |
| `cdriscv_mbist` | 77 % | abort, and the I-TCM instance |
| `cdriscv_if_stage` | 0 of 3 | worth a look: the stage clearly runs, so its three points are probably attributed oddly by inlining |

The `cdriscv_lsu` entry is the interesting one: the TCM always grants
immediately, so the LSU's wait-for-grant path has never run in any
test. That needs a memory model that stalls, which is a bench feature
rather than a program.


## Phase V7 continued — AMS interface (2026-08-21)

`make ams` covers the mixed-signal half of the IP: the limit registers
and range checking, the conversion time-out, the trim output and the
analog test bus. Twelve checks, all passing.

Coverage 83.4 % → **86.0 %**, with `cdriscv_ams_if` going from 68 % to
90.4 %.

One nice property of the setup: the **conversion time-out is provoked
by setting the limit below the bench ADC model's latency** — the model
answers after 20 cycles, the test allows 2 — so a stuck analog block is
exercised without touching the bench at all.

Mutation tested, all three caught:

| mutation | result |
|----------|--------|
| range checking disabled | fails at check 6 |
| the time-out is never reported | the sequencer poll expires, check 8 |
| the captured result is off by one | fails at check 2 |

The middle one exposed a weakness in the test rather than the design:
the poll bound was so large that a stuck sequencer ran the *bench* out
of cycles before the test's own check could fire, so the failure showed
up as a bench time-out instead of naming its check. The bounds are now
tight enough that the test reports itself. A test should fail with its
own voice.

## Coverage, where it stands

| | |
|---|---|
| baseline, before any peripheral test | 62.5 % |
| after peripherals and interrupts | 75.1 % |
| after the safety reactions | 80.0 % |
| after traps and illegal encodings | 83.4 % |
| after the AMS interface | **86.0 %** |

No single module dominates the remainder any more; the largest gap is
20 lines. What is left is a tail:

| module | coverage | what is missing |
|--------|----------|-----------------|
| `cdriscv_csr` | 80 % | the counter CSRs and the read-only ID registers |
| `cdriscv_safety_ctrl` | 77 % | the error pin in toggle mode, `PIN_DIV` |
| `cdriscv_decoder` | 70 % | the remaining reserved encodings |
| `cdriscv_mbist` | 84 % | the I-TCM instance, abort, the fail address path |
| `cdriscv_wdog` | 78 % | window mode and a wrong service key |
| `cdriscv_timer` | 68 % | the prescaler and the 64-bit roll-over |

Objective O6 asks for 100 % with reviewed waivers. Some of this tail is
genuinely unreachable in the shipped configuration — generate branches
for parameter values that are not used — and those need waivers rather
than tests. Separating the two is the next job, and it is the point at
which the coverage number stops being a to-do list and starts being a
sign-off argument.


## Phase V7 continued — traps and illegal encodings (2026-08-21)

`make trap` walks **every exception cause the core can raise** and
checks `mcause`, `mepc` and `mtval` for each: ecall, ebreak, four
different illegal encodings, load and store address misaligned, load
and store access fault, instruction address misaligned, and instruction
access fault. Fourteen checks, all passing on the first run.

Coverage 80.0 % → **83.4 %**, and `cdriscv_core` left the gap table
entirely.

Two details worth keeping:

* The handler returns to an address the main flow puts in `s7`
  beforehand, rather than advancing `mepc` by four. Advancing works for
  most causes but not for an instruction access fault, where `mepc`
  points into unmapped memory and the next fetch would fault again for
  ever. A test that used the obvious `mepc + 4` would hang on exactly
  the case it was written to check.
* The illegal encodings have to be written as `.word` constants. An
  assembler will not emit them, which is precisely why the decoder's
  rejection logic had never run: no valid program contains one, and the
  random generator only emits legal instructions.

Remaining gaps, in order:

| module | coverage | what is missing |
|--------|----------|-----------------|
| `cdriscv_ams_if` | 68 % | the limit registers, the analog flag inputs, the conversion time-out — the mixed-signal half of the IP |
| `cdriscv_csr` | 80 % | the counter CSRs and a few read-only ones |
| `cdriscv_safety_ctrl` | 77 % | the error pin in toggle mode, `PIN_DIV`, the injection register read-back |
| `cdriscv_decoder` | 71 % | the remaining reserved encodings |
| `cdriscv_wdog` | 78 % | window mode, and servicing with a wrong key |
| `cdriscv_timer` | 68 % | the prescaler and the 64-bit roll-over |


## Phase V7 continued — safety reactions (2026-08-21)

`make reaction` runs `verif/safety/reaction_test.S`: configuring the
clock monitor **through its registers** rather than by forcing them,
checking the safety controller's configuration lock, and taking a reset
request — which restarts the core, so the program recognises its own
second boot from a marker left in a peripheral register.

All nine checks pass, and coverage went from 75.1 % to **80.0 %**. The
clock monitor left the top of the gap table entirely.

Writing it found two design bugs, both in the reset reaction, and both
serious.

### V7-F1 — a configured reset reaction bricked the subsystem (design bug, FIXED)

**Severity: high.** `reset_req_o` was a *level*:

```
assign reset_req_o = |(status_q & react_rst_q);
```

The status is sticky and only software can clear it. So the first fault
with a reset reaction asserted the request, the request held the core in
reset, and the software that was supposed to clear the status could
never run again. The subsystem was dead until a power cycle.

That is worse than having no reaction at all, and it directly
contradicted the safety manual, which says the warm reset "restarts the
core but leaves the peripherals and their status registers standing, so
the software can determine the cause after the restart". It never
restarted.

The request is now a pulse per fault, with a `rst_acted_q` register
remembering which bits have already had their reset and clearing when
software clears the status, so a later recurrence requests a new one.

Confirmed by reverting the fix in a scratch copy: the level form times
out, the pulse form passes.

### V7-F2 — the warm reset was released in a race (design bug, FIXED)

**Found by the two simulators disagreeing**, which is the whole reason
the plan runs both. The same RTL and the same image: under Icarus the
core restarted and the test passed; under Verilator the core never came
back.

The cause:

```
assign core_rst_n = rst_n_sync && (warm_cnt_q == '0);
```

That releases the reset in the *same delta* as the clock edge that
clears the counter, so every flop using `core_rst_n` as an asynchronous
reset races between the old and the new value. Two simulators are
entitled to resolve it differently, and they did.

The warm reset now goes through `cdriscv_rst_sync`, which is what that
primitive exists for: asynchronous assertion, synchronous release,
clear of the clock edge. Both simulators now pass, within one cycle of
each other.

Worth stating plainly: a functional test alone would not have found
this. It took running the same test on two simulators and noticing they
disagreed.

### Two process notes

* One debugging session was spent chasing a **stale `.vvp`**: after
  patching the RTL I re-ran the simulation binary directly instead of
  through `make`, so the fix was not in the design under test and the
  probe binaries disagreed with the trace. Run through `make`.
* `make coverage | head` silently truncated the run — `head` exits,
  `make` takes SIGPIPE and dies partway, and the report that was left
  behind was the *previous* one. The numbers looked plausible and were
  stale. Redirect to a file and read the file.


## Phase V7 continued — peripheral and interrupt test (2026-08-20)

`make periph` runs `verif/core/periph_test.S`, eight checks over
everything the coverage baseline said had never been touched: the
machine timer, all three interrupt causes, WFI, the interrupt
controller, the watchdog serviced and unserviced, and a memory BIST
sweep of the D-TCM.

**All eight pass.** The core had never taken an interrupt before this
test existed, and the interrupt path, WFI wake-up and trap return all
work first time. The BIST sweeps 4096 words, which is why the run takes
about 100 000 cycles against a few hundred for the other tests.

Coverage moved accordingly:

| module | before | after |
|--------|--------|-------|
| **total RTL** | **62.5 %** | **75.1 %** |
| `cdriscv_mbist` | 30 % | 84 % |
| `cdriscv_wdog` | 41 % | 78 % |
| `cdriscv_irq_ctrl` | 43 % | 70 % |
| `cdriscv_timer` | 43 % | 65 % |
| `cdriscv_csr` | 57 % | 79 % |
| `cdriscv_core` | 57 % | 67 % |
| `cdriscv_ecc_secded` | — | **100 %** |

One test bug worth recording, because it is the kind that hides a real
one. Check 1 failed the first time: the timer interrupt never arrived.
The cause was in the test, not the design — `mtimecmp` is 64 bits and I
had written `-1` to the high word "to keep it out of the way", which
puts the deadline centuries away. A reader of that first version would
have concluded the timer was broken.

Remaining gaps, in order:

| module | coverage | what is missing |
|--------|----------|-----------------|
| `cdriscv_clkmon` | 34 % | still the APB configuration path: the V4 bench forces those registers instead of writing them |
| `cdriscv_ams_if` | 68 % | the limit registers, the analog flags, the conversion time-out |
| `cdriscv_core` | 67 % | the remaining trap causes, `fence.i`, misaligned access |
| `cdriscv_safety_ctrl` | 64 % | the reaction paths: reset request, error pin in both modes, the lock |
| `cdriscv_decoder` | 69 % | illegal encodings, which no valid program contains |

## Phase V7 — coverage baseline (2026-08-20)

`make coverage` runs the stimulus that exists — the directed ISA
program, eight random programs, the smoke test and the safety test —
under Verilator with `--coverage`, merges the databases and reports.

**Baseline: 62.5 % RTL line coverage** (783 of 1252 lines), test
benches excluded because they are not the design.

The value here is not the number, it is the ranking. It names what has
never been exercised at all:

| module | coverage | why |
|--------|----------|-----|
| `cdriscv_mbist` | 30 % | **no test ever starts the memory BIST** |
| `cdriscv_clkmon` | 34 % | the bench half forces its registers, so the APB register path is untouched |
| `cdriscv_wdog` | 41 % | **the watchdog has never been exercised** |
| `cdriscv_timer` | 43 % | **the timer has never been used** |
| `cdriscv_irq_ctrl` | 43 % | **no interrupt has ever been taken** |
| `cdriscv_core` | 57 % | the interrupt, WFI and most trap paths |
| `cdriscv_csr` | 57 % | most CSRs are never accessed |
| `cdriscv_ams_if` | 68 % | only the one sequencer path the smoke test uses |

Read that as a to-do list rather than a score. Four peripherals and the
core's whole interrupt path have no test at all, and the safety manual
lists three of them as safety mechanisms (SM4 the BIST, SM5 the
watchdog, SM6 the clock monitor). The bench-half tests of section V4
reach the clock monitor's *detection* logic by forcing its
configuration, which is why the block still reports 34 %: the path
software would actually use to configure it has never run.

The well covered end is also informative. `cdriscv_bus` at 87 %,
`cdriscv_apb_bridge` at 90 % and `cdriscv_lockstep` at 84 % are where
the random program regression does its work — every program is
thousands of bus transactions.

Next: a peripheral and interrupt test, which should lift the timer, the
interrupt controller, the watchdog and the core's trap paths together,
and a BIST run.


## Phase V6 continued — formal, SEC-DED decoder (2026-08-20)

`make formal-ecc` proves the three SEC-DED properties **over every one
of the 2^32 data values and every error position**, in 3 seconds. Both
modules are combinational, so this is not a bounded result: it
quantifies over the whole input space.

| property | what it says |
|----------|--------------|
| clean | the word comes back unchanged, no flag |
| one error | corrected, whatever the data and wherever the bit |
| two errors | flagged uncorrectable, and `err_single` never set |

The last one is the one the safety argument needs: a decoder that
flagged a double error *and* also "corrected" the data would pass any
test that only inspects flags, so the correction output is checked too.

This upgrades the evidence for the ECC from what the block bench gives
— every error position, but 268 sampled data patterns — to complete
coverage of the data space.

Mutation tested with two seeded bugs, both caught: one bit changed in
an encoder parity mask (`p_clean_single` fails), and `err_double_o`
tied low (`p_double_flag` fails).

### The result that was not a result

The first version of this run **passed in 0.3 seconds and proved
nothing**. The properties sit in a clocked block, and a BMC depth of 1
never reaches the clock edge, so the solver had nothing to check. It
looked like a spectacular proof.

What exposed it was the mutation test: a deliberately broken encoder
mask *also* passed. A formal run that passes suspiciously fast deserves
exactly that treatment, and the same applies to a simulation that runs
suspiciously few cycles.

Depth 2 is the fix, and it turned a 0.3 second non-result into a real
one — but only after changing the engine. With yices (SMT) depth 2 did
not finish in 240 seconds; with abc (SAT) it takes 3. The code is XOR
heavy, which SAT handles far better than SMT. The fetch stage
properties are the opposite case: they are about control, and yices
converges there in ten seconds where abc gave nothing extra. Both
choices are written into the `.sby` files with the reason.

## Phase V6 — formal, fetch stage (2026-08-20)

`make formal` bounded-model-checks `cdriscv_if_stage`, the block the
plan calls the riskiest in the design: three concurrent state updates —
request accepted, response accepted, redirect — share one always block,
and the interesting cases are the ones where they coincide. Simulation
samples that space; BMC covers it.

**Passes to depth 20 in 11 seconds**, five properties:

| property | what it says |
|----------|--------------|
| `p_pc_stream` | every instruction delivered is the next one of the stream that began at the last redirect |
| `p_single_outstanding` | never two bus transactions in flight |
| `p_addr_aligned` | fetch addresses are word aligned |
| `p_redirect_flushes` | nothing is presented in the cycle after a redirect |
| `p_fetch_en` | no request while fetching is disabled |

`p_pc_stream` is the one that carries the weight. It compares the
delivered PC against a reference model that restarts at every redirect
target and advances by four per consumed instruction — so a stale
instruction surviving a redirect, a discarded response surfacing, or a
PC that skips or repeats all violate it.

**Mutation tested.** Removing the discard of a fetch that was granted
in the same cycle as a redirect — precisely the interleaving that is
hard to hit in simulation — produces a counterexample at step 6. The
properties have teeth on the case they were written for.

### Getting it to converge, and what that cost

The first attempt did not finish: at depth 40 the solver was spending
over a minute per step and was still at step 21 after twelve minutes.
Two abstractions fixed it, and both narrow what is proven, so both are
written into the wrapper:

* `instr_rdata_i` is tied to a constant. No property reads the
  instruction word — they are all about which address is fetched and
  which PC is delivered — so 32 free bits per step bought nothing.
* redirect targets are confined to the low 1 KiB. The PC datapath is
  uniform in width, so any *control* bug still has a counterexample in
  that range; what this would miss is a bug that only appears at a
  particular high address, a carry chain error for instance. That class
  is left to simulation.

With those, depth 20 runs in 11 seconds — about 70 times faster.

**Limit, stated rather than glossed:** depth 60 still did not complete
within ten minutes, and an unbounded k-induction proof has not been
obtained. Depth 20 is enough to cover the request/response/redirect
interleavings of this block, which take three to five cycles, but it is
a bounded result and not a proof. Getting further needs a stronger
abstraction — narrowing the PC width in the DUT for formal builds is
the usual move — and is left as future work.

The other blocks in the plan's formal list (LSU handshake, bus response
routing, decoder, ECC decoder, safety controller stickiness) have not
been done yet.


## Phase V4 — safety mechanisms (2026-08-20, in progress)

`make safety` runs `verif/safety/safety_test.S` on the subsystem: nine
checks over the mechanisms an application can reach through the
register map. Each check that fails writes its own number to the exit
register, so a failure names itself. All nine pass, and the status
register takes exactly the values it should along the way:

| status | what set it |
|--------|-------------|
| `0x00000001` | lockstep comparator self test |
| `0x00000008` | D-TCM single bit error, corrected |
| `0x00000110` | D-TCM uncorrectable error, *plus* the bus error it causes |
| `0x00000800` | software fault trigger |

### Bench half — **pass**, 7 checks

`make safety-bench` covers what software cannot reach: faults forced
inside the checker core, and a system clock that misbehaves. Every
mechanism gets a trigger case *and* a quiet case, because a mechanism
wired to a constant passes a trigger-only test.

| check | result |
|-------|--------|
| quiet: no fault during 2000 cycles of normal execution | status stays `0` |
| lockstep: fault forced on a compared signal (checker fetch PC) | detected after **2 cycles** |
| lockstep: fault forced on the register write data | detected after **2 cycles**, indirectly |
| clock monitor: quiet at the nominal ratio | no fault, measured count 25 of a 22..30 window |
| clock monitor: system clock stopped | detected in the reference domain |
| clock monitor: system clock 1.5x too slow | detected, count 30 |
| clock monitor: system clock 2.5x too fast | detected, count 9 |

The stopped-clock case is the one that justifies the whole
architecture of that block: a monitor clocked by the clock it watches
cannot report that clock's failure, and this test is what demonstrates
the reference-domain design does.

### V4-F3 — register write data is not directly compared (CLOSED in V32: real, not worth fixing)

The lockstep compare vector carries the bus signals, the fault flags,
sleep and the retire information — but not the register file write
port. My first version of the test above asserted that a corrupted
register write would therefore go **undetected**, and that assertion
failed: it *was* caught, in 2 cycles.

The reason is that the corruption propagates. A wrong register value
reaches an address, a branch or a store quickly in ordinary code, and
all of those are compared. So this is not a hole. What it is, is a
detection latency that **depends on the program** rather than on the
hardware: a value that is written and never read is never detected
(harmless, it is dead), and a value read much later is detected much
later.

That matters for one specific claim. The fault tolerant time interval
argument in the safety manual wants a *bounded* detection latency, and
"2 cycles in this program" is not a bound. Two options, for whoever
owns that argument:

* add `rd_addr` and `rf_wdata` to the compare vector — 37 more bits,
  and detection of any register file fault becomes unconditional and
  single cycle, or
* keep the vector as it is and state the latency as program dependent,
  with a bound derived from the application's longest
  write-to-first-use distance.

Recorded rather than decided: it is a change to a safety mechanism and
belongs with the FMEDA, not with a verification pass.

Writing the software half found two things.

### V4-F1 — the ECC self test could never be triggered (design bug, FIXED)

**Severity: medium, and squarely in the safety story.** SM10 in the
safety manual is the fault injection that bounds the latent fault
metric for the memory protection. It could not be used at all.

`SELFTEST[1]`/`[2]` in the safety controller produced a **one cycle**
pulse, and `cdriscv_tcm` only applied the corruption to a write
happening in *that same cycle*. But the pulse comes from an APB write,
and the store it is meant to corrupt is necessarily several cycles
later — the APB transfer alone takes four. The two could never
coincide, so no software sequence could ever corrupt a code word.

The register map already documented the intended behaviour, "corrupt
one bit of the next TCM write", so this is the RTL disagreeing with its
own specification rather than a change of design. The TCM now *arms* on
the pulse and applies the mask to its next functional write, clearing
the arming as it does. Check 4/5 of the safety test is exactly this
sequence and would have failed before the fix.

While fixing it: the enable went to *both* TCMs, so arming would leave
the I-TCM primed to corrupt whatever wrote to it next, possibly much
later. `SELFTEST[3]` now selects the target, and the two TCMs get
separate enables.

### V4-F2 — prefetch past the end of the image meets uninitialised memory

**Not a bug, but an assumption of use that was not written down.**

The safety test first showed `X` in status bits 0 and 1 partway
through. Not uninitialised *data*: a fully initialised D-TCM changed
nothing. It was the **instruction** prefetcher, which runs one fetch
past the last instruction of the program, into an I-TCM word that was
never written. In simulation that is X, which propagates into both
cores and makes the lockstep comparison and the I-TCM ECC flag X.

In silicon it is worse than X, because it is *defined*: an unwritten
memory holds some arbitrary 39-bit pattern, and the SEC-DED check on it
will very likely report an uncorrectable error — a spurious safety
fault, with whatever reaction is configured, before the program has
done anything wrong.

Two consequences, both recorded:

* the bench now pads every image to the full memory depth, which is why
  `make safety` is clean,
* **the whole TCM must be written before the core is released.** The
  start-up memory BIST already does this, and leaves every word at the
  all-zero code word, which is a valid one — syndrome zero, no error.
  So AoU-5 in the safety manual is stronger than it looked: running the
  BIST is not only a test, it is also what makes the memory safe to
  fetch from. That is now said explicitly.


## Phase V3 continued — memory accesses in the comparison (2026-08-20)

The co-simulation now compares **memory accesses as well as register
writes**: the address of every load, and the address and data of every
store, truncated to the access width the way Spike reports it.

**Where the RTL side is sampled matters, and it is the point of this
step.** The obvious place is the core's decoded address and its `rs2`
value. That would be wrong — or rather, far too weak: it checks the
address adder and the source register, but the byte enable generation
and the write data lane shifting sit *downstream* of it, in the LSU,
and that is exactly where alignment bugs live. The bench therefore
reconstructs the access from the core's **bus outputs**: the byte
address from `data_addr_o` and the low set bit of `data_be_o`, the
store data by shifting `data_wdata_o` down by that offset and
truncating to `$countones(data_be_o)` bytes.

Mutation tested with a bug that touches no register and no control
flow: a byte store to offset 1 writing the wrong lane
(`{wdata[23:0],8'b0}` becomes `{wdata[15:0],16'b0}` in
`cdriscv_lsu.sv`). The comparison fails on exactly that store:

```
idx   spike                                   rtl
101   pc=80000194 00628223  m[800002b4]=00000055   ... matches
102   <-- the offset 1 store, diverges
```

Sampled at the decode level, that mutation would have passed.

Regression with the strengthened comparison: **1000 of 1000 programs
match, 16 885 968 instructions**, PCs, register writes and memory
accesses. Together with the earlier 2000-program run that compared PCs
and register writes over 33 760 012 instructions, that is the evidence
behind the README status table.

What is still outside the comparison: CSR state that no instruction
reads back, and anything the program does not execute.


## Phase V3 — co-simulation throughput (2026-08-20)

The previous entry ended with the arithmetic that the harness could not
reach objective O2: 10^9 instructions at 350 compared instructions per
second is 33 days. Two changes closed most of that gap.

### Verilator instead of Icarus — 90x on the simulator

The same bench, verilated with `--binary --timing`, runs a 200 000
cycle program in **0.19 s against Icarus' 17.8 s**. Nothing in the
bench had to change: the hierarchical reference that pulls the register
write out of the core, and the hierarchical `$readmemh` that loads the
TCM, both work under Verilator as they do under Icarus.

Verilator is now the default runner. Icarus stays wired up as
`make cosim-iverilog`, and both produce identical results on the
directed program. That second opinion is worth keeping: Icarus has
already earned its place once, by rejecting four SystemVerilog
constructs Verilator accepted (findings V0-F4 to V0-F7).

### Bounded outer loop — more execution per program

With the simulator no longer the bottleneck, the per-program overhead
took over: assembling, encoding the image, and starting Spike and
Python cost about 0.3 s regardless of how long the program runs.

The generator now wraps the random body in a bounded outer loop
(`--loops`). The image stays small — it has to fit the I-TCM — while
the executed instruction count multiplies. This is not repeated work:
the registers carry over, so every iteration starts from a different
state, and the loop hammers the fetch redirect path, which is where
finding V2-P1 says the cycles are going.

### Regression after the change — 2000 programs, 33.8 million instructions

**2000 of 2000 constrained random programs match Spike, 33 760 012
retired instructions compared**, PCs and register writes, in about
fifteen minutes. That is 106 times the previous run's 318 486, from the
same wall clock budget.

Objective O2 asks for 10^9, so this is **3.4 % of the way there** and
the objective remains open. What has changed is that the remainder is
now a matter of leaving a machine running overnight rather than of
rebuilding the harness.

### Where that leaves O2

| | before | after |
|---|---|---|
| simulator | Icarus | Verilator |
| instructions per program | ~650 | ~12 000 |
| end-to-end throughput | ~350 instr/s | **~43 000 instr/s** |
| 10^9 instructions would take | 33 days | **6.5 hours** single threaded |

The regression parallelises across seeds trivially, so O2 is now a
question of scheduling a machine for an evening rather than a
redesign. It is still **not met**: the number to report is whatever the
last completed regression actually compared, and nothing more.


## Phase V0 revisited — synthesis and a third front-end (2026-08-20)

### Objective O5 — **pass**

`make synth` runs a generic yosys synthesis and checks the two things
O5 asks for: **no inferred latches and no combinational loops**. Both
clean. With the TCMs cut to 64 words (the behavioural arrays would
otherwise map to a few hundred thousand flip-flops and drown
everything), the subsystem maps to **52 614 cells**, of which about
5 000 flip-flops are logic and 5 000 are the cut-down memories.

Two flow findings on the way there:

* **yosys' built-in Verilog frontend cannot read this RTL.** It rejects
  a package import in the module header (`module x import pkg::*; (...)`)
  with a syntax error. The target now uses the **yosys-slang** plugin,
  which handles it. Worth knowing before anyone points LibreLane at
  this design: `flow/config.json` will need the same treatment.
* A file list with one path per line, passed into `yosys -p`, is parsed
  as *one yosys command per line*. The symptom is a confusing "no
  top-level modules found" followed by "No such command: rtl/...". The
  list has to be flattened to spaces.

### A third front-end agrees

Standalone `slang` elaborates the whole design with **zero errors and
zero warnings**. That is three independent front-ends now — Verilator,
Icarus and slang — and slang is the strictest of them. It is a cheap
check and worth keeping in CI.


## Phase V1/V2 continued — ECC bench and random programs (2026-08-20)

### SEC-DED encoder/decoder (`verif/block/ecc`) — **pass**

Exhaustive over error positions rather than sampled. For each data
pattern the bench checks the clean code word, **all 39 single bit error
positions**, and **all 741 double bit error pairs**:

| Case | Required behaviour |
|------|--------------------|
| clean | no flag, data unchanged |
| single bit | corrected to the original data, `err_single` only |
| double bit | `err_double` only, never reported as correctable |

Current run: **209 308 checks over 268 data patterns** (all zero, all
one, both alternating patterns, walking one and walking zero across all
32 bit positions, and 200 random), zero failures. `make block-ecc`.

The double bit requirement is the one that matters for the safety
argument: a decoder that flagged a double error *and* also "corrected"
the data would pass any test that only inspects flags. Because the
check demands `err_double` set and `err_single` clear, a silent
miscorrection cannot pass.

Mutation tested:

| Mutation | Result |
|----------|--------|
| `err_double_o` tied low | detected, 53 352 / 56 232 |
| `err_single_o` set for any non-zero syndrome | detected, 53 352 / 56 232 |
| one data bit's correction term tied low | detected, 72 / 56 232 |
| one syndrome bit inverted | detected, 56 232 / 56 232 |
| no-op control mutation | not detected, as intended |

The third row is worth reading: a single broken correction term shows up
in only 72 of 56 232 checks. Sampling error positions instead of
enumerating them could easily have missed it.

### Multiplier / divider (`verif/block/multdiv`) — **pass**

4800 vectors against an independent model: every pairing of 15 corner
values for all eight operations, 300 random pairs each, and 75 more with
a small divisor where the quotient is large. Both special cases the
specification calls out are in the corner set — division by zero for all
four division operations, and the signed overflow `INT_MIN / -1`.

Two structural claims are checked as well as the results:

* **Constant latency: 33 cycles for every operation and every operand,
  including division by zero.** The safety manual quotes data
  independent latency as WCET evidence, so the bench asserts it rather
  than observing it: the first vector sets the expected latency and
  every later vector must match.
* **`acc_q[32]` is never set** (finding V0-A1). Lint reported the bit as
  unused and the waiver argued it from the restoring-division invariant;
  this turns that argument into a check that runs on every vector.

### Random program co-simulation — **pass**

`verif/core/gen_random_prog.py` generates constrained random RV32IM
programs and `make cosim-random` runs each through the Spike
comparison. Constrained rather than uniformly random, so that every
difference found is a real one:

* memory accesses are forced into a scratch area at aligned offsets, so
  nothing escapes the TCM and no access fault appears unless a directed
  test asks for one,
* branches only jump forward by a few instructions, so control flow is
  a DAG and no program can spin,
* no computed `jalr`, no counter CSRs (`mcycle` and `minstret`
  legitimately differ between model and RTL),
* the register pool is seeded with the boundary values (0, ±1,
  `INT_MIN`, `INT_MAX`, the alternating patterns) so that random
  arithmetic lands on the corners often,
* `x0` is used as a destination sometimes, on purpose.

First regression: **25 of 25 programs match, 11 261 instructions
compared**, PCs and register writes. Failing seeds are kept and the
runner prints the command to reproduce one.

### Regression at scale — 500 programs, 318 486 instructions

With the stop-PC fix below, the first real regression: **500 of 500
constrained random programs match Spike, 318 486 retired instructions
compared**, PCs and register writes, in about 15 minutes.

**This is not objective O2.** O2 asks for 10^9 instructions with zero
mismatches, and 318 486 is three and a half orders of magnitude short of
it. The interesting part is the arithmetic: at roughly **350 compared
instructions per second**, 10^9 would take about **33 days** of wall
clock. The harness as it stands cannot get there.

The fix is not more machines, it is the simulator. The co-simulation
bench runs under Icarus, which interprets; Verilator compiles, and is
typically one to two orders of magnitude faster on a design this size.
Porting the co-simulation bench to Verilator (a C++ harness rather than
`$display` parsing, which also removes the text I/O bottleneck) should
bring 10^9 into the range of a day or two, and it parallelises across
seeds trivially. That is now the next piece of infrastructure, ahead of
more directed benches.

### V2-T1 — the bench was simulating the spin loop (bench, FIXED)

The first large regression crawled at about **75 seconds per program**.
The cause was in the bench, not the design: each program ends in a tight
loop, and the bench went on simulating and printing that loop until it
hit the retire limit — tens of thousands of retires per program, all of
them worthless.

The runner now reads the `done` and `fail` addresses from the ELF and
passes them to the bench as `+STOPPC`, so the run ends when the program
does. **0.82 seconds per program**, about 90 times faster, which is what
makes a regression of hundreds of programs practical.


## Phase V2 — golden model co-simulation (2026-08-20, in progress)

### Register write co-simulation — **pass**

The comparison now covers the `(pc, instruction, rd, write data)`
sequence, not just control flow. Register writes come from Spike's
`--log-commits` and, on the RTL side, from the core's internal signals
through a hierarchical reference in the bench. Nothing was added to the
RTL: the synthesised design and the lockstep compare vector are
untouched, which is the whole point of doing it as a bench-side bind.

Current run: **208 retired instructions match, including every register
write**, and both sides reach the program's `done` label rather than
its `fail` label.

Mutation tested with a bug that changes no control flow at all —
`mulh` returning the product shifted by one bit position:

```
idx    spike                            rtl
66     pc=80000108 02b50633 x12=80000000  pc=80000108 02b50633 x12=80000000
67     pc=8000010c 02b516b3 x13=00000000  pc=8000010c 02b516b3 x13=00000001  <<<
```

The PC stream is identical there; only the value differs. That is the
coverage the register write comparison adds over the control flow
comparison, and it is why objective O2 is written the way it is.

### V2-F1 — Spike's default privilege set does not match the DUT (bench, FIXED)

The first value comparison diverged on `csrr t4, misa`: Spike returned
`0x40141100`, the RTL `0x40001100`. The difference is the S and U bits.
Spike defaults to `--priv=msu`, so it advertises supervisor and user
mode; cdriscv-32s is machine mode only and correctly advertises neither.

Not an RTL bug — a model configuration mismatch, and a good
advertisement for comparing values rather than only control flow, since
nothing in the program branched on `misa`. The runner now passes
`--priv=m`.

### Instruction stream co-simulation — **pass**

`make cosim` runs one program on Spike and on the RTL and compares the
retired instruction streams. Current run: **213 retired instructions,
identical**, covering the RV32IM exercise in `verif/core/cosim_isa.S`:
every register-immediate and register-register ALU form, the shift
family, all eight M-extension operations including `INT_MIN / -1` and
all four divide-by-zero cases, every load and store size at every
alignment, all six branch forms in both directions, `jal`/`jalr`/`jal
x0`, a 20-iteration loop, and the Zicsr access forms.

Two structural notes on the setup:

* The I-TCM is relocated to `0x8000_0000` for this bench, because Spike
  keeps its debug module at `[0, 0x1000)` and refuses to place memory
  under it. That also exercises the `ItcmBase` parameterisation, and
  putting code, data and stack in one region means the data master
  competes with the fetcher for the I-TCM on every load and store —
  the bus arbitration case worth running.
* The program ends with the HTIF `tohost` store, so Spike terminates
  the run itself. In the RTL that is an ordinary store into the TCM.

**What this does and does not prove.** Control flow and register writes
are compared. Still outside the comparison: memory write data (a wrong
store that is never loaded back stays invisible), CSR state that no
instruction reads back, and anything the program does not execute — the
program is directed, not random. Random program generation against the
same harness is the next step, and is what turns this into objective O2
proper.

### V2-P1 — CPI is far worse than predicted (performance, open)

**Not a correctness bug.** The co-simulation program retires **213
instructions in 1674 cycles, CPI 7.9**. Of that, roughly 560 cycles are
the seventeen 33-cycle multiply and divide instructions, which leaves
about CPI 5.7 for everything else — still far above the 1.5–2.5 range
predicted in the benchmark plan (since removed from the repository).

The structural cause is the single entry instruction buffer. The fetch
stage only issues the next request in the cycle the buffer is being
emptied, and the TCM answers one cycle later, so the sequence for two
back-to-back ALU instructions is:

```
T    instruction A executes and retires; fetch request for B issued
T+1  TCM returns B; the buffer fills at the end of the cycle
T+2  instruction B executes and retires
```

— a guaranteed one cycle bubble on every instruction, so **CPI 2 is the
floor** for straight-line code, before loads, taken branches and
multiply/divide are added.

This is the first entry in the improvement backlog that
the benchmark plan (since removed) asked for. The fix is a deeper prefetch
(issue the next request while the current instruction is still
executing, and buffer two words rather than one), which is contained
entirely in `cdriscv_if_stage.sv`. It should be measured, not assumed:
the cycle accounting instrumentation in the benchmark plan comes first.

### Tooling notes

**Spike's debug mode is unusable for tracing.**

Driving Spike with `-d` and `r <count>` took **60 seconds to retire 215
instructions**; free-running with `-l` and the HTIF exit does the same
work in **25 ms**, a factor of about 2000. Anything that traces Spike
should use the HTIF protocol.

**Spike notices the HTIF exit store only at its next poll**, so its
trace carries a tail of several thousand spin-loop instructions after
the program has finished. Both traces are therefore cut at the
program's `done` or `fail` label, which also lets the runner report
which of the two the program reached — the program's own verdict, on
top of the stream comparison.


## Phase V1 — block level benches (2026-08-20, in progress)

### ALU (`verif/block/alu`) — **pass**

`gen_vectors.py` holds a reference model of the ALU written from the
RISC-V semantics, independently of the RTL, and emits vectors as
`{op, a, b, expected}`. `tb_alu.sv` replays them against the block.

Current run: **453 840 vectors, 0 mismatches**, covering all 15
operators against every pairing of 16 corner values (0, ±1, the signed
and unsigned boundaries, shift amounts 31/32/33, alternating patterns),
20 000 random operand pairs per operator, and 10 000 more with a corner
on one side.

The bench was mutation tested, mutating a scratch copy so the working
tree is never touched:

| Mutation | Result |
|----------|--------|
| comparator polarity inverted (the V0-F2 bug) | detected, 1024 / 3840 |
| `sll` result taken without operand reversal | detected, 187 / 3840 |
| `eq` polarity inverted | detected, 256 / 3840 |
| subtract without the +1 (one's complement) | detected, 320 / 3840 |
| no-op control mutation (`x ^ 32'h0`) | not detected, as intended |

The control mutation matters: without it, a bench that always failed
would look equally convincing.

Run with `make block-alu`; the recipe checks the verdict, since `vvp`
exits zero either way.

### Tooling

Spike (`riscv-isa-sim` 1.1.1-dev) built and installed at
`/headless/verif-tools/spike`, which unblocks objectives O1 and O2.


## Phase V0 — lint, elaborate, smoke (2026-08-20)

Status: **complete**. `make lint`, `make lint-tb`, `make sw` and
`make sim` all pass. The subsystem boots from the I-TCM, executes the
smoke program through the integer, comparison, memory and peripheral
sections, and reports PASS in 395 cycles with the dual core lockstep
configuration active and no fault raised.

### V0-F2 — ALU comparator polarity inverted (design bug, FIXED)

**Severity: high.** Every signed and unsigned comparison in the core
returned the opposite answer: `slt`, `sltu`, `slti`, `sltiu`, `blt`,
`bge`, `bltu`, `bgeu`. Effectively no conditional branch other than
`beq`/`bne` worked.

`cdriscv_alu.sv` extends both operands to 33 bits and subtracts, then
took `cmp_lt = ~adder_result[32]`, with a comment describing bit 32 as
the carry-out. It is not: `adder_result` is a 33-bit vector holding a
33-bit sum, so the carry out of bit 32 is not kept and bit 32 is the
*sign* of the difference. Since the extension makes overflow
impossible, the sign is set exactly when `a < b`, so the correct
expression is `cmp_lt = adder_result[32]` — the inversion was wrong.

Found by the very first simulation: the smoke program's ADC poll loop
uses `blt` to bound its retries, fell through on the first iteration
and took the failure path. Fixed, and the comment corrected to say what
bit 32 actually is.

Two things this says about the bench rather than the design:

* The original smoke program used only `beq`/`bne`, so it exercised
  `cmp_eq` and never `cmp_lt`. It has been extended to check every
  comparison form in both directions, and the extension was validated
  by re-injecting the bug and confirming the program fails.
* An architectural test suite would have caught this on the first run.
  It is the argument for pulling phase V2 forward.

### V0-F1 — MBIST cannot read back the check bits of a failing word (FIXED in V22)

**Severity: low.** `cdriscv_mbist.sv` latches the full 39-bit failing
code word in `fail_data_q` but `FAILDAT` only returns bits [31:0], so
the seven check bits — the part of the array that only the raw test
port can reach — cannot be inspected after a failure. Diagnosis of a
check-bit-only failure is therefore blind.

Proposed fix: add `FAILDAT_HI` at `+0x10` returning
`{25'b0, fail_data_q[38:32]}`, and update `register_map.md`. Not done
yet because it changes the register map; queued for phase V4 when the
BIST bench is written.

> **Fixed in V22**, and the proposed fix above was wrong: `+0x10` lay
> outside the sixteen bytes each controller decoded, so the register
> would have answered with a bus error. The claim had to widen to
> thirty-two bytes first. Closing it also withdrew coverage waiver W2c.

### V0-F3 — `-march=rv32im` no longer implies Zicsr (flow, FIXED)

Modern binutils split Zicsr and Zifencei out of the base ISA strings,
so the smoke program failed to assemble on every `csrr`/`csrw`. The
Makefile now builds with `rv32im_zicsr_zifencei`. Worth remembering for
the benchmark work: the `-march` string used for a comparison must name
these explicitly.

### V0-F4 to V0-F7 — SystemVerilog portability (FIXED)

Verilator accepted all of these; Icarus rejected them. Since the plan
uses both simulators deliberately (one as a second opinion on the
other), the RTL now avoids the constructs rather than the tool:

| # | Construct | Where | Fix |
|---|-----------|-------|-----|
| V0-F4 | `case ... inside` with range items | `cdriscv_ams_if.sv` | if/else chain over explicit range comparisons |
| V0-F5 | `string` parameter passed down a hierarchy | `cdriscv_subsys.sv` → `cdriscv_tcm.sv` | dropped `ItcmInit`/`DtcmInit`; the bench loads images with hierarchical `$readmemh`, which it already did |
| V0-F6 | ternary whose arms are enum literals | `cdriscv_decoder.sv`, `cdriscv_lsu.sv`, `cdriscv_ams_if.sv` | if/else |
| V0-F7 | one array driven both continuously and procedurally | `cdriscv_regfile.sv` (`rf_q[0]` tied off by `assign`, `rf_q[31:1]` written in `always_ff`) | storage is now `[31:1]`, with a separate combinational read view that adds the constant `x0` entry |

V0-F7 is the one worth noting beyond portability: the original shape
was chosen to avoid an out-of-range index on the read ports, and the
replacement keeps that property while being legal for both tools.

### V0-A1 to V0-A5 — unused bits, analysed and waived

Lint reported five bits inside the core that are never read. Each was
checked against the structure that produces it rather than waived on
sight, because an unused bit is also what a real bug looks like:

| # | Signal | Why it is provably unused |
|---|--------|---------------------------|
| V0-A1 | `cdriscv_multdiv.acc_q[32]` | the multiply path writes bit 32 as zero; the restoring-division invariant keeps the partial remainder below the divisor, hence below 2^32, at every iteration boundary. The 33rd bit exists only for the shifted intermediate. To be turned into an assertion in the V1 bench. |
| V0-A2 | `cdriscv_alu.shift_ext[32]` | the sign extension bit that lets one arithmetic right shifter serve `srl`, `sra` and (by operand reversal) `sll`; the result only takes [31:0] |
| V0-A3 | `cdriscv_regfile.we_dec[0]` | write enable of `x0`, which is not implemented |
| V0-A4 | `cdriscv_core.mtvec[1]` | forced to zero on write; the mode field is bit 0 |
| V0-A5 | `cdriscv_csr.trap_pc_i[1:0]` | `mepc` is word aligned with IALIGN=32. This is the exact bit that changes if Zca is added |

All five are waived in `verif/lint/waivers.vlt` with their
justification. `make lint` now runs without `-Wno-fatal`, so any new
warning fails the build.
