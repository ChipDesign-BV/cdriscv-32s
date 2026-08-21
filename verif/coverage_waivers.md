# Coverage waivers

Objective O6 asks for 100 % line coverage **with a reviewed waiver for
each exclusion**. This file is that review. A waiver here is a claim
that a line cannot be reached by simulation *and* that something else
covers it — not a note that nobody got round to it.

Anything not listed here is a gap to be closed by a test, and the
current list of those is in `verification_findings.md`.

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
