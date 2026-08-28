// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s v2 -- physical memory protection.
//
// Machine-mode PMP to the privileged specification: NRegions entries,
// each an 8-bit pmpcfg and a 34-bit-equivalent pmpaddr (RV32 stores
// address[33:2], so the register holds the address shifted right by 2).
//
// Why a safety core wants this even with no user mode: PMP is the
// mechanism that gives freedom from interference between software
// partitions of different ASIL, which ISO 26262 requires when mixed-
// criticality software shares one core.  Without it the argument has to
// be made entirely in software.
//
// Matching rules, in the order the spec mandates:
//  * entries are checked LOW index first and the FIRST match wins --
//    not the most permissive, not the most restrictive;
//  * a locked entry (cfg.l) applies to machine mode too and cannot be
//    rewritten until reset.  Unlocked entries do not restrict machine
//    mode, which is why mmwp-style behaviour needs an explicit
//    catch-all entry;
//  * TOR compares against the PREVIOUS entry's address, and entry 0's
//    lower bound is zero;
//  * NAPOT decodes the trailing ones of pmpaddr to a size; NA4 is the
//    degenerate 4-byte case.
//
// STATUS: NEW AND UNVERIFIED -- not through the O1-O9 gate.  Do not use.

`default_nettype none

module cdriscv_v2_pmp
  import cdriscv_v2_pkg::*;
#(
    parameter int unsigned NRegions = 8
) (
    // configuration, driven from the CSR file
    input  pmp_cfg_t             cfg_i   [NRegions],
    input  logic [31:0]          addr_i  [NRegions],   // pmpaddr (addr>>2)

    // access under test
    input  logic [31:0]          req_addr_i,
    input  pmp_access_e          req_type_i,
    input  logic                 req_machine_i,        // 1 = M-mode

    output logic                 allow_o
);

  logic [NRegions-1:0] match, perm;

  // Everything below works in pmpaddr space -- the byte address shifted
  // right by 2 -- which is the format pmpaddr itself holds.  Mixing byte
  // and word addresses here is the classic source of off-by-four PMP
  // bugs, so the conversion happens exactly once.
  logic [31:0] req_pa;
  assign req_pa = {2'b00, req_addr_i[31:2]};

  for (genvar r = 0; r < NRegions; r++) begin : g_region
    logic [31:0] a, lower, napot_mask, napot_base;
    assign a = addr_i[r];

    // TOR lower bound is the previous entry; entry 0 starts at zero.
    if (r == 0) begin : g_tor0
      assign lower = 32'd0;
    end else begin : g_torn
      assign lower = addr_i[r-1];
    end

    // NAPOT size comes from the trailing ones of pmpaddr: the lowest
    // zero bit sets the mask.  NA4 is the degenerate all-ones mask.
    always_comb begin
      napot_mask = 32'hffff_ffff;
      if (cfg_i[r].a == PMP_NAPOT) begin
        for (int unsigned i = 0; i < 32; i++) begin
          if (a[i] == 1'b0) begin
            napot_mask = 32'hffff_ffff << (i + 1);
            break;
          end
        end
      end
    end
    assign napot_base = a & napot_mask;

    always_comb begin
      unique case (cfg_i[r].a)
        PMP_OFF   : match[r] = 1'b0;
        // `lower` is a constant 0 for entry 0, so the lower bound folds
        // away there -- correct, and intended.
        PMP_TOR   : match[r] = (req_pa >= lower) && (req_pa < a);
        PMP_NA4   : match[r] = (req_pa == a);
        PMP_NAPOT : match[r] = ((req_pa & napot_mask) == napot_base);
        default   : match[r] = 1'b0;
      endcase
    end

    always_comb begin
      unique case (req_type_i)
        PMP_ACC_READ  : perm[r] = cfg_i[r].r;
        PMP_ACC_WRITE : perm[r] = cfg_i[r].w;
        PMP_ACC_EXEC  : perm[r] = cfg_i[r].x;
        default       : perm[r] = 1'b0;
      endcase
    end
  end

  // ---- first match wins ------------------------------------------------
  logic matched, granted;
  always_comb begin
    matched = 1'b0;
    granted = 1'b0;
    for (int unsigned r = 0; r < NRegions; r++) begin
      if (!matched && match[r]) begin
        matched = 1'b1;
        // A locked entry binds machine mode as well; an unlocked one
        // does not constrain M-mode at all.
        granted = perm[r] || (req_machine_i && !cfg_i[r].l);
      end
    end
    // No entry matched: machine mode is unrestricted, anything else is
    // denied.  (With no U-mode implemented req_machine_i is tied high,
    // and this reduces to "unmatched is allowed".)
    if (!matched) granted = req_machine_i;
  end

  assign allow_o = granted;

  // PMP granularity is 4 bytes, so the byte offset never participates.
  logic unused;
  assign unused = |req_addr_i[1:0];

endmodule
