# Coverage waivers

Objective O6 asks for 100 % line coverage **with a reviewed waiver for
each exclusion**. This file is that review. A waiver here is a claim
that a line cannot be reached by simulation *and* that something else
covers it — not a note that nobody got round to it.

Anything not listed here is a gap to be closed by a test, and the
current list of those is in `verification_findings.md`.

## W2 — defensive `default` arms over fully enumerated selectors (2026-08-21)

Fifteen uncovered lines remain and every one of them is a `default:`
arm whose selector is already fully enumerated by the arms above it.
They fall into three groups, and the reason each is unreachable is
different enough to be worth stating separately.

Line coverage with this waiver applied is 100 %; without it, 96.0 %.

### A correction: this waiver was wrong when first written

It originally claimed seventeen lines and said "every one of them" was
an unreachable default. Its own tables only accounted for fourteen.
The three unlisted lines were the decoder's illegal-instruction
defaults, and checking them properly gave three different answers:

* `cdriscv_decoder.sv:252` really is unreachable — the OP-IMM `funct3`
  case lists all eight values — and is now waived under W2b below.
* `cdriscv_decoder.sv:322` is **reachable**: a SYSTEM instruction with
  `funct3 = 100` leaves `csr_op` undecodable.
* `cdriscv_decoder.sv:327` is **reachable**: the top level opcode
  default, which any unknown opcode falls through to.

Two lines had been waived as unreachable without anyone checking, in a
document whose entire purpose is to be that check. Both are now covered
by `fence_csr_test.S`, which executes `0x00004073` and `0x0000000b` and
requires each to trap as an illegal instruction.

The lesson is the obvious one and it is recorded here rather than
quietly fixed: a waiver list that does not reconcile against the actual
uncovered count is not a review, and the arithmetic is the cheapest
part of it.

### W2a — state machine recovery arms

| file | line |
|------|------|
| `cdriscv_ams_if.sv` | 159 |
| `cdriscv_apb_bridge.sv` | 72 |
| `cdriscv_core.sv` | 436 |
| `cdriscv_lsu.sv` | 104 |
| `cdriscv_mbist.sv` | 127 |
| `cdriscv_multdiv.sv` | 115 |

Each is `default: state_d = <IDLE>;` in a `unique case (state_q)` that
already lists every value of the state enum. No sequence of inputs can
put the register outside its enum, so simulation cannot reach these.

**They must not be deleted, and that is the point of the waiver.** An
upset in a state register *can* put the machine into an unused
encoding, and these arms are what returns it to a defined state rather
than leaving it stuck. Removing them to reach 100 % would trade a
safety property for a coverage number. The fault injection campaign is
where this behaviour is exercised, not the functional tests — and the
campaign has so far recorded no hang across 3 000 injections, which is
the evidence that the recovery works.

### W2b — mux arms over selectors with no spare encodings

| file | line | selector |
|------|------|----------|
| `cdriscv_alu.sv` | 124 | ALU operation enum |
| `cdriscv_decoder.sv` | 252 | OP-IMM `funct3`, all eight values listed |
| `cdriscv_core.sv` | 197, 206 | operand select enum |
| `cdriscv_core.sv` | 479 | writeback select enum |
| `cdriscv_lsu.sv` | 80, 142 | `addr[1:0]`, all four values listed |
| `cdriscv_multdiv.sv` | 195 | mul/div operation enum |

The LSU pair is the clearest case: `unique case (addr_i[1:0])` lists
`2'b00` through `2'b11`, so the default is unreachable by construction
— a two-bit selector has no fifth value. The others are enums whose
every member has an arm.

These are cheap to keep and give a defined output for an undefined
selector, which is the same argument as W2a in combinational form.

### W2c — APB decode arms the bridge makes unreachable

| file | line |
|------|------|
| `cdriscv_mbist.sv` | 237 |

This one is worth spelling out because it *looks* reachable and is not.
The BIST decodes `reg_ofs = paddr_i[3:0]` with arms for `0`, `4`, `8`
and `c`. An offset of, say, `0x41` would select the default — but no
such address ever arrives, because the APB bridge drives

