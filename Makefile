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

.PHONY: all lint lint-tb sim sw synth ecc clean block block-alu block-ecc block-multdiv safety safety-sw safety-bench periph reaction trap ams regwalk formal formal-if formal-ecc formal-bus formal-dec formal-lsu formal-safety coverage fi cosim cosim-iverilog cosim-stall cosim-random

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

# Images are padded to the full memory depth.  The prefetcher runs past
# the end of the program, and an unwritten TCM word is X in simulation
# and a random code word in silicon -- either way the ECC check on it is
# meaningless.  See finding V4-F2.
TCM_WORDS ?= 4096

$(BUILD)/%.hex: $(BUILD)/%.bin
	$(PYTHON) scripts/mkimage.py $< $@ --words $(TCM_WORDS)

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

MD_VECTORS := $(BUILD)/multdiv_vectors.hex
MD_RANDOM  ?= 300

$(MD_VECTORS): verif/block/multdiv/gen_vectors.py | $(BUILD)
	$(PYTHON) $< $@ $(MD_RANDOM)

$(BUILD)/tb_multdiv.vvp: rtl/core/cdriscv_pkg.sv rtl/core/cdriscv_multdiv.sv \
                         verif/block/multdiv/tb_multdiv.sv | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s tb_multdiv $^

block-multdiv: $(BUILD)/tb_multdiv.vvp $(MD_VECTORS)
	$(VVP) $(BUILD)/tb_multdiv.vvp +VEC=$(MD_VECTORS) \
	  +NVEC=$$(wc -l < $(MD_VECTORS)) | tee $(BUILD)/block_multdiv.log
	@grep -q "PASS" $(BUILD)/block_multdiv.log

block: block-alu block-ecc block-multdiv

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

# Verilator build of the same bench.  About 90 times faster than Icarus
# on this design (0.19 s against 17.8 s for a 200k cycle run), which is
# what makes a co-simulation of any real length affordable.  The lint
# waivers do not apply here because this is a build, not a lint run.
COSIM_RUNNER ?= $(BUILD)/obj_cosim/tb_cosim_vl

$(COSIM_RUNNER): $(RTL) verif/core/tb_cosim.sv | $(BUILD)
	$(VERILATOR) --binary --timing -sv --timescale 1ns/1ps \
	  -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
	  -Wno-SYNCASYNCNET \
	  --top-module tb_cosim -o $(notdir $(COSIM_RUNNER)) \
	  -Mdir $(BUILD)/obj_cosim $(RTL) verif/core/tb_cosim.sv

RANDOM_SEEDS ?= 50
RANDOM_LEN   ?= 400
# Each program's body is wrapped in a bounded outer loop, so a small
# image executes many instructions.  The body is not repeated work: the
# registers carry over, so every iteration starts from a different
# state, and the loop exercises the fetch redirect path hard.
RANDOM_LOOPS ?= 20
# Grants held off on this share of cycles; 0 keeps the memories always
# ready, which is the case every other test already covers.
RANDOM_STALL ?= 0

# Random program regression against Spike.  Failing seeds are kept in
# build/random and the runner prints the command to reproduce one.
# The same comparison with memory grants held off on a third of cycles.
# Back-pressure must change the timing and nothing else, and comparing
# against Spike is what checks that.  It is also the only thing that
# exercises the wait-for-grant paths in the LSU and the fetch stage,
# because the TCM always grants immediately.
COSIM_STALL ?= 35

cosim-stall: $(COSIM_RUNNER) $(BUILD)/cosim_isa.hex
	SPIKE=$(SPIKE) VVP=$(VVP) $(PYTHON) verif/core/cosim.py \
	  $(BUILD)/cosim_isa.elf --hex $(BUILD)/cosim_isa.hex \
	  --vvp $(COSIM_RUNNER) --count 5000 --stall $(COSIM_STALL)

