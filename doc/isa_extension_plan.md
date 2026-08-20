# Plan: extending cdriscv-32s to `rv32im_zba_zbb_zbs_zicsr_zca_zcb_zcmp`

Target build flags:

```
-march=rv32im_zba_zbb_zbs_zicsr_zca_zcb_zcmp
-mabi=ilp32
-mtune=arc-v-rmx-100-series
```

> **Status: a plan, nothing more.** The base IP is still unverified (see
> `verification_plan.md`); none of the work below has been started, and
> the effort figures are estimates, not commitments.

## 1. Verdict

**Yes, the architecture can be extended to this ISA**, and nothing in
the current design forecloses it. The work splits into three very
different categories:

| Group | Nature of the change | Risk |
|-------|----------------------|------|
| `zba`, `zbb`, `zbs` | Additive: new ALU functions and decoder entries. No change to the pipeline, the FSM, the bus or the safety architecture. | Low |
| `zca`, `zcb` | Structural: instructions become 2-byte aligned and 32-bit instructions may span two fetch words. The fetch stage is rewritten and a decompressor is added. | **High** |
| `zcmp` | Structural: one instruction performs up to 13 memory accesses. Breaks the "one instruction, at most one memory access" invariant the execute FSM and the WCET argument rest on. | **High** |
| `-mabi=ilp32` | No hardware impact (soft float, no F/D registers). | None |
| `-mtune=arc-v-rmx-100-series` | No hardware impact — `-mtune` only selects GCC's scheduling and cost model. **But see section 2.** | None (toolchain issue) |

The two structural groups are what turn this from a two week job into a
six week one. They are also the two that invalidate parts of the safety
argument, so they carry documentation and re-verification work beyond
the RTL itself.

## 2. Toolchain finding: `-mtune=arc-v-rmx-100-series` is not available here

The container's compiler is upstream `riscv64-unknown-elf-gcc 16.1.0`.
It accepts the `-march` and `-mabi` strings, but rejects the tuning
model:

```
cc1: error: unknown cpu 'arc-v-rmx-100-series' for '-mtune'
```

Its known `-mtune` values are the upstream set (`generic`, `rocket`,
`sifive-*`, `andes-*`, `thead/xt-*`, `spacemit-x60`, `mips-p8700`,
`size`, …). ARC-V tuning models ship with **Synopsys' ARC-V GNU
toolchain**, not with upstream GCC.

Consequences for the plan:

* The ISA requirement and the tuning requirement are independent. All
  the hardware work below is driven by `-march` alone.
* If the deliverable must build with that exact command line, the build
  environment has to be the Synopsys ARC-V toolchain. That is a
  procurement/setup item, not a design item.
* If the intent is instead *binary compatibility with an ARC-V RMX-100
  class core*, then `-march` is the whole requirement, and any tuning
  model can be used. `-mtune=size` or `-mtune=generic` would be the
  sensible upstream substitutes; tuning for a foreign pipeline costs
  performance, never correctness.
* Worth deciding explicitly: a scheduling model built for RMX-100
  assumes that core's load-use and multiply latencies. cdriscv-32s has
  a 33 cycle multiply/divide and a memory-latency-bound load, so the
  schedule will be mis-tuned either way. This matters for cycle count,
  not for function.

## 3. What the target code actually looks like

Compiled with the requested `-march` (upstream GCC, `-Os`), a trivial
function already exercises every hard case:

```
00000000 <f>:
   0:  b886        cm.push  {ra,s0-s3},-48     <- Zcmp, 6 memory accesses
   2:  892a        mv       s2,a0              <- 16-bit at a 2-aligned PC
   8:  00251993    slli     s3,a0,0x2
   c:  00b44563    blt      s0,a1,16
  10:  28b49533    bset     a0,s1,a1           <- Zbs
  14:  be86        cm.popret {ra,s0-s3},48     <- Zcmp: loads, sp add, return
  16:  00890533    add      a0,s2,s0           <- 32-bit at PC mod 4 == 2:
                                                  spans two fetch words
  1a:  c62e        sw       a1,12(sp)
```

