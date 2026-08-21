# cdriscv-32s verification findings

Running log of everything verification has turned up, newest phase
first. Each finding records what was wrong, how it was found, and what
was done about it. See `verification_plan.md` for the plan these come
from.

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

### V4-F3 — register write data is not directly compared (observation)

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
predicted in `benchmark_plan.md` section 7.

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
`benchmark_plan.md` section 8 asks for. The fix is a deeper prefetch
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

### V0-F1 — MBIST cannot read back the check bits of a failing word (open)

**Severity: low.** `cdriscv_mbist.sv` latches the full 39-bit failing
code word in `fail_data_q` but `FAILDAT` only returns bits [31:0], so
the seven check bits — the part of the array that only the raw test
port can reach — cannot be inspected after a failure. Diagnosis of a
check-bit-only failure is therefore blind.

Proposed fix: add `FAILDAT_HI` at `+0x10` returning
`{25'b0, fail_data_q[38:32]}`, and update `register_map.md`. Not done
yet because it changes the register map; queued for phase V4 when the
BIST bench is written.

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
