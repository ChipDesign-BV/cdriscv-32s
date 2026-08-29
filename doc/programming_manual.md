# cdriscv-32s-10 programming manual

The firmware developer's view: what the machine looks like from
software, how to trap, how to drive each peripheral, and what the
safety mechanisms require *you* to do.

Companion documents, referenced rather than repeated:
[register_map.md](register_map.md) is the bit-level reference for every
register named here; [integration.md](integration.md) is the SoC
integrator's manual; [safety_manual.md](safety_manual.md) carries the
safety argument. Where this manual gives a register offset it is for
orientation — the authoritative bit definitions are in the register
map.

**Status.** Verified to objectives O1–O9 of
[verification_plan.md](verification_plan.md); may be used in a project.
**Not qualified for safety-critical use.** No compliance with any
functional safety standard is claimed.

## 1. The machine

| Property | Value |
|----------|-------|
| ISA | RV32IM, Zicsr, Zifencei |
| Privilege | **machine mode only** — no U or S mode, no PMP, no virtual memory |
| Registers | 32 × 32-bit, `x0` hardwired zero, odd parity per word |
| Endianness | little |
| Misaligned access | **traps** — no hardware fixup (§4.2) |
| Compressed (C) | **not implemented** — a 16-bit encoding is an illegal instruction |
| Atomics (A), float (F/D) | not implemented |

Because there is no U mode, there is no privilege boundary inside the
subsystem: all code runs with full access to every register. Isolation,
if you need it, is a software-architecture problem, not something the
hardware will enforce.

### 1.1 Toolchain

```sh
riscv32-unknown-elf-gcc -march=rv32im_zicsr_zifencei -mabi=ilp32 \
    -mno-relax -nostdlib -nostartfiles -T link.ld -o app.elf app.c start.S
```

`-mno-relax` is not cosmetic. Linker relaxation combined with the
`.option rvc` blocks in some third-party sources leaves 16-bit `c.nop`
padding in the executed stream, and this core traps on any 16-bit
encoding (finding V36). If you see an illegal-instruction trap at an
address that disassembles as `.insn 2`, this is why.

Memory image: `scripts/mkimage.py` turns a binary into the 39-bit
ECC-encoded words the TCMs expect. Loading a raw binary directly into
the arrays produces uncorrectable ECC errors on the first fetch.

### 1.2 Memory map

| Range | Contents |
|-------|----------|
| `0x0000_0000` | I-TCM — instruction fetch **and** data reads |
| `0x1000_0000` | D-TCM |
| `0x2000_0000` | peripherals, sixteen 256-byte slots (§5) |
| anything else | bus error → load/store access fault |

Both TCMs are SEC-DED protected: single-bit errors are corrected
transparently and reported; double-bit errors raise an access fault at
the instruction that touched them.

## 2. Performance model

Straight-line integer code retires **one instruction per cycle**. The
costs that matter for a worst-case execution time budget:

| Operation | Cost |
|-----------|------|
| ALU, load, store (aligned, hit) | 1 cycle |
| Taken branch / jump | + pipeline refill |
| `mul`, `div`, `rem` | **33 cycles**, constant — no early exit |
| Partial-word store (`sb`, `sh`) | 2 cycles — read-modify-write for the ECC code word |
| CSR access | 1 cycle |

Two consequences worth designing around: the multiplier/divider is
constant-time, so its cost is predictable but never cheap, and byte or
halfword stores cost double what word stores do because the ECC check
bits cover the whole word. Prefer word-aligned structures in hot paths.

`mcycle`/`minstret` (and their read-only `cycle`/`instret` shadows) are
64-bit and free-running; read the high word, the low word, then the
high word again and retry if it changed.

## 3. Startup

The ordering constraints are in [integration.md](integration.md) §5;
`tb/sw/start.S` is a worked example. The parts that surprise people:

1. **Run the memory BIST, or write every TCM word yourself.** This is
   not only a test: the BIST writes every location, and the prefetcher
   will fetch past the end of your program. An unwritten word is an
   arbitrary code word and will most likely raise an uncorrectable ECC
   error. Set `MbistAuto` or drive slot 5 (§5.6).
2. **Zero every architectural register before enabling lockstep.** The
   two cores must start from identical state or the comparator will
   flag a mismatch that never happened. Write all 31 registers.
3. Configure the safety mechanisms, then **lock them** (§5.1, §5.2).
4. Set `mtvec`, enable only the interrupts you handle, enter the
   control loop.

## 4. Traps

### 4.1 Model

`mtvec` supports direct (bit 0 = 0, all traps to `BASE`) and vectored
(bit 0 = 1, interrupts to `BASE + 4 × cause`) mode. On a trap the core
writes `mepc`, `mcause`, `mtval`, copies `MIE` to `MPIE` and clears
`MIE`; `mret` reverses it. There is no trap nesting in hardware — if
you want it, re-enable `MIE` in the handler after saving state.