Note address `0x16`: a 32-bit instruction starting two bytes before a
word boundary. Handling that is not an optimisation, it is the
correctness case.

## 4. Impact per extension

### 4.1 Zba — trivial

Three instructions on RV32: `sh1add`, `sh2add`, `sh3add`
(`OP`, funct7 `0010000`, funct3 `010`/`100`/`110`).

* `cdriscv_alu.sv`: one 2-bit pre-shift on operand A ahead of the
  existing adder. No new adder.
* `cdriscv_decoder.sv`: three decode entries.

Roughly 30 lines. No timing risk.

### 4.2 Zbb — the bulk of the ALU work

| Sub-group | Instructions | Implementation |
|-----------|--------------|----------------|
| Logic with negate | `andn`, `orn`, `xnor` | invert operand B into the existing logic block |
| Rotate | `rol`, `ror`, `rori` | replace the current reverse-and-shift-right structure with a 64-bit funnel shifter (`{a,a} >> shamt`), which then also serves `sll`/`srl`/`sra` |
| Count | `clz`, `ctz`, `cpop` | combinational: leading-zero count over the (already available) reversal, plus a popcount adder tree |
| Compare | `min`, `max`, `minu`, `maxu` | reuse the existing `cmp_lt` from the shared adder, plus a mux |
| Extend | `sext.b`, `sext.h`, `zext.h` | wiring |
| Permute | `rev8`, `orc.b` | wiring |

Two design decisions to make:

1. **Funnel shifter vs. second shifter.** The funnel shifter is the
   clean answer and removes the current operand-reversal trick, but it
   is the widest structure in the ALU and is a candidate for the
   critical path. Alternative: keep the existing shifter and add a
   rotate-correction stage.
2. **`clz`/`ctz`/`cpop` latency.** Combinational keeps every ALU
   instruction single cycle, which is what the WCET argument likes.
   If they land on the critical path, the fallback is to route them
   through the existing iterative unit (`cdriscv_multdiv`) at a fixed
   cost, which keeps latency data-independent.

`alu_op_e` currently uses 15 of 16 encodings. Zba+Zbb+Zbs add about 24
operations, so the field must grow to 6 bits, or be restructured as
`{class, sub-op}`. The latter is preferable: it keeps the ALU result
mux shallow, which is where the added width will otherwise cost timing.

Splitting the heavier functions into `rtl/core/cdriscv_bitmanip.sv`
keeps `cdriscv_alu.sv` readable.

### 4.3 Zbs — small

`bset`, `bclr`, `binv`, `bext` and their immediate forms. All need a
one-hot mask `1 << (b & 31)`, which is a 5-to-32 decoder, then an
and/or/xor with operand A, or a bit select. About 60 lines in the ALU
and the decoder. No structural impact.

### 4.4 Zca — the fetch rewrite

This is where the current design has to change shape, in five places.

**a) Fetch stage (`cdriscv_if_stage.sv`, rewrite).** Today: a
word-granular PC, one outstanding transaction, one buffered
instruction, and `instr[1:0] != 2'b11` rejected as illegal. Needed:

* a half-word granular fetch pointer, with word-aligned bus addresses,
* a leftover half-word register holding the upper half of the previous
  fetch word,
* assembly of a 32-bit instruction from two consecutive words,
* a redirect to a target whose bit 1 is set, where the lower half of
  the first returned word must be discarded,
* correct error attribution when only one of the two halves of an
  instruction comes back with an error.

Expect the stage to go from ~120 to ~280 lines, and expect it to be the
main source of bugs. A 2-entry prefetch FIFO is recommended (compressed
code averages about 3 bytes per instruction, so one 32-bit word per
cycle feeds more than one instruction per cycle) but is an optimisation,
not a correctness requirement.

