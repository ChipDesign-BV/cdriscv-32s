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

**The reference model is the blocker, not the DUT.** Spike takes far
longer per test here than it should — minutes rather than milliseconds
— so a full run does not complete. One reference signature was produced
and is complete (592 words for `add-01.S`), which says the flow is
correct and the throughput is not.

Not yet investigated: whether this is a Spike build issue in this
environment, an interaction with `+signature-granularity`, or the test
environment's HTIF handling. Until it is, **no conformance claim can be
made from this directory**, and the README status table says so.

The DUT side has never been exercised end to end for the same reason —
RISCOF runs the reference first.