```systemverilog
assign paddr_o = {addr_q[11:2], 2'b00};
```

The low two address bits are forced to zero for every peripheral
access, byte and halfword accesses included, so `reg_ofs` can only ever
be `0`, `4`, `8` or `c`. A byte read at `0x41` reaches the BIST as a
read of `0x40`.

This was checked rather than assumed: `rdback_test.S` issues exactly
that byte read, and the line stayed uncovered.

The equivalent `default: prdata_o = 32'b0;` in every *other* peripheral
is **not** waived and is covered, because those decode the full
`paddr_i[7:0]` and an unmapped word offset selects them normally.

### What would invalidate this waiver

* A decoder gaining an opcode or `funct3` arm, which can turn a
  "fully enumerated" claim false. That is how two lines were waived
  wrongly the first time.
* A peripheral that decodes `paddr_i[1:0]`, or an APB bridge that stops
  forcing them to zero — W2c would become reachable and must then be
  tested rather than waived.
* Any state enum gaining a value without an arm, which would turn a
  W2a default from unreachable into a live path.
* Gate level simulation, where synthesis may encode states differently
  and the "unreachable" argument has to be re-made against the netlist
  rather than the RTL. That is objective O8 and is not done.

## W1 — WITHDRAWN (2026-08-21)

The prefetch was deepened (V2-P1), and as this waiver predicted, the
three lines it covered became reachable: the fetcher now runs ahead, so
a redirect routinely finds a transaction in flight. The invariant
assertion that justified the waiver failed on the very first run after
the change, which is what it was written for.

Nothing is waived here any more. The original text is kept below,
because a withdrawn waiver is part of the argument's history.

### Original text

## W1 — `cdriscv_if_stage.sv:87-89`, redirect coincident with a response

```systemverilog
end else if (resp_accepted) begin
  outstanding_q <= 1'b0;
  discard_q     <= 1'b0;
end
```

**Reached when** a redirect arrives while a fetch is still in flight,
and that fetch's response lands in the same cycle.

**These lines are not dead code.** Bounded model checking finds a
five-step counterexample to the invariant "no fetch is outstanding at a
redirect" when the block is checked against its own input space: a
redirect arriving while the buffer is empty leaves a fetch in flight,
and the block handles it correctly. The lines are defensive, and a
reuse of this block with a different execute stage would need them.

**Why the assembled subsystem cannot reach them.** `cdriscv_core` only
asserts `redirect` in a cycle where it holds a valid instruction —
every redirect comes from a trap or a retire, and both require
`instr_valid`. With that as an assumption, `p_no_outstanding_at_redirect`
in `verif/formal/if_stage_fv.sv` **passes** to depth 20: with a
one-deep buffer, no fetch can be in flight at a redirect, so neither
this branch nor the `outstanding_q` branch below it can execute.

**The assumption is itself checked**, not merely assumed:
`verif/core/tb_cosim.sv` asserts `redirect |-> instr_valid` on every
co-simulation cycle, so every directed and random run discharges it.

**What covers the lines instead.** For the general case, `p_pc_stream`
to depth 20; its mutation test removes the discard on a coincident
redirect and is caught at step 6.

**Status.** Accepted for the current prefetch depth, and deliberately
*not* removed from the RTL. Finding V2-P1 proposes deepening the
prefetch, and the moment that happens these branches become live —
`p_no_outstanding_at_redirect` is expected to fail then, which is
exactly why it is written down as an assertion rather than a comment.

### How this waiver changed

The first version of it said the lines were merely hard to reach in
simulation, and guessed at a structural reason. Formal disproved the
guess in five steps. Writing the invariant down as a property, rather
than asserting it in prose, is what turned an assumption into either a
proof or a counterexample — and here it produced one of each,
depending on whether the core's own discipline is assumed.

## Format for future entries

Each waiver states: the lines, when they would be reached, why
simulation cannot reach them, what covers them instead, and whether the
waiver is permanent or has a to-do attached. A waiver without the third
and fourth parts is not a waiver, it is an excuse.
