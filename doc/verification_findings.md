# cdriscv-32s verification findings

Running log of everything verification has turned up, newest phase
first. Each finding records what was wrong, how it was found, and what
was done about it. See `verification_plan.md` for the plan these come
from.

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
