#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 ChipDesign B.V.
# SPDX-License-Identifier: Apache-2.0
#
# Random program regression: generates programs, builds them, and runs
# each through the Spike co-simulation.
#
#   python3 verif/core/random_regress.py --seeds 50 --count 400
#
# Failing seeds are kept in the build directory and named, so a failure
# is reproducible with one command.

import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
BUILD = os.path.join(ROOT, "build", "random")
CROSS = os.environ.get("CROSS", "riscv64-unknown-elf-")
ARCH = "rv32im_zicsr_zifencei"


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def build(seed, count, loops):
    asm = os.path.join(BUILD, "rand_%d.S" % seed)
    elf = os.path.join(BUILD, "rand_%d.elf" % seed)
    binf = os.path.join(BUILD, "rand_%d.bin" % seed)
    hexf = os.path.join(BUILD, "rand_%d.hex" % seed)

    r = sh([sys.executable, os.path.join(HERE, "gen_random_prog.py"), asm,
            "--seed", str(seed), "--count", str(count),
            "--loops", str(loops)])
    if r.returncode:
        return None, "generator failed: " + r.stderr

    r = sh([CROSS + "gcc", "-march=" + ARCH, "-mabi=ilp32", "-nostdlib",
            "-nostartfiles", "-T", os.path.join(HERE, "link_cosim.ld"),
            "-o", elf, asm])
    if r.returncode:
        return None, "assembler failed: " + r.stderr

    r = sh([CROSS + "objcopy", "-O", "binary", elf, binf])
    if r.returncode:
        return None, "objcopy failed: " + r.stderr

    r = sh([sys.executable, os.path.join(ROOT, "scripts", "mkimage.py"),
            binf, hexf])
    if r.returncode:
        return None, "mkimage failed: " + r.stderr

    return (elf, hexf), None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", type=int, default=20)
    ap.add_argument("--start", type=int, default=1)
    ap.add_argument("--count", type=int, default=400)
    ap.add_argument("--loops", type=int, default=1)
    ap.add_argument("--vvp", dest="runner",
                    default=os.path.join(ROOT, "build", "obj_cosim", "tb_cosim_vl"))
    ap.add_argument("--max-report", type=int, default=3)
    args = ap.parse_args()

    os.makedirs(BUILD, exist_ok=True)

    passed, failed, instructions = 0, [], 0
    for seed in range(args.start, args.start + args.seeds):
        built, err = build(seed, args.count, args.loops)
        if built is None:
            print("[random] seed %d: %s" % (seed, err))
            failed.append(seed)
            continue
        elf, hexf = built
        r = sh([sys.executable, os.path.join(HERE, "cosim.py"), elf,
                "--hex", hexf, "--vvp", args.runner, "--count", "20000"])
        out = r.stdout.strip()
        if r.returncode == 0:
            passed += 1
            for tok in out.split():
                if tok.isdigit():
                    instructions += int(tok)
                    break
        else:
            failed.append(seed)
            if len(failed) <= args.max_report:
                print("[random] seed %d FAILED" % seed)
                print("\n".join("    " + l for l in out.splitlines()[:14]))
                print("    reproduce: python3 verif/core/cosim.py %s --hex %s"
                      % (os.path.relpath(elf, ROOT), os.path.relpath(hexf, ROOT)))

    print("[random] %d/%d programs match, %d instructions compared"
          % (passed, passed + len(failed), instructions))
    if failed:
        print("[random] FAIL: seeds %s" % failed)
        return 1
    print("[random] PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