Interrupts are taken at instruction boundaries only.

### 4.2 Causes

| `mcause` | Cause | `mtval` |
|---|---|---|
| 0 | instruction address misaligned | target address |
| 1 | instruction access fault (bus error, or uncorrectable ECC on fetch) | address |
| 2 | illegal instruction | the instruction word |
| 3 | breakpoint (`ebreak`) | — |
| 4 / 6 | load / store address misaligned | the address |
| 5 / 7 | load / store access fault | the address |
| 11 | environment call (`ecall`) | — |
| 0x8000_0003 / 7 / B | software / timer / external interrupt | — |

**Misaligned accesses trap.** There is no hardware fixup: a word load
from an address with either low bit set, or a halfword load from an odd
address, raises cause 4. If your code can generate them, either fix the
alignment or emulate in the handler.

### 4.3 A minimal handler

```asm
    .align 6                    # mtvec needs 64-byte alignment here
trap_entry:
    csrrw  sp, mscratch, sp     # swap in the handler stack
    addi   sp, sp, -64
    sw     ra, 0(sp)
    # ... save what you clobber ...
    csrr   t0, mcause
    bltz   t0, interrupt        # high bit set => interrupt
    # exception: t0 is the cause, mepc points at the faulting insn
    csrr   t1, mepc
    addi   t1, t1, 4            # skip it, if that is your policy
    csrw   mepc, t1
1:  # ... restore ...
    csrrw  sp, mscratch, sp
    mret
```

## 5. Peripherals

Every peripheral lives in a 256-byte slot at `0x2000_0000 + slot×0x100`
and is accessed with ordinary word loads and stores. Unused slots and
unmapped offsets raise a bus error, which is deliberate: a stray
pointer into peripheral space traps rather than silently reading zero.

### 5.1 Safety controller (slot 0) — the one you must get right

Every fault in the subsystem ends here as a sticky bit in `STATUS`,
with a configurable reaction (`REACT_IRQ`, `REACT_RST`, `REACT_PIN`).
Configure it, then set `CTRL.lock` so a runaway program cannot switch
the safety reactions off. The lock survives until reset.

**`STATUS` bit 13 — configuration parity — is different, and it is the
one bit your handler must implement.** Every configuration register
group in the subsystem carries a hardware parity bit. A mismatch
latches bit 13 **ungated**: it raises the safety interrupt and asserts
the error pin regardless of `ENABLE`, `CTRL.enable` and `REACT_*`,
because those are precisely the registers a fault may have corrupted.

```c
void safety_isr(void) {
    uint32_t st = SAFETY->STATUS;
    if (st & (1u << 13)) {                 /* configuration parity */
        uint32_t src = SAFETY->CFG_SRC;    /* which group (0x28)   */
        reprogram_group(src);              /* rewrite it: this also
                                              rebaselines its parity */
        SAFETY->STATUS = (1u << 13);       /* W1C, after the rewrite */
    }
    /* ... other sources ... */
}
```

Rewriting the group *before* clearing the bit matters: clearing first
leaves the corruption in place and the bit simply sets again.

Without this mechanism, 46.4 % of configuration upsets were latent — a
safety mechanism silently disabled while the program kept producing
correct answers. With it, zero of 2 600 (findings V29/V37).

`SELFTEST` and `INJECT` let software prove the detection paths work
in-mission: force a lockstep mismatch, corrupt a TCM code word, or
pulse a fault bit. Writing `SELFTEST` *arms* a TCM corruption which the
next write to that memory applies — it cannot be same-cycle, because
the write you want to corrupt is necessarily several cycles after the
APB access that arms it.

### 5.2 Watchdog (slot 1)

Windowed: servicing too early is as much a fault as not servicing at
all. Service with the two-key sequence (`KEY_A` then `KEY_B` to
`SERVICE`); any other value, or `KEY_B` out of window, is a bad-service
fault. Configure `PERIOD` and `WINDOW`, then set `CTRL.lock`.

**Service it from exactly one place in your control loop.** Servicing
from an interrupt handler defeats the purpose — the loop can be dead
while the timer interrupt still runs.

### 5.3 Machine timer (slot 2)

64-bit `mtime` with a prescaler, and `mtimecmp`; `mtime >= mtimecmp`
raises the machine timer interrupt. Write the high word first when
setting a new deadline to avoid a spurious match. `mtimecmp` is
parity-protected (§5.1).

### 5.4 Clock monitor (slot 3)

Counts `clk_i` edges against an independent reference clock and faults
if the ratio leaves `[MIN, MAX]`. Configure the window, then enable —
enabling first can latch a spurious fault from the partial first
measurement. Choose the window from the real ratio with margin for both
oscillators' tolerance; too tight and it trips on nothing.

### 5.5 AMS interface (slot 4)

