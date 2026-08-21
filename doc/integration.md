# cdriscv-32s integration guide

> **Status: not verified yet — do not use yet.**

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

## 6. Files

| Path | Contents |
|------|----------|
| `rtl/cdriscv_files.f` | read order for Verilator, iverilog and yosys |
| `rtl/core/` | core |
| `rtl/safety/` | lockstep, ECC, safety controller, watchdog, clock monitor, BIST |
| `rtl/bus/` | interconnect, TCM, APB bridge |
| `rtl/periph/` | timer, interrupt controller, AMS interface |
| `rtl/common/` | synchronisers |
| `scripts/gen_secded.py` | generates the ECC RTL |
| `scripts/mkimage.py` | builds a 39-bit memory image from a binary |

## boot_addr_i must be tied to a constant

Not a recommendation: `fetch_pc_q` resets to `boot_addr_i`, and a
flip-flop whose reset loads a data value has no standard cell
equivalent. Tie the port to a constant at the SoC level and every flop
maps; drive it from a register and the program counter cannot be
synthesised. Synthesising the subsystem standalone, with `boot_addr_i`
left as a port, leaves 64 flops unmapped — see finding V18.
