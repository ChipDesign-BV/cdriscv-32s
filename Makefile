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
ARCH       := rv32im
ABI        := ilp32

.PHONY: all lint sim sw synth ecc clean

all: lint

# ---------------------------------------------------------------- lint
lint:
	$(VERILATOR) --lint-only -sv --timing -Wall \
	  -Wno-fatal \
	  --top-module $(TOP) $(RTL)

lint-tb:
	$(VERILATOR) --lint-only -sv --timing -Wall \
	  -Wno-fatal \
	  --top-module $(TB_TOP) $(RTL) $(TB)

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
