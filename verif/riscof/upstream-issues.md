# Defects found in riscv-arch-test and RISCOF

**Filing status (2026-08-22):**

* Item 3 (pmp `verify` gating) — filed as
  [riscv/riscv-arch-test#2159](https://github.com/riscv/riscv-arch-test/issues/2159).
* Item 1 (`c.nop`) — already reported upstream (#442, #659) and fixed on
  `act4`; the `-mno-relax` workaround for `old-framework-3.x` users posted as
  a [comment on #659](https://github.com/riscv/riscv-arch-test/issues/659#issuecomment-5381756173).
* Item 2 (cebreak regex) — already fixed in the current tree; nothing to file.
* Item 4 (broken default clone) — **cannot be filed:
  `riscv-software-src/riscof` is archived and read-only.** That also means
  the defect is permanent; the workaround below is the fix.

Four problems found (one turned out to be already fixed upstream and one already reported — see each item) while bringing `make riscof` up on this core (RV32IM
Zicsr Zifencei, machine mode only, no PMP, no U mode). All are in the
tools, not in the design. Each is reduced to the smallest reproduction that
still shows it. Verified 2026-08-22 against `riscv/riscv-arch-test`
`old-framework-3.x` at `281d71ef`, `act4` at HEAD, and RISCOF 1.25.3.

## 1. `LA` emits an executable `c.nop` on targets without C — known upstream (#442, #659), fixed on `act4`; not filed as a new issue

**Where:** `riscv-test-suite/env/arch_test.h`, `LA` macro, on
`old-framework-3.x` — the branch that carries the suite RISCOF consumes.

The macro brackets its alignment in `.option rvc`, so the assembler pads with
`c.nop` even when the target has no C extension. Linker relaxation keeps the
padding in the executed stream, and every instruction after it sits at a
halfword offset. Building `rv32i_m/I/src/add-01.S` with
`-march=rv32i_zicsr_zifencei` gives six 16-bit encodings, and **Spike
configured as `rv32i` traps on the first one**:

```
800002c4:  d8840413   addi  s0,s0,-632
800002c8:  0001       .insn 2, 0x0001     <-- c.nop
800002ca:  00000013   nop                 <-- and everything after is at +2

core 0: exception trap_illegal_instruction, epc 0x800002c8
```

Minimal case, no suite involved:

```asm
	.option push
	.option rvc
	.align 5
	.option norvc
	la	a0, sym
	.align 5
	.option pop
```

`riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32` puts `0x0001` in `.text`.

This is not new: **#442** (2024) and **#659** both reported it. **#891** fixed
it on `act4` by jumping over the second alignment, and **#950** then removed
that jump when it enabled `.option norelax` suite-wide. `norelax` is the
better fix and `act4` is correct today — measured, four variants, counting
illegal-instruction traps under Spike `rv32i`:

| variant | traps |
|---|---|
| `.align`, no jump (`old-framework-3.x`) | 1 |
| `.p2align`, no jump (`act4` today) | 1 |
| `.p2align`, no jump, **`.option norelax`** (`act4` as built) | **0** |
| `.align` + `j 9f` (#891 as merged) | 0 |

**So `act4` needs nothing.** But `old-framework-3.x` is still what RISCOF
users get, and it has neither the jump nor `norelax`.

**Workaround that needs no change to the suite: build with `-mno-relax`.**
On `add-01.S`: 16-bit encodings 6 → 0, Spike `rv32i` traps 1 → 0. Across the
85 tests this core selects, adding `-mno-relax` to the plugin compile command
takes the suite from unrunnable to 85 of 85 passing.

Suggested: add `.option norelax` (or the `-mno-relax` note) to
`old-framework-3.x`, or state in the README that non-C targets must build
with `-mno-relax` or use release 3.5.3 or earlier.

## 2. `cebreak-01.S` regex typo — already fixed upstream, do not file

Release 3.5.3 gates the test with `check ISA:=regex(.*I.*Zicsr.*.C*)`, where
`C*` matches zero occurrences, so the test selects on cores without C. The
current `old-framework-3.x` tree reads `.*I.*C.*Zicsr` — fixed. Only relevant
to anyone still pinning 3.5.3, which this repository no longer does. Kept
here for the record.

## 3. The pmp tests gate PMP with a clause RISCOF never evaluates

**Where:** `riscv-test-suite/rv32i_m/pmp/src/*.S`, all 43.

```
check ISA:=regex(.*32.*); check ISA:=regex(.*I[^S]*Zicsr.*);
def rvtest_mtrap_routine=True; verify (PMP['implemented']); ...
```

PMP is gated by `verify (...)`, but RISCOF selects tests on `check` clauses
only — `riscof/framework/test.py:315`:

```python
for condition in part_dict['check']:
    include = include and eval_cond(condition, spec)
```

`verify` is never consulted. So all 43 pmp tests are selected on **any** RV32
core with I and Zicsr, whether or not it implements PMP. On this core, which
implements none, that is 43 failures that say nothing about the design.

Either the gate belongs in a `check` clause, or RISCOF should evaluate
`verify`. Filed here because the tests are here; it needs a decision from
both sides.

## 4. `riscof arch-test --clone` no longer fetches a suite

**Where:** `riscv-software-src/riscof`, `riscof/arch_test.py`.

`clone()` and `update()` default to `branch="main"`, and `main` of
`riscv/riscv-arch-test` no longer contains `riscv-test-suite/` — the legacy
suite moved to `old-framework-3.x`, and the default branch is now `act4`. A
new user following the RISCOF quickstart gets a checkout with no tests in it.