cosim-random: $(COSIM_RUNNER)
	SPIKE=$(SPIKE) VVP=$(VVP) $(PYTHON) verif/core/random_regress.py \
	  --seeds $(RANDOM_SEEDS) --count $(RANDOM_LEN) \
	  --loops $(RANDOM_LOOPS) --stall $(RANDOM_STALL) --vvp $(COSIM_RUNNER)

cosim: $(COSIM_RUNNER) $(BUILD)/cosim_isa.hex
	SPIKE=$(SPIKE) VVP=$(VVP) $(PYTHON) verif/core/cosim.py \
	  $(BUILD)/cosim_isa.elf --hex $(BUILD)/cosim_isa.hex \
	  --vvp $(COSIM_RUNNER) --count 5000

# The same comparison under Icarus, as an independent second opinion on
# the simulator itself.  Slow: use it on the directed program, not on a
# regression.
cosim-iverilog: $(BUILD)/tb_cosim.vvp $(BUILD)/cosim_isa.hex
	SPIKE=$(SPIKE) VVP=$(VVP) $(PYTHON) verif/core/cosim.py \
	  $(BUILD)/cosim_isa.elf --hex $(BUILD)/cosim_isa.hex \
	  --vvp $(BUILD)/tb_cosim.vvp --count 5000

# --------------------------------------------------- register walk
$(BUILD)/regwalk_test.elf: verif/core/regwalk_test.S tb/sw/link.ld | $(BUILD)
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
	  -T tb/sw/link.ld -o $@ verif/core/regwalk_test.S

$(BUILD)/regwalk_test.bin: $(BUILD)/regwalk_test.elf
	$(OBJCOPY) -O binary --only-section=.text $< $@

# The registers and modes the functional tests never reach: timer
# prescaler and roll-over, interrupt controller edge mode and claim,
# watchdog window mode and a wrong key, the safety controller's pin
# registers, and the CSRs no program happens to read.
regwalk: $(BUILD)/tb_cdriscv_subsys.vvp $(BUILD)/regwalk_test.hex \
         $(BUILD)/dtcm_zero.hex
	$(VVP) $(BUILD)/tb_cdriscv_subsys.vvp \
	  +ITCM_HEX=$(BUILD)/regwalk_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex \
	  +MAX_CYCLES=200000 | tee $(BUILD)/regwalk.log
	@grep -q "PASS" $(BUILD)/regwalk.log

# -------------------------------------------------------- AMS tests
$(BUILD)/ams_test.elf: verif/core/ams_test.S tb/sw/link.ld | $(BUILD)
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
	  -T tb/sw/link.ld -o $@ verif/core/ams_test.S

$(BUILD)/ams_test.bin: $(BUILD)/ams_test.elf
	$(OBJCOPY) -O binary --only-section=.text $< $@

# Limit registers, range checking, the conversion time-out, the trim
# output and the analog test bus.  The time-out is provoked by setting
# the limit below the bench ADC model's latency, so no bench change is
# needed for it.
ams: $(BUILD)/tb_cdriscv_subsys.vvp $(BUILD)/ams_test.hex \
     $(BUILD)/dtcm_zero.hex
	$(VVP) $(BUILD)/tb_cdriscv_subsys.vvp \
	  +ITCM_HEX=$(BUILD)/ams_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex \
	  +MAX_CYCLES=300000 | tee $(BUILD)/ams.log
	@grep -q "PASS" $(BUILD)/ams.log

# ------------------------------------------------------- trap tests
$(BUILD)/trap_test.elf: verif/core/trap_test.S tb/sw/link.ld | $(BUILD)
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
	  -T tb/sw/link.ld -o $@ verif/core/trap_test.S

$(BUILD)/trap_test.bin: $(BUILD)/trap_test.elf
	$(OBJCOPY) -O binary --only-section=.text $< $@

# Every exception cause the core can raise, with mcause and mtval
# checked for each, plus the illegal encodings a valid program never
# contains.
trap: $(BUILD)/tb_cdriscv_subsys.vvp $(BUILD)/trap_test.hex \
      $(BUILD)/dtcm_zero.hex
	$(VVP) $(BUILD)/tb_cdriscv_subsys.vvp \
	  +ITCM_HEX=$(BUILD)/trap_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex \
	  +MAX_CYCLES=100000 | tee $(BUILD)/trap.log
	@grep -q "PASS" $(BUILD)/trap.log

