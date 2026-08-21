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

## What is not working yet

The reference model works: **128 signatures** generate in a few
minutes. It needed `--instructions=500000`, because this Spike never
acts on the HTIF `tohost` write and the test's halt loop otherwise
spins for ever. Bounding it is safe — the signature is written before
the halt loop, and `add-01.S` gives the same 592 words either way.

**The blocker is now the test suite, not either model.** The DUT
executes the tests and traps at the first piece of alignment padding:

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
