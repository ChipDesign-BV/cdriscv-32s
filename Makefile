# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# cdriscv-32s -- build entry points.
#
# NONE OF THESE FLOWS HAS BEEN RUN YET.  The RTL in this repository has
# not been compiled, linted, simulated or synthesised; the targets below
# describe how it is meant to be exercised, not a result that has been
# achieved.  See doc/verification_plan.md.

SHELL      := /bin/bash
BUILD      := build
FILELIST   := rtl/cdriscv_files.f
RTL        := $(shell grep -v '^//' $(FILELIST))
TOP        := cdriscv_subsys
TB         := tb/tb_cdriscv_subsys.sv
TB_TOP     := tb_cdriscv_subsys

VERILATOR  ?= verilator
IVERILOG   ?= iverilog
VVP        ?= vvp
YOSYS      ?= yosys
PYTHON     ?= python3

CROSS      ?= riscv64-unknown-elf-
CC         := $(CROSS)gcc
OBJCOPY    := $(CROSS)objcopy
OBJDUMP    := $(CROSS)objdump
ARCH       := rv32im_zicsr_zifencei
ABI        := ilp32

.PHONY: all lint lint-tb sim sw synth ecc clean block block-alu block-ecc cosim cosim-random

all: lint

# ---------------------------------------------------------------- lint
WAIVERS := verif/lint/waivers.vlt

# No -Wno-fatal: a new warning that is not waived in $(WAIVERS) fails
# the build.  Every waiver in that file carries its justification.
lint:
	$(VERILATOR) --lint-only -sv --timing -Wall \
	  --top-module $(TOP) $(WAIVERS) $(RTL)

# The RTL carries no `timescale (the tool default applies); the bench
# does, so the bench lint sets one globally to keep them consistent.
lint-tb:
	$(VERILATOR) --lint-only -sv --timing -Wall --timescale 1ns/1ps \
	  --top-module $(TB_TOP) $(WAIVERS) $(RTL) $(TB)

# ----------------------------------------------------------------- sim
$(BUILD)/$(TB_TOP).vvp: $(RTL) $(TB) | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s $(TB_TOP) $(RTL) $(TB)

sim: $(BUILD)/$(TB_TOP).vvp sw
	$(VVP) $< +ITCM_HEX=$(BUILD)/prog.itcm.hex \
	          +DTCM_HEX=$(BUILD)/prog.dtcm.hex \
	          +TRACE=1

# ------------------------------------------------------------ software
sw: $(BUILD)/prog.itcm.hex $(BUILD)/prog.dtcm.hex

$(BUILD)/prog.elf: tb/sw/start.S tb/sw/link.ld | $(BUILD)
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
	  -T tb/sw/link.ld -o $@ tb/sw/start.S
	$(OBJDUMP) -d $@ > $(BUILD)/prog.dis

$(BUILD)/prog.itcm.bin: $(BUILD)/prog.elf
	$(OBJCOPY) -O binary --only-section=.text $< $@

$(BUILD)/prog.dtcm.bin: $(BUILD)/prog.elf
	$(OBJCOPY) -O binary --only-section=.data $< $@

$(BUILD)/%.hex: $(BUILD)/%.bin
	$(PYTHON) scripts/mkimage.py $< $@

# -------------------------------------------------------- block benches
# Each block bench prints "PASS" or "FAIL"; the recipe greps for the
# verdict so that a failing bench fails make, which vvp itself does not.
ALU_VECTORS := $(BUILD)/alu_vectors.hex
ALU_RANDOM  ?= 20000

$(ALU_VECTORS): verif/block/alu/gen_vectors.py | $(BUILD)
	$(PYTHON) $< $@ $(ALU_RANDOM)

$(BUILD)/tb_alu.vvp: rtl/core/cdriscv_pkg.sv rtl/core/cdriscv_alu.sv \
                     verif/block/alu/tb_alu.sv | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s tb_alu $^

block-alu: $(BUILD)/tb_alu.vvp $(ALU_VECTORS)
	$(VVP) $(BUILD)/tb_alu.vvp +VEC=$(ALU_VECTORS) \
	  +NVEC=$$(wc -l < $(ALU_VECTORS)) | tee $(BUILD)/block_alu.log
	@grep -q "PASS" $(BUILD)/block_alu.log

ECC_PATTERNS ?= 200

$(BUILD)/tb_ecc.vvp: rtl/core/cdriscv_pkg.sv rtl/safety/cdriscv_ecc_secded.sv \
                     verif/block/ecc/tb_ecc.sv | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s tb_ecc $^

block-ecc: $(BUILD)/tb_ecc.vvp
	$(VVP) $(BUILD)/tb_ecc.vvp +PATTERNS=$(ECC_PATTERNS) | tee $(BUILD)/block_ecc.log
	@grep -q "PASS" $(BUILD)/block_ecc.log

block: block-alu block-ecc

# ------------------------------------------------- core co-simulation
# Runs one program on Spike and on the RTL and compares the retired
# instruction streams.  SPIKE can be overridden; the default is where
# scripts/build_spike.sh installs it.
SPIKE      ?= /headless/verif-tools/spike/bin/spike
COSIM_ARCH := rv32im_zicsr_zifencei
COSIM_SRC  := verif/core/cosim_isa.S
COSIM_LD   := verif/core/link_cosim.ld

$(BUILD)/cosim_isa.elf: $(COSIM_SRC) $(COSIM_LD) | $(BUILD)
	$(CC) -march=$(COSIM_ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
	  -T $(COSIM_LD) -o $@ $(COSIM_SRC)
	$(OBJDUMP) -d $@ > $(BUILD)/cosim_isa.dis

$(BUILD)/cosim_isa.hex: $(BUILD)/cosim_isa.elf
	$(OBJCOPY) -O binary $< $(BUILD)/cosim_isa.bin
	$(PYTHON) scripts/mkimage.py $(BUILD)/cosim_isa.bin $@

$(BUILD)/tb_cosim.vvp: $(RTL) verif/core/tb_cosim.sv | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s tb_cosim $(RTL) verif/core/tb_cosim.sv

RANDOM_SEEDS ?= 50
RANDOM_LEN   ?= 400

# Random program regression against Spike.  Failing seeds are kept in
# build/random and the runner prints the command to reproduce one.
cosim-random: $(BUILD)/tb_cosim.vvp
	SPIKE=$(SPIKE) VVP=$(VVP) $(PYTHON) verif/core/random_regress.py \
	  --seeds $(RANDOM_SEEDS) --count $(RANDOM_LEN)

cosim: $(BUILD)/tb_cosim.vvp $(BUILD)/cosim_isa.hex
	SPIKE=$(SPIKE) VVP=$(VVP) $(PYTHON) verif/core/cosim.py \
	  $(BUILD)/cosim_isa.elf --hex $(BUILD)/cosim_isa.hex --count 5000

# ---------------------------------------------------------------- ecc
ecc:
	$(PYTHON) scripts/gen_secded.py

# --------------------------------------------------------------- synth
synth: | $(BUILD)
	$(YOSYS) -p "read_verilog -sv $(RTL); \
	             hierarchy -top $(TOP); \
	             synth -top $(TOP); \
	             stat" -l $(BUILD)/synth.log

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD) obj_dir *.vcd
