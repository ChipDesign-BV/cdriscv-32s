# Plan: benchmarking cdriscv-32s against the Synopsys ARC-V RMX-100

> **Status: a plan.** No benchmark has been run, no figure in this
> document is a measurement, and the design under discussion has not
> been verified. Numbers quoted from third parties below are from
> memory and are marked as such — **every one of them must be checked
> against its primary source before it appears in a comparison.**

## 1. What the comparison is for

Two different questions get confused in benchmark exercises, and they
need separating up front:

1. **How fast is cdriscv-32s?** An absolute figure, on standard
   benchmarks, that can be compared with anything.
2. **How does it compare with the core a customer would otherwise
   licence?** The RMX-100 is the smallest member of Synopsys' ARC-V
   family and sits in the same segment: small, in-order, 32-bit, deeply
   embedded control.

Question 1 is entirely within our control. Question 2 is not, because
the RMX-100 is licensed IP — see section 4. The plan therefore builds
question 1 properly first, so that whatever access we get for question 2
lands on a harness that is already trustworthy.

It is also worth being explicit about the axes on which cdriscv-32s is
*not* trying to win. It is a two stage machine with a 33 cycle
multiply, no branch prediction and no compressed instructions. It will
lose on CoreMark and it will lose badly on code size. What it is built
to win on is determinism, diagnostic coverage and the fact that the
safety mechanisms are in the box rather than in an option package. A
benchmark report that only lists CoreMark/MHz measures the wrong thing;
section 6 defines the full metric set.

## 2. Prerequisite: verification

CoreMark and Dhrystone both self-check (CoreMark via CRC over its work
lists, Dhrystone by printing expected values), so they are useful
bring-up vehicles from day one. They are *not* evidence of correctness.

Sequencing:

* Run CoreMark during phase V0–V1 of `verification_plan.md` as a smoke
  test — it will find bring-up bugs faster than the smoke program does.
* Do not publish or act on any number before V3 (arch tests plus random
  co-simulation clean). A cycle count from a core that computes the
  wrong answer is not a performance figure.

## 3. Benchmark selection

| Benchmark | Why | Notes |
|-----------|-----|-------|
| **CoreMark 1.0** | The de facto figure of merit in this segment, and what vendors publish | Self-checking. Needs a timer and character output. Report `CoreMark/MHz`. |
| **Dhrystone 2.1** | Still quoted in datasheets, so needed for like-for-like with vendor material | Known to be gameable by the compiler; report the flags. |
| **Embench-IoT 2.0** | The least gameable of the three, and it scores **code size** as a first class result | Relative scores against a reference platform; the right primary source for the code density comparison. |
| **Application kernel** | The IP exists for control loops, so measure one | PID loop plus ADC sequencing through `cdriscv_ams_if`, watchdog servicing, and a safety interrupt. Ours to write. |
| **Determinism suite** | The axis the design is built for | Cycle count variance across runs, worst-case interrupt latency, WCET of the longest instruction sequence. |

In simulation, frequency drops out of the headline metrics entirely:

```
CoreMark/MHz = ITERATIONS * 1e6 / total_cycles
DMIPS/MHz    = (ITERATIONS * 1e6 / total_cycles) / 1757
```

so the primary measurement is a cycle count, and `fmax` is a separate,
independent measurement from synthesis (section 6.3).

## 4. Getting to an RMX-100 number

In decreasing order of value:

1. **Synopsys evaluation.** A cycle-accurate model (nSIM / xCAM class
   tooling) or an FPGA evaluation kit under NDA, driven with *our*
   binaries and *our* memory configuration. This is the only route to a
   genuine apples-to-apples number. Action: request an evaluation,
   stating that the intent is a published comparison — that changes what
   they are willing to provide.
2. **Published EEMBC scores.** CoreMark results in the EEMBC database
   are certified and carry their conditions with them. Check whether the
   RMX-100 has an entry.
3. **Synopsys product material.** Datasheet and product brief figures.
   Usable, but record the configuration: vendor numbers are normally the
   best-case configuration, with every optional accelerator enabled, and
   with a memory system that does not stall.
4. **Proxy ladder.** Benchmark the open cores in the same class on our
   own harness — Ibex (small and performance configurations), CV32E40P,
   VexRiscv, PicoRV32 — and place the published RMX-100 figure on that
   ladder with the uncertainty stated. Fully reproducible, entirely
   within our control, and it is what makes our own number
   interpretable.

**Do 4 immediately and pursue 1 in parallel.** Do not build the
comparison on 3 alone.