# ------------------------------------------------- reaction tests
$(BUILD)/reaction_test.elf: verif/safety/reaction_test.S tb/sw/link.ld | $(BUILD)
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
	  -T tb/sw/link.ld -o $@ verif/safety/reaction_test.S

$(BUILD)/reaction_test.bin: $(BUILD)/reaction_test.elf
	$(OBJCOPY) -O binary --only-section=.text $< $@

# Configures the clock monitor through its registers, checks the safety
# controller lock, and takes a reset request -- which restarts the core,
# so the program recognises its own second boot from a marker left in a
# peripheral register.
reaction: $(BUILD)/tb_cdriscv_subsys.vvp $(BUILD)/reaction_test.hex \
          $(BUILD)/dtcm_zero.hex
	$(VVP) $(BUILD)/tb_cdriscv_subsys.vvp \
	  +ITCM_HEX=$(BUILD)/reaction_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex \
	  +MAX_CYCLES=500000 | tee $(BUILD)/reaction.log
	@grep -q "PASS" $(BUILD)/reaction.log

# ------------------------------------------------- peripheral tests
$(BUILD)/periph_test.elf: verif/core/periph_test.S tb/sw/link.ld | $(BUILD)
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
	  -T tb/sw/link.ld -o $@ verif/core/periph_test.S

$(BUILD)/periph_test.bin: $(BUILD)/periph_test.elf
	$(OBJCOPY) -O binary --only-section=.text $< $@

# The memory BIST sweeps every word, so this one takes about 100k
# cycles rather than the few hundred the other tests need.
periph: $(BUILD)/tb_cdriscv_subsys.vvp $(BUILD)/periph_test.hex \
        $(BUILD)/dtcm_zero.hex
	$(VVP) $(BUILD)/tb_cdriscv_subsys.vvp \
	  +ITCM_HEX=$(BUILD)/periph_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex \
	  +MAX_CYCLES=2000000 | tee $(BUILD)/periph.log
	@grep -q "PASS" $(BUILD)/periph.log

# ------------------------------------------------------ safety tests
$(BUILD)/safety_test.elf: verif/safety/safety_test.S tb/sw/link.ld | $(BUILD)
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
	  -T tb/sw/link.ld -o $@ verif/safety/safety_test.S

$(BUILD)/safety_test.bin: $(BUILD)/safety_test.elf
	$(OBJCOPY) -O binary --only-section=.text $< $@

$(BUILD)/dtcm_zero.bin: | $(BUILD)
	head -c $$(( $(TCM_WORDS) * 4 )) /dev/zero > $@

$(BUILD)/tb_safety.vvp: $(RTL) verif/safety/tb_safety.sv | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s tb_safety $(RTL) verif/safety/tb_safety.sv

# Bench half: faults forced inside the checker core and a system clock
# that misbehaves -- neither reachable from software.
safety-bench: $(BUILD)/tb_safety.vvp $(BUILD)/safety_test.hex
	$(VVP) $(BUILD)/tb_safety.vvp +ITCM_HEX=$(BUILD)/safety_test.hex \
	  | tee $(BUILD)/safety_bench.log
	@grep -q "PASS" $(BUILD)/safety_bench.log

safety: safety-sw safety-bench

safety-sw: $(BUILD)/tb_cdriscv_subsys.vvp $(BUILD)/safety_test.hex \
        $(BUILD)/dtcm_zero.hex
	$(VVP) $(BUILD)/tb_cdriscv_subsys.vvp \
	  +ITCM_HEX=$(BUILD)/safety_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex \
	  +MAX_CYCLES=20000 | tee $(BUILD)/safety.log
	@grep -q "PASS" $(BUILD)/safety.log

