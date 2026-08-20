#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# Runs one program on Spike and on the RTL and compares the retired
# instruction streams.
#
#   python3 verif/core/cosim.py build/cosim_isa.elf --count 3000
#
# What is compared today is the (pc, instruction) sequence: the RTL
# exposes retire_valid/retire_pc/retire_instr but no register or memory
# write information, so a value error that never reaches a branch is
# still invisible.  Closing that is objective O2 in the verification
# plan and needs the RVFI bind.
#
# Spike's own reset vector at 0x1000 is skipped: the comparison starts
# at the ELF entry point.

import argparse
import os
import re
import subprocess
import sys

SPIKE = os.environ.get("SPIKE", "/headless/verif-tools/spike/bin/spike")
VVP = os.environ.get("VVP", "vvp")
ISA = "rv32im_zicsr_zifencei"

SPIKE_RE = re.compile(r"core\s+\d+:\s+0x([0-9a-f]+)\s+\(0x([0-9a-f]+)\)")
RTL_RE = re.compile(r"^TRACE ([0-9a-f]+) ([0-9a-f]+)")


def entry_point(elf):
    out = subprocess.run(["riscv64-unknown-elf-readelf", "-h", elf],
                         capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        if "Entry point address" in line:
            return int(line.split(":")[1].strip(), 16)
    raise RuntimeError("no entry point in %s" % elf)


def run_spike(elf, count, base, size):
    # Free running with the HTIF exit protocol: the program ends the run
    # by storing to `tohost`.  Spike's interactive debug mode can do the
    # same job with "r N", but it is thousands of times slower -- 215
    # instructions took a minute there against 25 ms here.
    cmd = [SPIKE, "-l", "--isa=" + ISA, "-m0x%x:0x%x" % (base, size), elf]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    trace = []
    for line in proc.stdout.splitlines() + proc.stderr.splitlines():
        m = SPIKE_RE.search(line)
        if m:
            trace.append((int(m.group(1), 16), int(m.group(2), 16)))
    return trace


def run_rtl(vvp_file, hexfile, count):
    cmd = [VVP, vvp_file, "+HEX=" + hexfile, "+MAXRETIRE=%d" % count,
           "+MAXCYCLES=%d" % (count * 40 + 5000)]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    trace = []
    for line in proc.stdout.splitlines():
        m = RTL_RE.match(line)
        if m:
            trace.append((int(m.group(1), 16), int(m.group(2), 16)))
        elif "FAULT" in line or "TIMEOUT" in line:
            sys.stderr.write("[cosim] RTL reported: %s\n" % line.strip())
    return trace


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("elf")
    ap.add_argument("--hex", default=None)
    ap.add_argument("--vvp", default="build/tb_cosim.vvp")
    ap.add_argument("--count", type=int, default=2000)
    ap.add_argument("--base", type=lambda x: int(x, 0), default=0x80000000)
    ap.add_argument("--size", type=lambda x: int(x, 0), default=0x4000)
    ap.add_argument("--context", type=int, default=8)
    args = ap.parse_args()

    hexfile = args.hex or args.elf.replace(".elf", ".hex")
    entry = entry_point(args.elf)

    spike = run_spike(args.elf, args.count, args.base, args.size)
    # drop Spike's built-in reset vector: start at the ELF entry
    start = next((i for i, (pc, _) in enumerate(spike) if pc == entry), None)
    if start is None:
        print("[cosim] FAIL: Spike never reached the entry point 0x%08x" % entry)
        return 1
    spike = spike[start:]

    rtl = run_rtl(args.vvp, hexfile, args.count)

    if not rtl:
        print("[cosim] FAIL: the RTL retired nothing")
        return 1

    # Spike stops at the tohost store; the RTL keeps spinning in the
    # loop after it, so the comparison runs to the end of Spike's stream.
    n = min(len(spike), len(rtl), args.count)
    for i in range(n):
        if spike[i] != rtl[i]:
            print("[cosim] FAIL: streams diverge at retired instruction %d" % i)
            lo = max(0, i - args.context)
            print("        %-6s %-22s %-22s" % ("idx", "spike", "rtl"))
            for j in range(lo, min(n, i + args.context)):
                mark = "  <<<" if j == i else ""
                print("        %-6d pc=%08x %08x  pc=%08x %08x%s"
                      % (j, spike[j][0], spike[j][1], rtl[j][0], rtl[j][1], mark))
            return 1

    if n < args.count:
        print("[cosim] note: compared %d instructions (spike %d, rtl %d)"
              % (n, len(spike), len(rtl)))
    print("[cosim] PASS: %d retired instructions match" % n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
