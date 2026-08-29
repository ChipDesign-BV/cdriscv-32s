#!/usr/bin/env klayout -b -r
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# Render a GDS to PNG, headless, with the PDK's own layer colours.
#
#   klayout -b -r scripts/render_gds.py -rd gds=<in.gds> -rd png=<out.png> \
#           [-rd width=1600] [-rd lyp=<file.lyp>] [-rd white=1]
#
# Why a script rather than a one-liner: the die plot in the integration
# manual was produced ad hoc the first time and could not be reproduced
# when the floorplan changed.  A figure nobody can regenerate is a figure
# that quietly goes stale, so this lives beside the flow it illustrates.
#
# `-b` is batch mode: no GUI, no X server, no Xvfb.  LayoutView still
# rasterises because KLayout carries its own renderer.

import pya
import os

gds   = globals().get("gds")
png   = globals().get("png", "die.png")
width = int(globals().get("width", 1600))
lyp   = globals().get(
    "lyp", "/foss/pdks/ihp-sg13g2/libs.tech/klayout/tech/sg13g2.lyp")
white = str(globals().get("white", "0")) not in ("0", "", "false", "False")

if gds is None or not os.path.exists(gds):
    raise SystemExit("need -rd gds=<file>; got %r" % gds)

view = pya.LayoutView()
view.load_layout(gds, 0)
view.max_hier()

if os.path.exists(lyp):
    view.load_layer_props(lyp)
else:
    print("no .lyp at %s -- falling back to KLayout defaults" % lyp)

# A die plot is read for its floorplan, so the frame and grid are noise.
view.show_grid       = False
view.show_texts      = False
view.show_markers    = False

if white:
    # For a printed report: white background, black foreground.  The
    # house template renders figures on white.
    view.set_config("background-color", "#ffffff")
    view.set_config("grid-visible", "false")

view.zoom_fit()

# view.box() is the *viewport*, which KLayout keeps square by default --
# using it gives a square image with the die letterboxed inside.  The
# die's own bounding box is on the cell.
cv   = view.cellview(0)
box  = cv.cell.dbbox()
aspect = box.height() / box.width() if box.width() > 0 else 1.0
height = int(round(width * aspect))

view.save_image_with_options(
    png, width, height,
    0, 0, 0,        # linewidth, oversampling, resolution: 0 = auto
    box,            # target box
    False           # monochrome
)

print("%s  %d x %d px  (die %.1f x %.1f um)"
      % (png, width, height, box.width(), box.height()))