**b) Decompressor (`rtl/core/cdriscv_decompress.sv`, new).** A
combinational 16→32 bit expander placed between the fetch stage and the
existing decoder, so `cdriscv_decoder.sv` keeps seeing only 32-bit
encodings. About 250 lines, mechanical, and — importantly — exhaustively
checkable (see section 7). Zca for RV32 includes `c.jal`.

**c) Instruction length in the execute stage (`cdriscv_core.sv`).**

* `redirect_pc = instr_pc + 4` becomes `+ 2` or `+ 4`,
* the link value for `jal`/`jalr` (`OP_B_FOUR`) becomes `OP_B_ILEN`,
* `instr_misalign` must be relaxed: with IALIGN=16 a control transfer
  target only has to be 2-byte aligned, so the instruction-address
  misaligned exception effectively disappears (`jalr` still clears
  bit 0). Leaving the current check in place would trap on perfectly
  legal compressed code.

**d) CSRs (`cdriscv_csr.sv`).**

* `misa` must set the C bit (bit 2). With no F or D, Zca alone is
  architecturally the C extension.
* `mepc` masking changes from `{pc[31:2], 2'b00}` to `{pc[31:1], 1'b0}`
  — in two places (the trap path and the CSR write path). Getting this
  wrong silently corrupts every return from a trap taken on a 2-aligned
  instruction.

**e) Trace and lockstep (`cdriscv_lockstep.sv`).** A compressed
instruction should appear on `retire_instr_o` in the low half, and a
`retire_compressed_o` (or an ilen field) is worth adding for the
tracer. **Any new core output must be added to the compared vector and
`OutW` updated** — forgetting that silently reduces lockstep coverage
rather than causing a visible failure. Worth a review check.

### 4.5 Zcb — small, once Zca exists

Extra 16-bit encodings only: `c.lbu`, `c.lhu`, `c.lh`, `c.sb`, `c.sh`,
`c.zext.b`, `c.sext.b`, `c.zext.h`, `c.sext.h`, `c.not`, `c.mul`. All
expand to 32-bit instructions the core will already have (the sub-word
loads and stores are already supported by the LSU; `c.mul` needs M,
`c.sext.h`/`c.zext.h` need Zbb — both present in the target ISA). About
60 extra lines in the decompressor.

### 4.6 Zcmp — the micro-sequenced instructions

`cm.push`, `cm.pop`, `cm.popret`, `cm.popretz`, `cm.mva01s`,
`cm.mvsa01`. A single 16-bit instruction can store or load up to 13
registers and adjust `sp`, and `cm.popret` additionally returns.

The current execute stage assumes one instruction performs at most one
memory access, and the LSU is built around that. Two ways forward:

* **Micro-sequencer in the execute FSM (recommended).** Add states
  `ST_ZCMP` (iterate the register list, one LSU access per cycle plus
  memory latency) and `ST_ZCMP_FIN` (stack pointer update, optional
  `a0` zeroing, optional jump to `ra`). The register file's read
  address and the write address are muxed to a sequencer-driven index.
  No change to the LSU itself.
* **Trap and emulate.** Decode as illegal and emulate in the M-mode
  handler. Rejected: in this IP an illegal instruction is also a
  *safety fault* (`FLT_CORE_TRAP`), so normal code would continuously
  raise safety faults, and the timing would be far worse.

Three semantics that must be pinned down before writing RTL:

1. **Restartability.** Update `sp` (and `ra`/`a0` for the `popret`
   forms) **last**, so that a trap partway through leaves the sequence
   idempotent: re-executing repeats the same stores from unchanged
   registers, or reloads from unchanged addresses. This must be
   checked against the ratified Zc specification text rather than
   assumed.
2. **Interrupts.** Because the sequence is idempotent, the clean
   choice is to allow an interrupt to *abort* it, with `mepc` pointing
   at the `cm.*` instruction. That keeps worst-case interrupt latency
   at roughly what it is today instead of adding 13 memory accesses to
   it — which matters directly for the fault tolerant time interval.
   The alternative (complete the sequence, then take the interrupt) is
   simpler to implement and easier to argue.
