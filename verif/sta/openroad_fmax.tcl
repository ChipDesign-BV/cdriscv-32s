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

# THREE corners, not one.  Reading only the typical library is what
# made this script report "closed at 50 MHz" for a design that missed
# its constraint by 9 ns at the slow corner (finding V45).  The slow
# corner is the binding one for setup; keep it first so a careless
# reading of the output sees it first.
define_corners slow typ fast
read_liberty -corner slow $pdk/lib/sg13g2_stdcell_slow_1p08V_125C.lib
read_liberty -corner slow $sram/lib/RM_IHPSG13_1P_2048x64_c2_bm_bist_slow_1p08V_125C.lib
read_liberty -corner typ  $pdk/lib/sg13g2_stdcell_typ_1p20V_25C.lib
read_liberty -corner typ  $sram/lib/RM_IHPSG13_1P_2048x64_c2_bm_bist_typ_1p20V_25C.lib
read_liberty -corner fast $pdk/lib/sg13g2_stdcell_fast_1p32V_m40C.lib
read_liberty -corner fast $sram/lib/RM_IHPSG13_1P_2048x64_c2_bm_bist_fast_1p32V_m55C.lib

read_verilog $::env(GATE_NETLIST)
link_design cdriscv_subsys

read_sdc verif/sta/cdriscv_subsys.sdc

# Ideal clock stands in for the tree: 250 ps uncertainty covers the
# skew and jitter a real CTS run would introduce.
set_clock_uncertainty 0.25 [all_clocks]

# Internal timing and the IO budget are different questions.  The SDC's
# input/output delays are a placeholder 30 % of the period "until the
# SoC says otherwise"; folding them into one worst-slack number lets a
# placeholder set the headline.  Grouped, each question gets its own
# answer.
group_path -name reg2reg -from [all_registers] -to [all_registers]
group_path -name in2reg  -from [all_inputs]
group_path -name reg2out -to [all_outputs]

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
    -path_group reg2reg -group_path_count 3
puts ""
puts "==== fmax ===="
set period 40.0
foreach grp {reg2reg in2reg reg2out} {
    set paths [find_timing_paths -path_group $grp -sort_by_slack -group_path_count 1]
    if {[llength $paths] == 0} { continue }
    set slk [get_property [lindex $paths 0] slack]
    if {$slk eq ""} { puts "$grp: slack query failed"; continue }
    puts [format "%-8s worst setup slack %+.3f ns -> %.1f MHz" \
        $grp $slk [expr {1000.0 / ($period - $slk)}]]
}
puts "reg2reg is the design's number; in2reg/reg2out carry the SDC's"
puts "placeholder 30 % IO budget and belong to the integration, not the core."

# Constants leave the resizer as named nets (one_/zero_) with nothing
# driving them; simulated as-is the reset synchroniser's D input is X
# and the whole netlist is dead -- found by O8's first annotated run.
# Tie cells give the constants real drivers, for the netlist and for
# the eventual layout alike.
insert_tiecells sg13g2_tiehi/L_HI
insert_tiecells sg13g2_tielo/L_LO

# ---------------------------------------------------------------- O8 handoff
# The repaired netlist and its SDF, for gate-level simulation with real
# delays (verification plan O8).  The netlist written here is NOT the
# input netlist: repair inserted buffers and resized gates, and
# simulating the input netlist against this SDF would annotate cells
# that do not exist.
write_verilog build/gate/cdriscv_subsys_pd_final.v
write_sdf -corner default build/gate/cdriscv_subsys_pd.sdf

exit
