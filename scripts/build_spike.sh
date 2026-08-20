#!/bin/sh
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# Builds the Spike reference model used by the co-simulation.
#
#   sh scripts/build_spike.sh [prefix]
#
# Default prefix is /headless/verif-tools/spike, which is where the
# Makefile's SPIKE variable looks.  Override SPIKE when running make if
# you install it elsewhere:
#
#   make cosim SPIKE=/usr/local/bin/spike

set -e

PREFIX="${1:-/headless/verif-tools/spike}"
SRC="$(dirname "$PREFIX")/spike-src"

mkdir -p "$(dirname "$PREFIX")"

if [ ! -d "$SRC" ]; then
    git clone --depth 1 https://github.com/riscv-software-src/riscv-isa-sim.git "$SRC"
fi

mkdir -p "$SRC/build"
cd "$SRC/build"
../configure --prefix="$PREFIX"
make -j"$(nproc)"
make install

"$PREFIX/bin/spike" --help 2>&1 | head -1
echo "spike installed in $PREFIX"