3. **Alignment.** The stack adjustment is a multiple of 16 and `sp`
   stays 16-byte aligned under ilp32; a misaligned `sp` produces
   ordinary load/store misaligned exceptions from the existing check.

## 5. Files touched

| File | Change |
|------|--------|
| `rtl/core/cdriscv_pkg.sv` | widen/restructure `alu_op_e`, add ilen and Zcmp control types |
| `rtl/core/cdriscv_alu.sv` | funnel shifter, logic-with-negate, min/max, extends, Zba pre-shift, Zbs mask |
| `rtl/core/cdriscv_bitmanip.sv` | **new**: `clz`, `ctz`, `cpop`, `rev8`, `orc.b` |
| `rtl/core/cdriscv_decoder.sv` | Zba/Zbb/Zbs decode; drop the `instr[1:0] == 11` rejection (moves to the decompressor); ilen output |
| `rtl/core/cdriscv_decompress.sv` | **new**: Zca + Zcb 16→32 expansion |
| `rtl/core/cdriscv_if_stage.sv` | rewrite for 16-bit alignment, word-spanning instructions, optional prefetch FIFO |
| `rtl/core/cdriscv_core.sv` | ilen-based PC and link values, relaxed misalign check, Zcmp sequencer states, register file address muxing |
| `rtl/core/cdriscv_csr.sv` | `misa.C`, `mepc` masking to bit 0 only |
| `rtl/core/cdriscv_regfile.sv` | read/write address muxing for the Zcmp sequencer |
| `rtl/safety/cdriscv_lockstep.sv` | compare vector width and contents for the new trace outputs |
| `tb/tb_cdriscv_subsys.sv`, `tb/sw/*`, `Makefile` | new `-march`, trace of compressed instructions |
| `doc/*` | architecture, register map (`misa`), safety manual (WCET, interrupt latency), verification plan |

## 6. Staged plan

Each phase ends in a state where the repository is consistent and the
claims in the documentation match what has actually been run.

**Phase 0 — get the base out of "unverified" (prerequisite).**
Lint, elaborate, run the smoke bench, then the RV32IM architectural
tests. Adding two structural changes on top of an unverified base means
every future failure has three possible causes instead of one. This is
the single most valuable thing to do first.
*Exit:* `make lint`, `make sim` and `riscv-arch-test` for RV32IM/Zicsr
pass, and the README status table says so.

**Phase 1 — Zba, Zbb, Zbs.**
ALU restructuring, new bit manipulation block, decoder entries.
*Exit:* architectural tests for Zba/Zbb/Zbs pass; area and timing
compared against the Phase 0 baseline; a decision recorded on the
`clz`/`ctz`/`cpop` latency question.

**Phase 2 — Zca.**
Decompressor first (it is independently testable, exhaustively), then
the fetch rewrite, then the ilen and CSR changes.
*Exit:* exhaustive decompressor equivalence check passes; architectural
tests for C pass; directed tests for word-spanning fetch, redirects to
2-aligned targets, and fetch errors on either half pass.

**Phase 3 — Zcb.**
Decompressor table extension only.
*Exit:* architectural tests for Zcb pass.

**Phase 4 — Zcmp.**
Sequencer, restart semantics, interrupt policy.
*Exit:* architectural tests for Zcmp pass; directed tests for a trap and
for an interrupt at every position within a 13-register push and pop;
new WCET numbers measured.

**Phase 5 — consolidation.**
Rebuild the smoke program with the full `-march`; update the safety
manual (new worst-case latencies, new interrupt latency, the argument
that all added logic sits inside the lockstep boundary); update the
architecture document and the register map; re-run synthesis for area
and timing; record the code size improvement.

## 7. Verification additions

* **Exhaustive decompressor check.** All 65536 16-bit patterns compared
  against a reference model, checking both the expansion and the
  illegal-instruction classification. Complete, cheap, and it removes
  the largest single source of doubt in Phase 2.