Facts about the RMX-100 that this plan assumes and that must be
confirmed from Synopsys documentation before use (all from memory, none
verified):

* smallest member of the ARC-V family, aimed at deeply embedded
  control, 32-bit, in-order, short pipeline (believed three stages);
* supports the RISC-V code density and bit manipulation extensions,
  consistent with the `-march` string in `isa_extension_plan.md`;
* functional safety variants exist across the ARC/ARC-V range — whether
  an RMX-100 configuration with lockstep and ECC exists, and what it
  costs in area, decides whether the safety comparison in section 6.4 is
  against a like configuration or against a plain one.

## 5. Rules of engagement

Without these, the numbers are worthless and, worse, arguable.

* **One toolchain where possible.** ARC-V *is* RISC-V, so upstream GCC
  can build for both cores; only `-mtune` differs, and `-mtune` changes
  scheduling, not the ISA. Build both with the same compiler version and
  the same flags, and report the tuning model used for each. (Note the
  finding in `isa_extension_plan.md`: `-mtune=arc-v-rmx-100-series` does
  not exist in upstream GCC, so the RMX-100 build either uses the
  Synopsys toolchain or an upstream substitute such as `-mtune=size`.)
* **Two comparison points, always reported together.**
  * **Common ISA**: both cores restricted to `rv32im`, identical
    binaries. Isolates the microarchitecture and is the only honest way
    to compare the cores as they exist today.
  * **Native ISA**: each core with its full `-march`. This is what a
    customer experiences. Until the extension work in
    `isa_extension_plan.md` is done, cdriscv-32s cannot compete here,
    and the gap in this column is precisely the business case for that
    work.
* **Same memory system.** Zero wait state tightly coupled memory on
  both sides, large enough that nothing spills. Record cache
  configuration if the other core has one; a cached core measured
  against an uncached one is not a microarchitecture comparison.
* **Same iteration counts**, same benchmark version, same optimisation
  level, and report `-O2` and `-Os` separately — code size conclusions
  from `-O2` are misleading.
* **Report cycles, and derive everything else.** Never compare across
  cores using a wall clock figure that mixes microarchitecture with
  process technology.
* **Publish the harness.** Every number in the report must be
  reproducible from the repository by someone outside the team.

## 6. Metric set

### 6.1 Performance

| Metric | cdriscv-32s (single core) | cdriscv-32s (lockstep) | RMX-100 | Source |
|--------|---|---|---|---|
| CoreMark/MHz, common ISA | | | | measured / published |
| CoreMark/MHz, native ISA | | | | |
| DMIPS/MHz | | | | |
| Embench-IoT speed score | | | | |
| Application kernel, cycles per control loop | | | | |

The lockstep column should equal the single core column exactly. If it
does not, something is wrong with the lockstep wrapper — a free
consistency check worth running.

### 6.2 Where the cycles go

More useful than the headline number, and the actual deliverable of the
exercise. Instrument the Verilator model with counters and report, per
benchmark:

* instructions retired, total cycles, CPI;
* cycles stalled waiting for the instruction buffer (fetch bound);
* cycles in `ST_WAIT_LSU` (load/store bound);
* cycles in `ST_WAIT_MD` (multiply/divide bound);
* cycles lost to redirects (taken branches, jumps, traps, `fence.i`);
* cycles the data master spent losing I-TCM arbitration to the fetcher —
  and vice versa.

This breakdown converts directly into the improvement backlog of
section 8.

### 6.3 Area, frequency, power

We have the IHP SG13G2 PDK and the LibreLane flow, so these are real
measurements for our side rather than estimates:

* area in µm² **and in kGE** (gate equivalents), because the RMX-100
  figure will be on a different node and only kGE compares;
* `fmax` from static timing at the target corner;
* a breakdown by configuration, so the safety overhead is visible and
  the comparison against a non-safety core stays honest:
  single core, no ECC / single core with ECC / lockstep with ECC /
  full subsystem with peripherals;
* power from switching activity on the CoreMark run, if the flow
  supports it.

Set `ItcmWords`/`DtcmWords` to something a real block would carry, and
report memory area separately from logic area — otherwise the TCMs
dominate and hide every logic difference.

### 6.4 The axes the design is actually built for

| Metric | How measured |
|--------|--------------|
| Worst-case interrupt latency, in cycles | interrupt asserted at every cycle offset across a workload; report the maximum and the distribution |
| Execution time jitter | same input, repeated runs, and across the multi-cycle instruction mix; a deterministic core should show zero jitter |
| WCET of the longest instruction | multiply/divide is 33 cycles by construction; confirm and document |
| Diagnostic coverage | from the fault injection campaign in `verification_plan.md` section 9 |
| Safety mechanisms included as standard | feature-by-feature table against the RMX-100 safety configuration |
| Code size | `.text` bytes for identical source, both ISA points |

