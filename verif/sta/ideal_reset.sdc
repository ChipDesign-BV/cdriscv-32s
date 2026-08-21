# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# Second scenario: the reset distribution is assumed to have a buffer
# tree, as it will after place and route.
#
# This is not a way of making the numbers look better.  The raw run is
# reported first and its verdict stands: as synthesised, one flip-flop
# drives up to 2 201 reset pins and the delay on that net swamps
# everything.  What that number cannot tell you is whether the *logic*
# would meet timing once the tree exists, and that is a different and
# also useful question -- it is the one that says whether the pipeline
# is too deep, which no amount of buffering would fix.
#
# So the four reset nets are cut here, exactly as a clock would be
# treated before clock tree synthesis.  Any path reported after this is
# a path through combinational logic between two flip-flops, with the
# reset tree taken out of the picture.
#
# Note that check_rst_n is not only a reset: the lockstep comparator
# uses it as an enable, so cutting it removes a real data path too.
# That is the honest cost of this scenario and is why both are
# reported.

set_false_path -through [get_nets core_rst_n]
set_false_path -through [get_nets rst_n_sync]
set_false_path -through [get_nets {g_lockstep.u_core.check_rst_n}]
