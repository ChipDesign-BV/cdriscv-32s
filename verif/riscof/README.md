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

## Status: 59 of 62 pass, on release 3.5.3

`make riscof` runs against **`riscv-arch-test` 3.5.3, unmodified**.

Current releases cannot be used with this core. `env/arch_test.h` wraps
its `.align` directives in `.option rvc` so the assembler pads with
`c.nop`, unconditionally, and that padding lands in the executable
instruction stream. An RV32I core must trap on a 16-bit encoding — and
**Spike traps at the same address**, so the suite build is wrong for
non-C targets rather than the core being wrong. 3.5.3 (2022-12-27) is
the newest release predating that change.

### Setup

```sh
pip install "cython<3" && pip install --no-build-isolation riscof
cd verif/riscof && riscof arch-test --clone
git -C riscv-arch-test worktree add ../arch-test-3.5.3 3.5.3
for t in gcc objcopy nm objdump ld as; do
  ln -sf "$(command -v riscv64-unknown-elf-$t)" ~/.local/bin/riscv32-unknown-elf-$t
done
```

Two tests must be removed from the 3.5.3 tree, both for reasons
external to this design:

* `rv32i_m/C/src/cebreak-01.S` — a C extension test **selected by a
  typo**: its regex is `.*I.*Zicsr.*.C*`, and `C*` matches zero
  occurrences, so it selects on cores without C. The other 26 C tests
  use `.*C.*`.
* `rv32i_m/I/src/jalr-01.S` — modern binutils rejects `la x0,5b`.

### Known failures

`misalign-lh-01.S`, `misalign-lhu-01.S`, `misalign-lw-01.S`. Misaligned
**stores** pass. Three signature words of 72 differ; the reference
values look like sign-extended bytes and the DUT's like sign-extended
halfwords. **Open and unexplained** — see finding V34.

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
