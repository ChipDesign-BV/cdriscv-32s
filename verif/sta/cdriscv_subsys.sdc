# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# Timing constraints for cdriscv_subsys.
#
# Two clocks, and they are genuinely asynchronous.  The clock monitor
# exists precisely because the reference oscillator is independent of
# the system clock, and every signal that crosses between them goes
# through the synchronisers in cdriscv_sync.sv.  Declaring them
# asynchronous is therefore correct rather than a convenience: analysing
# those paths as if they were related would produce violations that mean
# nothing and hide the ones that do.

# 20 ns: the integration target was reduced from 100 MHz to 50 MHz on
# 2026-08-24.  The placed-and-buffered netlist runs at 81 MHz (V39), so
# this closes with 3.7 ns of margin on the worst internal path.
set period_sys 20.0
set period_ref 1000.0

create_clock -name clk     -period $period_sys [get_ports clk_i]
create_clock -name ref_clk -period $period_ref [get_ports ref_clk_i]

set_clock_groups -asynchronous \
  -group [get_clocks clk] \
  -group [get_clocks ref_clk]

# Resets are asynchronous in assertion and synchronised in release
# (finding V7-F2), so they are not timed as data.
set_false_path -from [get_ports rst_ni]
set_false_path -from [get_ports ref_rst_ni]

# Everything else at the boundary: a conventional 30 % of the period
# budgeted outside the block, which is a placeholder until the SoC
# says otherwise.
# `remove_from_collection` is not in this OpenSTA build, so the clock
# and reset ports are filtered by name.  Leaving them in raises
# "set_input_delay relative to a clock defined on the same port", which
# is a warning worth not having rather than one worth ignoring.
set io_budget [expr {$period_sys * 0.3}]
set skip {clk_i ref_clk_i rst_ni ref_rst_ni}
foreach p [all_inputs] {
  set n [get_full_name $p]
  if {[lsearch -exact $skip $n] < 0} {
    set_input_delay -clock clk $io_budget $p
  }
}
set_output_delay -clock clk $io_budget [all_outputs]

# No layout, so no real load model.  A fixed fanout load keeps the
# numbers honest about being pre-layout rather than pretending to a
# precision they do not have.
set_load 0.05 [all_outputs]
set_max_fanout 16 [current_design]