The last row is where the extension work pays: expect 20–30 % of code
size to be recoverable with Zca/Zcb/Zcmp.

## 6.5 First measurement (2026-08-20)

Not a benchmark, but the first real cycle count from the co-simulation
program: **213 instructions in 1674 cycles, CPI 7.9**, of which about
560 cycles are seventeen 33-cycle multiply and divide instructions.

The dominant structural cost is not the multiplier: it is that the
single entry instruction buffer guarantees a one cycle fetch bubble on
every instruction, so **CPI 2 is the floor** for straight-line code.
See finding V2-P1 in `verification_findings.md`. This moves "deeper
prefetch" to the top of the improvement backlog of section 8, ahead of
the fast multiplier that section 7 predicted would lead it.

The prediction in section 7 below (CPI 1.5–2.5) was therefore wrong,
and is left standing rather than quietly edited.

## 7. What to expect

Predictions, stated so that being wrong is visible later. None of these
is a measurement.

* **CPI on CoreMark around 1.5–2.5.** Four contributors, in the order I
  expect them to matter: the 33 cycle multiply and divide; the two cycle
  minimum data access; the redirect penalty on every taken branch,
  which empties the instruction buffer; and the single entry buffer
  itself, which cannot cover a redirect latency.
* **CoreMark/MHz materially below the class.** Small in-order 32-bit
  cores commonly publish in the low single digits of CoreMark/MHz (the
  widely quoted ARM figures for Cortex-M0+ and Cortex-M3 are in that
  range — *check the primary source before quoting either*). With the
  CPI above, cdriscv-32s should be expected to land well under a
  typical figure for the class, and the point of the exercise is to
  find out by how much and, more importantly, why.
* **Code size roughly a third worse than the RMX-100** until the
  compressed and push/pop extensions exist.
* **Area roughly double a comparable non-safety core**, before ECC and
  peripherals. That is the price of dual core lockstep and it should be
  presented as such, not buried.
* **Determinism and interrupt latency should be excellent**, and
  should be the headline of any comparison we publish.

## 8. Deliverables

1. `bench/` in the repository: benchmark sources as submodules or
   vendored with their licences, the C runtime shim (character output
   through the SoC expansion slot, `clock()` mapped to `mcycle`), the
   linker scripts, and a `make bench` target that produces a machine
   readable results file.
2. A cycle-accounting harness in the Verilator model (section 6.2).
3. A results report, regenerated from the results file, with the tables
   of section 6 and the conditions of every third-party number spelled
   out.
4. **An improvement backlog**, ranked by cycles saved per gate added.
   Based on the predictions above, I expect it to open with: a fast
   multiplier option (single or few cycle, parameterised so the
   iterative one stays available for the deterministic configuration);
   a deeper prefetch buffer; and cheaper taken branches. Each of these
   is a design change to be planned separately, not part of this work.

## 9. Effort

Assumes the core is at V3 of the verification plan.

| Step | Effort |
|------|--------|
| C runtime shim, character output, `mcycle` timer, linker scripts | 2–3 d |
| CoreMark and Dhrystone bring-up and first numbers | 2–3 d |
| Embench-IoT bring-up | 2–3 d |
| Cycle accounting instrumentation | 2 d |
| Application kernel and determinism suite | 3–4 d |
| Proxy ladder: three open cores on the same harness | 4–5 d |
| Synthesis runs for area and `fmax` across four configurations | 3–4 d |
| Report | 2–3 d |
| | **4–5 weeks** |

Plus whatever the Synopsys evaluation takes in calendar time, which is
the long pole and should be started on day one.

## 10. Risks

| Risk | Mitigation |
|------|------------|
| No access to an RMX-100 model, leaving only marketing numbers | build the proxy ladder so our own figures are interpretable without it; state the uncertainty rather than hiding it |
| Comparing our unverified core and drawing conclusions from wrong results | gate publication at V3; rely on the benchmarks' self-checks in the meantime |
| The comparison reads as advocacy rather than engineering | fix the metric set and the rules of engagement *before* the first number arrives, which is what this document is for |
| Vendor figures measured in a configuration we cannot match (caches, accelerators, different memory) | record conditions for every quoted number; if they cannot be matched, report the difference instead of normalising it away |
| Benchmark scores drive the roadmap towards the things benchmarks measure | keep section 6.4 in the same report, with equal weight |
