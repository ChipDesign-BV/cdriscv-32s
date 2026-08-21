// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// Black box stub for the TCM, used for gate level synthesis only.
//
// The TCMs are 4 096 x 39 bit arrays.  Synthesised as logic they become
// a third of a million flip-flops, which is neither what the design
// means nor something that finishes: a first attempt mapped 325 107
// flops before it was killed.  In silicon these are compiled SRAM
// macros, and a gate level netlist instantiates them rather than
// containing them.
//
// Marking the real module `blackbox` inside yosys does not work here.
// The slang front end specialises parameterised modules, so the
// instances are `$paramod\cdriscv_tcm\...` and a `blackbox cdriscv_tcm`
// command matches nothing -- silently, which is why the first run just
// looked slow rather than wrong.  Substituting this file for the real
// one at read time is unambiguous.
//
// Ports are identical to rtl/bus/cdriscv_tcm.sv.  At simulation time
// the *real* module is compiled in place of this stub, so the memory
// behaves exactly as it does at RTL while everything around it is
// gates.

`default_nettype none

(* blackbox *)
module cdriscv_tcm #(
    parameter int unsigned Depth    = 4096,
    parameter string       InitFile = ""
)(
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        req_i,
    output logic        gnt_o,
    output logic        rvalid_o,
    input  logic        we_i,
    input  logic [3:0]  be_i,
    input  logic [31:0] addr_i,
    input  logic [31:0] wdata_i,
    output logic [31:0] rdata_o,
    output logic        err_o,
    output logic        ecc_cor_o,
    output logic        ecc_unc_o,
    input  logic        inj_en_i,
    input  logic [38:0] inj_mask_i,
    input  logic        bist_en_i,
    input  logic        bist_we_i,
    input  logic [31:0] bist_addr_i,
    input  logic [38:0] bist_wdata_i,
    output logic [38:0] bist_rdata_o
);
endmodule

`default_nettype wire