Sequences ADC conversions over the channels in `CHMASK`, compares each
result against per-channel `LIM_LO`/`LIM_HI`, and raises a range fault
outside them. One-shot or continuous (`CTRL.cont`). `STATUS` carries
done, timeout and per-channel range bits. The DAC/trim output has a
write strobe. Limits and channel mask are parity-protected.

### 5.6 Memory BIST (slot 5)

March C- over each TCM, I-TCM at `+0x00` and D-TCM at `+0x40`. Start,
poll `STATUS.done`, check `STATUS.fail`; `FAILADR`/`FAILDAT` localise a
failure. **Running it destroys memory contents** — run it before
loading anything you care about. Note the slot's two controllers each
claim 16 bytes, and offsets belonging to neither raise a bus error.

### 5.7 Interrupt controller (slot 6)

`NumSrc` SoC lines, each edge or level (`MODE`), with `ENABLE`,
sticky-for-edge `PENDING`, and a `CLAIM` register giving the
lowest-numbered active source. Level sources follow their input; edge
sources stay set until written back to `PENDING`. `ENABLE` and `MODE`
are parity-protected. There is also a software interrupt doorbell
(`MSIP`).

## 6. Core-local safety CSRs

| CSR | Address | Access | Contents |
|-----|---------|--------|----------|
| `msafestat` | `0x7c0` | RW1C | [0] register-file parity error, [1] illegal-instruction trap, [2] bus-error trap, [3] lockstep alert |
| `msafectrl` | `0x7c1` | RW | [0] fault output enable, [1] software fault trigger (self-clearing) |

`msafestat` accumulates core-local events even when the corresponding
trap is handled and forgotten — read it periodically if you want to
know that a register-file parity error was corrected under you.

Writing `msafectrl[1]` raises a software fault into the safety
controller. That is the intended way for software that detects a
problem of its own — a failed plausibility check, a corrupted data
structure — to enter the same reaction machinery as a hardware fault.

**One caveat with teeth**: if the fault you are reporting is that the
safety controller's own configuration is corrupt, the report may have
nowhere to go — the register the fault disabled is the one that would
record it. That is exactly why configuration parity latches ungated
(§5.1), and why an integrator is told to route the error pin outside
this subsystem's failure domain.

## 7. Idioms worth knowing

**Reading a 64-bit counter safely.**

```c
static uint64_t read_mcycle(void) {
    uint32_t hi, lo, hi2;
    do { hi  = csr_read(mcycleh);
         lo  = csr_read(mcycle);
         hi2 = csr_read(mcycleh);
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}
```

**Self-modifying code and loaded images.** After writing instructions
to the I-TCM — a bootloader, a patch — execute `fence.i` before jumping
to them. Without it the prefetch buffer may still hold stale words.

**Word-aligned data structures.** Byte and halfword stores cost two
cycles (§2); in a hot loop that is a doubling worth avoiding.

**Checking a configuration you did not write.** After any reset that is
not a cold reset, the safety status survives by design. Read `STATUS`
early in startup and decide deliberately whether the previous fault
matters; do not clear it reflexively.

## 8. Worked example: minimal safe main

```c
int main(void) {
    bist_run_and_check();            /* §3 step 1  */
    zero_all_registers();            /* §3 step 2, in asm before this */

    CLKMON->MIN = min_ratio;         /* §5.4: window, then enable */
    CLKMON->MAX = max_ratio;
    CLKMON->CTRL = CLKMON_ENABLE;

    SAFETY->ENABLE    = 0xffffffff;  /* §5.1: all sources count */
    SAFETY->REACT_IRQ = 0xffffffff;
    SAFETY->REACT_PIN = 0xffffffff;
    SAFETY->CTRL      = SAFETY_ENABLE | SAFETY_LOCK;

    WDOG->PERIOD = period;           /* §5.2 */
    WDOG->WINDOW = window;
    WDOG->CTRL   = WDOG_ENABLE | WDOG_WINDOW_MODE | WDOG_LOCK;

    csr_write(mtvec, (uint32_t)trap_entry);
    csr_write(mie, MIE_MEIE | MIE_MTIE);
    csr_set(mstatus, MSTATUS_MIE);

    for (;;) {
        do_control_work();
        wdog_service();              /* exactly one call site */
    }
}
```

## 9. What software cannot do

* **Reach a mechanism that is off.** Locked configuration stays locked
  until reset — by design; that is what stops a runaway program
  disarming the safety case.
* **Test everything from software.** Some paths are unreachable from
  software by construction: a reset-request reaction resets the core
  that would observe it. Those are covered by the bench
  (`verif/safety/tb_safety.sv`), not by firmware.
* **Rely on a mechanism it never checks.** A read-back check covers
  exactly what it reads back — one register left out of a scrub loop
  stayed 100 % latent across a whole campaign (finding V30).
