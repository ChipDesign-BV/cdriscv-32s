# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# OpenSTA run for the synthesised subsystem.
#
# PRE-LAYOUT, AND PRE-BUFFERING.  There is no placement, no extracted
# parasitics, and no buffer tree on any high fanout net.  Read the
# setup numbers below with that in mind: they are dominated by the
# reset distribution, which a single flip-flop currently drives into
# a couple of thousand reset pins.  Building that tree is a
# place-and-route job, exactly as clock tree synthesis is, and no
# amount of RTL change makes it unnecessary.
#
# What this run is good for: proving hold is met, showing the fanout
# that has to be fixed, and confirming the logic depth is not the
# problem.  What it cannot give is an Fmax.

read_liberty $env(GATE_LIB)
read_verilog $env(GATE_NETLIST)
link_design cdriscv_subsys
read_sdc verif/sta/cdriscv_subsys.sdc

puts ""
puts "=== hold ==="
report_worst_slack -min -digits 3

puts ""
puts "=== setup, worst register to register ==="
report_checks -path_delay max -digits 3 -path_group clk -group_path_count 1

puts ""
puts "=== fanout and slew violations ==="
report_check_types -max_fanout -max_slew -digits 3 -violators

puts ""
puts "=== summary ==="
report_worst_slack -max -digits 3
report_tns -digits 3
