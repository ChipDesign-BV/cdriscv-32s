# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# cdriscv_subsys -- placed-and-buffered timing estimate (V38).
#
# The plain `make sta` number comes from an unbuffered netlist straight
# out of abc: every net ideal, every fanout free.  That is not an Fmax,
# it is a lower bound on optimism.  This flow floorplans the subsystem
# with its four real SRAM banks, places it, lets the resizer insert
# buffers and resize gates against placement-estimated parasitics, and
# only then asks for slack.  No CTS and no routing: the clock is still
# ideal, held honest by the uncertainty margin below.  The result is a
# pre-layout estimate, stated as such -- but one on a netlist that has
# paid for its wire loads and its fanout.

set pdk   $::env(GATE_PDK)
set sram  $::env(SRAM_PDK)

read_lef $pdk/lef/sg13g2_tech.lef
read_lef $pdk/lef/sg13g2_stdcell.lef
read_lef $sram/lef/RM_IHPSG13_1P_2048x64_c2_bm_bist.lef

read_liberty $pdk/lib/sg13g2_stdcell_typ_1p20V_25C.lib
read_liberty $sram/lib/RM_IHPSG13_1P_2048x64_c2_bm_bist_typ_1p20V_25C.lib

read_verilog $::env(GATE_NETLIST)
link_design cdriscv_subsys

read_sdc verif/sta/cdriscv_subsys.sdc

# Ideal clock stands in for the tree: 250 ps uncertainty covers the
# skew and jitter a real CTS run would introduce.
set_clock_uncertainty 0.25 [all_clocks]

# ---------------------------------------------------------------- floorplan
initialize_floorplan -utilization 45 -aspect_ratio 1.0 \
    -core_space 20 -site CoreSite
make_tracks

place_pins -hor_layers Metal3 -ver_layers Metal2

# The four SRAM banks (two per TCM).
rtl_macro_placer -halo_width 10 -halo_height 10

set_wire_rc -signal -layer Metal2
set_wire_rc -clock  -layer Metal3

# ---------------------------------------------------------------- place
global_placement -density 0.6
estimate_parasitics -placement

# ---------------------------------------------------------------- repair
repair_design
detailed_placement
estimate_parasitics -placement
repair_timing -setup
detailed_placement
estimate_parasitics -placement

# ---------------------------------------------------------------- report
puts "==================== V38 placed-and-buffered timing ===================="
report_design_area
puts ""
report_worst_slack -max
report_tns
puts ""
report_checks -path_delay max -fields {slew cap fanout} -digits 3 \
    -path_group clk -group_path_count 3
puts ""
puts "==== fmax ===="
set period 10.0
set wns [sta::worst_slack -max]
puts [format "period %.2f ns, worst setup slack %+.3f ns" $period $wns]
puts [format "fmax estimate: %.1f MHz (1 / (period - slack), ideal clock + 250 ps uncertainty)" \
    [expr {1000.0 / ($period - $wns)}]]
exit
