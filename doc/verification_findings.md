# cdriscv-32s verification findings

Running log of everything verification has turned up, newest phase
first. Each finding records what was wrong, how it was found, and what
was done about it. See `verification_plan.md` for the plan these come
from.

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