# -------------------------------------------------------------- coverage
# Line coverage over the stimulus that exists: the directed ISA program,
# a spread of random programs, and the two subsystem level tests.
COV_SEEDS ?= 1000 1001 1002 1003 1004 1005 1006 1007

$(BUILD)/obj_cov/tb_cosim_cov: $(RTL) verif/core/tb_cosim.sv | $(BUILD)
	$(VERILATOR) --binary --timing -sv --timescale 1ns/1ps --coverage \
	  -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
	  -Wno-SYNCASYNCNET \
	  --top-module tb_cosim -o tb_cosim_cov -Mdir $(BUILD)/obj_cov \
	  $(RTL) verif/core/tb_cosim.sv

$(BUILD)/obj_syscov/tb_sys_cov: $(RTL) $(TB) | $(BUILD)
	$(VERILATOR) --binary --timing -sv --timescale 1ns/1ps --coverage \
	  -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
	  -Wno-SYNCASYNCNET -Wno-WIDTHTRUNC \
	  --top-module $(TB_TOP) -o tb_sys_cov -Mdir $(BUILD)/obj_syscov \
	  $(RTL) $(TB)

coverage: $(BUILD)/obj_cov/tb_cosim_cov $(BUILD)/obj_syscov/tb_sys_cov \
          $(BUILD)/cosim_isa.hex $(BUILD)/safety_test.hex \
          $(BUILD)/periph_test.hex $(BUILD)/reaction_test.hex \
          $(BUILD)/trap_test.hex $(BUILD)/ams_test.hex \
          $(BUILD)/regwalk_test.hex $(BUILD)/dtcm_zero.hex sw
	@mkdir -p $(BUILD)/cov && rm -f $(BUILD)/cov/*.dat
	@./$(BUILD)/obj_cov/tb_cosim_cov +HEX=$(BUILD)/cosim_isa.hex \
	  +MAXRETIRE=100000 +QUIET > /dev/null 2>&1; \
	  mv coverage.dat $(BUILD)/cov/cov_isa.dat
	@for p in 15 35 70 90; do \
	  ./$(BUILD)/obj_cov/tb_cosim_cov +HEX=$(BUILD)/cosim_isa.hex \
	    +MAXRETIRE=100000 +STALL=$$p +QUIET > /dev/null 2>&1; \
	  mv coverage.dat $(BUILD)/cov/cov_isa_stall$$p.dat; \
	done
	@for s in $(COV_SEEDS); do \
	  if [ -f $(BUILD)/random/rand_$$s.hex ]; then \
	    ./$(BUILD)/obj_cov/tb_cosim_cov +HEX=$(BUILD)/random/rand_$$s.hex \
	      +MAXRETIRE=100000 +QUIET > /dev/null 2>&1; \
	    mv coverage.dat $(BUILD)/cov/cov_r$$s.dat; \
	  fi; done
	@./$(BUILD)/obj_syscov/tb_sys_cov +ITCM_HEX=$(BUILD)/prog.itcm.hex \
	  +DTCM_HEX=$(BUILD)/prog.dtcm.hex +MAX_CYCLES=20000 > /dev/null 2>&1; \
	  mv coverage.dat $(BUILD)/cov/cov_smoke.dat
	@./$(BUILD)/obj_syscov/tb_sys_cov +ITCM_HEX=$(BUILD)/safety_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex +MAX_CYCLES=20000 > /dev/null 2>&1; \
	  mv coverage.dat $(BUILD)/cov/cov_safety.dat
	@./$(BUILD)/obj_syscov/tb_sys_cov +ITCM_HEX=$(BUILD)/periph_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex +MAX_CYCLES=2000000 > /dev/null 2>&1; \
	  mv coverage.dat $(BUILD)/cov/cov_periph.dat
	@./$(BUILD)/obj_syscov/tb_sys_cov +ITCM_HEX=$(BUILD)/reaction_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex +MAX_CYCLES=500000 > /dev/null 2>&1; \
	  mv coverage.dat $(BUILD)/cov/cov_reaction.dat
	@./$(BUILD)/obj_syscov/tb_sys_cov +ITCM_HEX=$(BUILD)/trap_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex +MAX_CYCLES=100000 > /dev/null 2>&1; \
	  mv coverage.dat $(BUILD)/cov/cov_trap.dat
	@./$(BUILD)/obj_syscov/tb_sys_cov +ITCM_HEX=$(BUILD)/ams_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex +MAX_CYCLES=300000 > /dev/null 2>&1; \
	  mv coverage.dat $(BUILD)/cov/cov_ams.dat
	@./$(BUILD)/obj_syscov/tb_sys_cov +ITCM_HEX=$(BUILD)/regwalk_test.hex \
	  +DTCM_HEX=$(BUILD)/dtcm_zero.hex +MAX_CYCLES=200000 > /dev/null 2>&1; \
	  mv coverage.dat $(BUILD)/cov/cov_regwalk.dat
	verilator_coverage --write $(BUILD)/cov/merged.dat $(BUILD)/cov/cov_*.dat
	@rm -rf $(BUILD)/cov/ann_line $(BUILD)/cov/ann_tog
	verilator_coverage --filter-type line --annotate $(BUILD)/cov/ann_line \
	  --annotate-min 1 $(BUILD)/cov/merged.dat > /dev/null
	verilator_coverage --filter-type toggle --annotate $(BUILD)/cov/ann_tog \
	  --annotate-min 1 $(BUILD)/cov/merged.dat > /dev/null
	@$(PYTHON) scripts/coverage_report.py $(BUILD)/cov/ann_line \
	  "line coverage" | tee $(BUILD)/coverage.txt
	@echo "" | tee -a $(BUILD)/coverage.txt
	@$(PYTHON) scripts/coverage_report.py $(BUILD)/cov/ann_tog \
	  "toggle coverage" | head -3 | tee -a $(BUILD)/coverage.txt

# ------------------------------------------------- fault injection
FI_RUNS ?= 300
FI_SEED ?= 7

$(BUILD)/fi_workload.elf: verif/fi/fi_workload.S tb/sw/link.ld | $(BUILD)
	$(CC) -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
	  -T tb/sw/link.ld -o $@ verif/fi/fi_workload.S

$(BUILD)/fi_workload.bin: $(BUILD)/fi_workload.elf
	$(OBJCOPY) -O binary --only-section=.text $< $@

$(BUILD)/tb_fi.vvp: $(RTL) verif/fi/tb_fi.sv | $(BUILD)
	$(IVERILOG) -g2012 -o $@ -s tb_fi $(RTL) verif/fi/tb_fi.sv

# Single event upsets across a named fault list, classified into
# detected / silent-ok / silent data corruption / hang.  The SDC count
# is the one that matters: a fault that changes the result and reports
# nothing is what a safety mechanism exists to prevent.
fi: $(BUILD)/tb_fi.vvp $(BUILD)/fi_workload.hex $(BUILD)/dtcm_zero.hex
	$(PYTHON) scripts/fi_campaign.py --runs $(FI_RUNS) --seed $(FI_SEED) \
	  | tee $(BUILD)/fi_campaign.txt

# --------------------------------------------------------------- formal
# Bounded model check of the fetch stage.  Depth is a variable because
# the cost climbs steeply: the properties reason over 32-bit PCs, and
# the solver time per step grows with depth.  FORMAL_DEPTH=20 is the
# routine setting; a deeper run is worth doing before any release.
FORMAL_DEPTH ?= 20
SBY          ?= sby

formal: formal-if formal-ecc formal-bus formal-dec formal-lsu formal-safety

formal-if: | $(BUILD)
	$(SBY) -f -d $(BUILD)/fv_if verif/formal/if_stage.sby bmc \
	  | tee $(BUILD)/formal_if.log
	@grep -q "DONE (PASS" $(BUILD)/formal_if.log

formal-ecc: | $(BUILD)
	$(SBY) -f -d $(BUILD)/fv_ecc verif/formal/ecc.sby bmc \
	  | tee $(BUILD)/formal_ecc.log
	@grep -q "DONE (PASS" $(BUILD)/formal_ecc.log

# The interconnect's risk is bookkeeping, not arithmetic: a misrouted
# response hands one master another's data, which looks plausible and
# is wrong.  Read through yosys-slang, because the built-in frontend
# cannot parse the address decode function.
formal-bus: | $(BUILD)
	$(SBY) -f -d $(BUILD)/fv_bus verif/formal/bus.sby bmc \
	  | tee $(BUILD)/formal_bus.log
	@grep -q "DONE (PASS" $(BUILD)/formal_bus.log

# The decoder is combinational, so this quantifies over every one of the
# 2^32 instruction encodings: an instruction the decoder rejects must
# have no architectural effect at all -- no register write, no memory
# access, no control transfer, no CSR access, no system side effect.
formal-dec: | $(BUILD)
	$(SBY) -f -d $(BUILD)/fv_dec verif/formal/decoder.sby bmc \
	  | tee $(BUILD)/formal_dec.log
	@grep -q "DONE (PASS" $(BUILD)/formal_dec.log

# The LSU drives its bus outputs combinationally from the core's
# request, so the core owes it stability.  That obligation is an
# assumption in the wrapper, stated rather than implied.
formal-lsu: | $(BUILD)
	$(SBY) -f -d $(BUILD)/fv_lsu verif/formal/lsu.sby bmc \
	  | tee $(BUILD)/formal_lsu.log
	@grep -q "DONE (PASS" $(BUILD)/formal_lsu.log

# A latched fault does not go away by itself, and a locked
# configuration stays locked.  Both are claims the safety manual makes;
# this is where they are checked.
formal-safety: | $(BUILD)
	$(SBY) -f -d $(BUILD)/fv_safety verif/formal/safety.sby bmc \
	  | tee $(BUILD)/formal_safety.log
	@grep -q "DONE (PASS" $(BUILD)/formal_safety.log

# ---------------------------------------------------------------- ecc
ecc:
	$(PYTHON) scripts/gen_secded.py

# --------------------------------------------------------------- synth
# Structural check, not a real hardening run: the TCMs are cut down to
# SYNTH_TCM_WORDS because the behavioural arrays would otherwise map to
# a few hundred thousand flip-flops and dominate everything.  What this
# target is for is objective O5 -- no inferred latches, no combinational
# loops -- plus a logic area figure to track.
SYNTH_TCM_WORDS ?= 64

# yosys-slang rather than the built-in Verilog frontend: the latter
# does not accept a package import in the module header.  slang is also
# the strictest of the three front-ends this project uses, so it is a
# useful third opinion after Verilator and Icarus.
synth: | $(BUILD)
	$(YOSYS) -p "plugin -i slang; \
	             read_slang --top $(TOP) \
	               -G ItcmWords=$(SYNTH_TCM_WORDS) \
	               -G DtcmWords=$(SYNTH_TCM_WORDS) \
	               $(RTL); \
	             synth -top $(TOP); \
	             stat" -l $(BUILD)/synth.log
	@echo "--- structural checks (objective O5) ---"
	@if grep -qiE "inferring latch|combinational loop|found logic loop" $(BUILD)/synth.log; then \
	  grep -iE "inferring latch|combinational loop|found logic loop" $(BUILD)/synth.log; \
	  echo "FAIL: latch or loop inferred"; exit 1; fi
	@if grep -qE '\$$_DLATCH_' $(BUILD)/synth.log; then \
	  echo "FAIL: latch cells in the mapped netlist"; exit 1; fi
	@echo "no latches, no combinational loops"
	@grep -E "^ +[0-9]+ (wires|cells)$$" $(BUILD)/synth.log | tail -2
	@grep -cE '\$$_(DFF|ALDFF)' $(BUILD)/synth.log | \
	  xargs -I{} echo "flip-flop cell types: {}"

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD) obj_dir *.vcd
