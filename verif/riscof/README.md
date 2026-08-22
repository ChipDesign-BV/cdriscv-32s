# RISCOF — architectural test suite (objective O1)

**Status: infrastructure in place, not yet producing a result.** Read
the last section before quoting anything from here.

## What this is

RISCOF runs the official `riscv-arch-test` suite against the DUT and a
reference model, and compares signatures. It is the only thing that
answers "does this core implement the RISC-V specification" — Spike
co-simulation answers the weaker question "does it agree with Spike on
the programs we happened to write".

## Setup

The test suite is 1.7 GB and is not vendored:

```sh
pip install "cython<3" && pip install --no-build-isolation riscof
cd verif/riscof && riscof arch-test --clone
```

The plugins expect a `riscv32-unknown-elf-*` toolchain prefix and this
environment ships `riscv64-`, which targets rv32 perfectly well through
`-march`/`-mabi`. Symlink rather than patch the vendor plugin:

```sh
for t in gcc objcopy nm objdump ld as; do
  ln -sf "$(command -v riscv64-unknown-elf-$t)" ~/.local/bin/riscv32-unknown-elf-$t
done
```

Then `make riscof`.

## How the DUT plugin works

`cdriscv/riscof_cdriscv.py` builds each test and runs it on the Icarus
co-simulation bench:

1. `objcopy` the ELF to a flat binary from `0x8000_0000`, padded to
   `end_signature`, so code, `.tohost` and the signature region land at
   the right word offsets;
2. `mkimage.py` turns that into the 39-bit ECC hex image the TCM loads
   — the same builder the rest of the suite uses;
3. `vvp` runs it with `+TOHOST`, `+SIGBEGIN`, `+SIGEND` and `+SIGFILE`.

The bench watches for the store to `tohost`, then dumps the signature
words straight out of the I-TCM array. The SEC-DED encoding is
systematic — `cw = {parity, data}` — so the data half is the low 32
bits. All four plusargs come from the ELF symbol table via `nm`;
nothing about the addresses is assumed.

`env/model_test.h` and `env/link.ld` are the target environment. There
is no console, so the IO macros are empty and the signature is the only
output.

## Status: 85 of 85 pass, on the current suite

`make riscof` runs against the **current `riscv-arch-test`, unmodified**:
39 from I, 8 from M, 22 hints, 15 privilege, 1 Zifencei. **85 passed, 0
failed.**

Two things make that work, both in `cdriscv/riscof_cdriscv.py` and
`spike/riscof_spike.py`:

* **`-mno-relax`.** The suite's `LA` macro brackets its alignment in
  `.option rvc`, so the assembler pads with `c.nop` even on a target with no
  C extension, and linker relaxation keeps that padding in the executed
  stream. An RV32I core must trap on a 16-bit encoding, and Spike traps at
  the same address. Turning relaxation off resolves the padding away. This
  replaces the earlier workaround of pinning the suite to release 3.5.3.
* **The `pmp` group is dropped from the generated test list.** All 43 gate
  PMP on `verify (PMP['implemented'])`, and RISCOF selects on `check` clauses
  only, so they are selected on any RV32 I+Zicsr core. This core implements
  no PMP and has no U mode. `make riscof` prints how many it dropped.

Both, and two more, are written up in [upstream-issues.md](upstream-issues.md).

### Setup

```sh
pip install "cython<3" && pip install --no-build-isolation riscof
cd verif/riscof && riscof arch-test --clone
git -C riscv-arch-test checkout old-framework-3.x   # main no longer has the suite
for t in gcc objcopy nm objdump ld as; do
  ln -sf "$(command -v riscv64-unknown-elf-$t)" ~/.local/bin/riscv32-unknown-elf-$t
done
```

### One trap to be careful of

`RVMODEL_DATA_SECTION` must expand inside `RVMODEL_DATA_END`, after
`end_signature` — never inside `RVMODEL_DATA_BEGIN`. On RISC-V `.align 8`
means 256 bytes, so that block drags ~400 bytes of padding with it, and ahead
of the signature the padding sits between `rvtest_data` and `mtrap_sigptr`.
The arch-test trap handler records `mtval` *relative to `mtrap_sigptr`*, so
the same faulting address then encodes as a different number than in the
reference build, and every misaligned-**load** test fails while everything
else passes. See finding V35.

## How the earlier releases fail (kept for the record)

**The reference model traps in the same place the DUT does.** Spike on
`add-01.S`:

```
core 0: 0x800002c8 (0x00000001) c.nop
core 0: exception trap_illegal_instruction, epc 0x800002c8
```

So the 128 signature files an earlier run produced are not references:
Spike was spinning in its trap path and the `--instructions` bound was
dumping whatever was in memory. A file being produced is not a result.

**The blocker is the test suite, not either model**, and that is now
proven from both sides rather than inferred from one. The DUT traps at
the first piece of alignment padding, and so does the reference:

```
800002c8:  0001       nop     <-- c.nop, 16-bit
```

`env/arch_test.h` does `.option rvc` in three places, unconditionally,
so that `.align` can pad with `c.nop`. The ELF attribute says
`rv32i2p1` and the padding is compressed regardless. On a core with the
C extension that is harmless; **this core is RV32IM_Zicsr_Zifencei and
must trap on a 16-bit encoding** — correctly, and the padding is in the
straight-line stream, not skipped.

Patching `arch_test.h` would make the run pass and would also mean the
result no longer came from the official suite, which is the whole point
of running it. So it has not been patched. **No conformance claim can
be made from this directory** and the README status table says so.
