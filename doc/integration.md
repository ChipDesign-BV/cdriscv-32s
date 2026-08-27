# cdriscv-32s integration manual

Everything an SoC team needs to instantiate, constrain, harden, boot
and sign off this subsystem. Companion documents, referenced rather
than repeated: [architecture.md](architecture.md) for how it works,
[register_map.md](register_map.md) for every register bit,
[safety_manual.md](safety_manual.md) for the safety argument and
assumptions of use, [fmeda.md](fmeda.md) for the metrics.

**Status.** Verified to the O1–O9 objectives of
[verification_plan.md](verification_plan.md); may be used in a project.
**Not qualified for safety-critical use** — that needs foundry failure
rates, common-cause analysis and an assessed safety case, per the
FMEDA's handoff checklist. No compliance with any functional safety
standard is claimed.

## 0. Deliverables and integration checklist

### 0.1 What you receive

| Item | Path | Note |
|------|------|------|
| RTL | `rtl/`, read order in `rtl/cdriscv_files.f` | SystemVerilog-2017; needs a slang-class front end (see §7.1) |
| Hardening flow | `flow/` | LibreLane 3 config and hardening wrapper, IHP SG13G2 |
| Timing constraints | `verif/sta/cdriscv_subsys.sdc` | three-corner, see §8 |
| Verification suite | `verif/`, `Makefile` | 40+ targets; `make lint sim block cosim riscof formal coverage fi gate` |
| Boot example | `tb/sw/start.S` | register zeroing, BIST, safety configuration |
| Evidence | `doc/verification_findings.md` | V0–V45, every number's provenance |

### 0.2 Integration checklist

Work top to bottom; each item names the section that explains it.

- [ ] `boot_addr_i` tied to a **constant** at SoC level — §9.1, not optional
- [ ] `ref_clk_i` driven from an oscillator **physically independent** of `clk_i` — §2, AoU-1
- [ ] Synchroniser inputs constrained false-path / max-delay; flop chains protected from retiming and merging — §2
- [ ] `rst_ni` asynchronous assert, synchronous release preserved; `boot_addr_i` stable while low — §3
- [ ] TCM behavioural arrays replaced by compiled RAM macros, `bist_*` port kept on raw storage — §4
- [ ] `err_pin_o` routed to something outside this subsystem's failure domain — §6.2
- [ ] Safety-controller reactions configured and `CTRL.lock` set during boot — §5
- [ ] Watchdog serviced from exactly one place in the control loop — §5
- [ ] STATUS bit 13 handler implemented (configuration parity) — §6.1
- [ ] Interrupt and fault input widths matched, unused inputs tied low — §1
- [ ] DFT strategy chosen: scan insertion is **not** included — §7.3
- [ ] Timing signed off at the **slow** corner, not just typical — §8.2