* Architectural test suites for Zba, Zbb, Zbs, Zca, Zcb, Zcmp.
* Random instruction generation against a golden model. This needs an
  RVFI-style interface, which the core does not have yet (it exposes
  only `retire_valid/pc/instr`); building it during Phase 0 pays for
  itself three times over here.
* Directed tests, in addition to those in `verification_plan.md`:
  * 32-bit instruction spanning two fetch words, with: a redirect in
    the same cycle, an ECC-corrected error in either half, an
    uncorrectable error in either half,
  * branch and jump to every 2-byte aligned offset,
  * `mepc` correctness for a trap taken on a 2-aligned instruction,
  * `cm.push`/`cm.pop` with every `rlist` value, trapping on each
    individual access,
  * interrupt asserted at each cycle of a Zcmp sequence,
  * lockstep: mismatch injected during a Zcmp sequence and during a
    word-spanning fetch.

## 8. Safety impact

Mostly neutral to positive, with three items that need writing up:

* **Everything added sits inside the lockstep boundary.** The
  decompressor, the bit manipulation logic and the Zcmp sequencer are
  all inside the compared cores, so they add no undetected fault sites.
  The compare vector must be extended for any new output.
* **Code size drops.** Zca/Zcb/Zcmp typically save 20–30 %. A smaller
  I-TCM means fewer bits exposed to upsets and a lower memory FIT
  contribution — and possibly a smaller macro. That is a real safety
  argument in favour of doing this work.
* **Worst-case execution time changes.** `cm.push`/`cm.pop` with 13
  registers is the new longest instruction. Both the WCET table and the
  interrupt latency figure in the safety manual must be recomputed, and
  the interrupt policy from section 4.6 decided, because it feeds
  directly into the fault tolerant time interval.
* One new failure mode to document: a 32-bit instruction spanning two
  ECC words can be hit by two independent memory errors, and the
  attribution rule for `mtval` on a partial fetch error must be stated.

## 9. Effort estimate

One engineer already familiar with this code base. Verification effort
is included and dominates.

| Phase | RTL | Verification | Total |
|-------|-----|--------------|-------|
| 0 (base) | 1–2 d (fixes) | 4–6 d | 1–1.5 weeks |
| 1 Zba/Zbb/Zbs | 2–3 d | 2–3 d | 1 week |
| 2 Zca | 4–6 d | 4–5 d | 2 weeks |
| 3 Zcb | 1 d | 1 d | 0.5 week |
| 4 Zcmp | 4–5 d | 3–4 d | 1.5–2 weeks |
| 5 consolidation | 2–3 d | — | 0.5 week |
| | | | **6–7 weeks** |

Dropping Zcmp (if binary compatibility with an ARC-V RMX-100 target is
not required) removes about 1.5–2 weeks and the largest structural
risk, at the cost of some code size. Dropping Zca/Zcb as well would
leave a one week, low risk job — but `zca` is where most of the code
size benefit comes from, so that is a poor trade unless the ISA
requirement is negotiable.

Area: the additions are small next to the TCMs, which dominate. Expect
the core logic to grow by roughly a quarter (doubled by the lockstep
pair), and the subsystem by a few percent — likely offset by being able
to shrink the I-TCM.

## 10. Open decisions

1. Is the requirement *this exact command line* (then the Synopsys
   ARC-V toolchain is needed), or *binary compatibility with an
   RMX-100 class core* (then `-march` alone is the requirement and the
   upstream toolchain can be used with `-mtune=size`)?
2. Is Zcmp negotiable? It carries the largest structural risk.
3. Interrupt policy during a Zcmp sequence: abort and restart (short
   interrupt latency, more logic) or complete first (simpler, longer
   worst case)?
4. `clz`/`ctz`/`cpop`: single cycle combinational, or iterative with a
   fixed multi-cycle latency?
5. Should Phase 0 (verifying the base) run first, or should the
   extensions be implemented against the unverified base and verified
   in one campaign at the end? The first is strongly recommended.
