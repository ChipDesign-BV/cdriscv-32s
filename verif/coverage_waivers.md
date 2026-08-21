# Coverage waivers

Objective O6 asks for 100 % line coverage **with a reviewed waiver for
each exclusion**. This file is that review. A waiver here is a claim
that a line cannot be reached by simulation *and* that something else
covers it — not a note that nobody got round to it.

Anything not listed here is a gap to be closed by a test, and the
current list of those is in `verification_findings.md`.

## W1 — `cdriscv_if_stage.sv:87-89`, redirect coincident with a response

```systemverilog
end else if (resp_accepted) begin
  outstanding_q <= 1'b0;
  discard_q     <= 1'b0;
end
```

**Reached when** a redirect (taken branch, jump, trap, `fence.i`)
occurs in the same cycle as the response to an already-outstanding
fetch, with no new request granted that cycle.

**Why simulation does not reach it.** The TCM answers exactly one cycle
after a grant, and the core needs at least two cycles per instruction,
so an outstanding fetch has always completed before the next redirect.
The bench's stall injector delays *grants*, which moves the response
later as a block but never lands it on the redirect cycle; reaching it
needs a memory model with variable *response* latency, which the bench
does not have. Four stall rates from 15 % to 90 % were tried.

**What covers it instead.** Bounded model checking. `make formal-if`
explores every interleaving of request, response and redirect to depth
20, and `p_pc_stream` — every delivered instruction is the next of the
stream that began at the last redirect — fails if this branch is wrong.
The mutation test for that property removes the discard on a coincident
redirect and is caught at step 6, which is the same class of bug.

**Status.** Accepted, with a to-do: a variable-latency memory model
would close it in simulation as well, and is worth having anyway for
the bus tests.

## Format for future entries

Each waiver states: the lines, when they would be reached, why
simulation cannot reach them, what covers them instead, and whether the
waiver is permanent or has a to-do attached. A waiver without the third
and fourth parts is not a waiver, it is an excuse.