## 1. Top level ports (`cdriscv_subsys`)

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk_i` | in | 1 | system clock |
| `rst_ni` | in | 1 | asynchronous active low reset, synchronised internally |
| `ref_clk_i` | in | 1 | independent reference clock for the clock monitor |
| `ref_rst_ni` | in | 1 | reset for the reference domain |
| `boot_addr_i` | in | 32 | reset vector, must be stable during reset |
| `fetch_enable_i` | in | 1 | release the core |
| `irq_i` | in | 14 | SoC interrupt lines, asynchronous, synchronised internally |
| `fault_ext_i` | in | 16 | SoC fault inputs, asynchronous, synchronised internally |
| `err_pin_o` | out | 1 | external error signal, level or toggle protocol |
| `reset_req_o` | out | 1 | high while the internal warm reset is active |
| `fault_any_o` | out | 1 | any fault latched in the safety controller |
| `adc_start_o` | out | 1 | one cycle conversion start |
| `adc_ch_o` | out | 3 | channel for the conversion being started |
| `adc_valid_i` | in | 1 | conversion result valid |
| `adc_data_i` | in | 12 | conversion result |
| `dac_data_o` | out | 12 | trim / DAC output value |
| `dac_we_o` | out | 1 | strobe, one cycle after a write to `DAC` |
| `atest_en_o` | out | 1 | analog test bus enable |
| `atest_sel_o` | out | 4 | analog test bus selection |
| `ana_flag_i` | in | 4 | analog comparator / supervisor flags, asynchronous |
| `ext_p*` | in/out | | APB3 expansion port, peripheral slot 15 |
| `core_sleep_o` | out | 1 | core is in WFI |
| `retire_valid_o`, `retire_pc_o`, `retire_instr_o` | out | 1, 32, 32 | retire trace, for debug and for an external monitor |

## 2. Clocking

* `clk_i` — everything except the measurement part of the clock monitor.
* `ref_clk_i` — the measurement part of the clock monitor only. It must
  come from an oscillator independent of `clk_i` (see AoU-1).

Crossings, all inside `cdriscv_clkmon` and the input synchronisers:

| Signal | From | To | Structure |
|--------|------|----|-----------|
| heartbeat toggle | `clk_i` | `ref_clk_i` | 2 flop level synchroniser |
| enable | `clk_i` | `ref_clk_i` | 2 flop, quasi-static |
| `MIN`, `MAX` | `clk_i` | `ref_clk_i` | quasi-static, write while disabled |
| status clear pulse | `clk_i` | `ref_clk_i` | toggle pulse synchroniser |
| fault level | `ref_clk_i` | `clk_i` | 2 flop level synchroniser |
| result toggle + value | `ref_clk_i` | `clk_i` | toggle synchroniser, value captured after |
| `irq_i`, `fault_ext_i`, `ana_flag_i` | async | `clk_i` | 2 flop level synchroniser |

Constrain the synchroniser inputs as false paths (or with a maximum
delay equal to one destination period) and keep the flop chains from
being retimed or merged.

## 3. Reset

`rst_ni` is asynchronously asserted and synchronously released by
`cdriscv_rst_sync`. `boot_addr_i` must be stable while `rst_ni` is low.

The warm reset (`WarmRstLen` cycles) restarts the core, the lockstep
pair, the bus and the APB bridge. It does not reset the peripherals, so
the safety status survives a warm reset; software must clear it.

## 4. Memories

`cdriscv_tcm` describes its storage behaviourally, as a `logic [38:0]`
array. For an ASIC flow, replace the array with a compiled 39-bit wide
single port RAM (or a 32-bit and a 7-bit instance) with the same timing:
synchronous read with one cycle latency, write in the same cycle as the
address. Keep the `bist_*` port connected to the raw storage; that is
what makes the check bits testable.

## 5. Software boot sequence

1. Run the memory BIST (or configure `MbistAuto`) and check
   `STATUS.fail` for both TCMs. Treat this as mandatory rather than
   optional: besides testing the array it writes every word, and the
   prefetcher will fetch past the end of the program into whatever
   follows it. An unwritten word is an arbitrary code word, and the ECC
   check on it will most likely report an uncorrectable error. If the
   BIST is skipped, the loader must write every TCM word instead.
2. Load or verify the application image in the I-TCM.
3. Zero all architectural registers before enabling the lockstep
   comparison (the example in `tb/sw/start.S` does this) so that the two
   cores start from the same state.
4. Configure the clock monitor `MIN`/`MAX`, then enable it.
5. Configure the safety controller reactions and set `CTRL.lock`.
6. Configure the watchdog `PERIOD`/`WINDOW` and set `CTRL.lock`.
7. Set `mtvec`, enable the interrupts that are needed, enter the control
   loop and service the watchdog from one well defined place in it.

Every configuration group written above is parity-protected from the
moment it is written; the handler that goes with that is §6.1.
Periodic software re-reads (finding V30) are no longer needed for
single-bit detection, but remain the only mechanism that catches a
double-bit upset inside one group, so they stay worthwhile as defence
in depth.

## 6. Safety integration

### 6.1 The one interrupt you must handle

Safety controller `STATUS` bit 13 is **configuration parity**, and it
is deliberately not maskable: a mismatch latches the bit, raises the
safety interrupt and asserts the error pin regardless of `ENABLE`,
`CTRL.enable` and `REACT_*` — because those are exactly the registers
a fault may have corrupted. `CFG_SRC` (0x28) names the offending
group. **Handler**: read `CFG_SRC`, rewrite that group's configuration
(which rebaselines its parity), then W1C bit 13.

Without this mechanism 46.4 % of configuration upsets were latent — a
mechanism silently disabled while the program kept producing correct
answers. With it, zero of 2 600. See findings V29/V37.

### 6.2 The error pin is the escape hatch

`err_pin_o` must reach something **outside this subsystem's failure
domain** — an external supervisor, a safe-state actuator, a system
watchdog. Two modes: level (asserted on fault) and toggle (square wave
while healthy, stops on fault), and toggle is the one that also
survives the subsystem dying entirely, including a stuck-at fault on
the pin itself.

### 6.3 Assumptions of use

The full list is in [safety_manual.md](safety_manual.md). The three
that most often get missed:

* **AoU-1** — `ref_clk_i` from an independent oscillator. A shared PLL
  makes the clock monitor blind to the failure it exists to catch.
* **AoU-2** — the lockstep pair shares clock, reset and supply.
  Common-cause analysis for those is the integrator's, and it is
  outside what fault injection can measure.
* **AoU-3** — memory BIST at every power-up, not merely at production
  test; it is also what initialises the ECC check bits (§5, step 1).

## 7. Implementation

### 7.1 Front end

The RTL uses packages, `always_ff`/`always_comb`, interfaces-free
module ports and SystemVerilog assertions in the benches. Yosys' native
Verilog front end **cannot** parse it — `import cdriscv_pkg::*` is
rejected. Use yosys with the slang plugin (`read_slang`), or any
commercial elaborator. In LibreLane set `USE_SLANG: true`; the flow in
`flow/` does.

### 7.2 Parameters

| Parameter | Default | Note |
|-----------|---------|------|
| `Lockstep` | 1 | dual-core lockstep; 0 removes the checker core and its comparator |
| `LockstepDly` | 2 | delay in cycles between main and checker core |
| `ItcmWords`, `DtcmWords` | 4096 | 39-bit words including ECC |
| `RfParity` | 1 | register file parity |
| `MbistAuto` | 0 | run BIST automatically out of reset |
| `WarmRstLen` | — | warm reset duration in cycles |

Set them at instantiation. Note that a gate-level netlist is one
*configuration* — parameters are resolved by synthesis — so a bench
running on the netlist must not re-override them.

### 7.3 DFT

**Scan insertion is not included.** The design has no scan chains, no
test-mode port and no compression. If you need structural test, insert
scan in your own flow after synthesis; the memory BIST covers the
arrays but nothing covers the logic.

Existing test hooks, all software-driven and intended for in-mission
self test rather than manufacturing: `SELFTEST` (forces a lockstep
mismatch, corrupts a TCM code word), `INJECT` (pulses fault bits), and
the March C- memory BIST.

## 8. Physical integration

Numbers below are from the RTL2GDS run described in the README; see
`flow/config.json` for the exact configuration.

### 8.1 Floorplan

Four SRAM macros (`RM_IHPSG13_1P_2048x64_c2_bm_bist`, 784 × 627 µm
each — two per TCM, bank select on address bit 11) placed at the die
corners with 10 µm halos, standard cells in the central cross. The
reference run uses a 2.9 × 2.9 mm die at 36 % utilisation, which is
deliberately roomy; a tighter floorplan is available and untried.

Each macro needs **three** supply connections — `VDD!`, `VSS!` and the
array supply **`VDDARRAY!`**. Missing the third is silent until a
post-route disconnected-pin check catches it.

### 8.2 Timing — sign off at the slow corner

The design is constrained at **40 ns (25 MHz)**. That number has
history worth heeding: the first hardening run met 20 ns at the
typical corner and missed it **by 9 ns at slow (1.08 V, 125 °C)**,
where 3 636 register-to-register paths failed. A single-corner
analysis had reported the design "closed" (finding V45).

**Sign off setup at slow, hold at fast, and check typical too.** All
three corners are in `verif/sta/cdriscv_subsys.sdc` and in the
`make fmax` script.

**Hold at the fast corner is an open item.** The reference run leaves
15 paths violating, worst −0.40 ns at 1.32 V / −40 °C. Setup is clean
at all three corners. Closing hold needs a post-route repair pass that
the reference flow does not run, or an explicit lower bound on
operating voltage and temperature in the product specification.
Whoever hardens this for silicon must resolve it — a hold violation is
a functional failure, not a speed limit.

Both clocks are genuinely asynchronous; `set_clock_groups -asynchronous`
between `clk` and `ref_clk` is correct rather than convenient.

### 8.3 Constants

Synthesis emits named constant nets (`one_`/`zero_`) that need tie
cells. Insert them (`insert_tiecells` in OpenROAD, or your flow's
equivalent) — without it every constant in the design is undriven, and
in simulation the reset synchroniser's data input is X and the netlist
is dead on arrival (finding V42).

## 9. Known constraints

### 9.1 `boot_addr_i` must be tied to a constant

Not a recommendation: `fetch_pc_q` resets to `boot_addr_i`, and a
flip-flop whose reset loads a data value has no standard cell
equivalent. Tie the port to a constant at the SoC level and every flop
maps; drive it from a register and the program counter cannot be
synthesised. Synthesising the subsystem standalone, with `boot_addr_i`
left as a port, leaves 64 flops unmapped — see finding V18.
`flow/cdriscv_subsys_hard.sv` is the wrapper that does this for the
reference hardening run.

### 9.2 Performance

Straight-line code retires one instruction per cycle; every taken
branch, jump and load costs extra cycles. At 25 MHz worst case, budget
accordingly — this is a safety-oriented subsystem, not a
throughput-oriented one.

### 9.3 Warm reset does not clear the safety status

By design: the status survives so software can see what happened.
Software must clear it explicitly after reading.

## 10. Verifying your integration

After instantiating, re-run at least:

```sh
make lint          # structural: latches, loops, multiply-driven nets
make sim sw        # boots and runs the smoke program
make cosim         # agreement with the golden model
make safety        # every mechanism fires, and stays quiet when it should
make rdback        # every register reads back what it should
```

If you changed parameters, also `make riscof` (architectural
conformance) and `make fi` (fault injection) — both are sensitive to
configuration in ways directed tests are not.

## 11. Files

| Path | Contents |
|------|----------|
| `rtl/cdriscv_files.f` | read order for Verilator, iverilog and yosys |
| `rtl/core/` | core |
| `rtl/safety/` | lockstep, ECC, safety controller, watchdog, clock monitor, BIST |
| `rtl/bus/` | interconnect, TCM, APB bridge |
| `rtl/periph/` | timer, interrupt controller, AMS interface |
| `rtl/common/` | synchronisers, configuration parity, 64-bit counters |
| `flow/` | LibreLane 3 hardening flow and its wrapper |
| `scripts/gen_secded.py` | generates the ECC RTL |
| `scripts/mkimage.py` | builds a 39-bit memory image from a binary |
