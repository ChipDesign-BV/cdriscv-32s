// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s v2 -- end-to-end (E2E) bus protection.
//
// The TCMs in variant 1 are ECC-protected *inside* the memory: a word
// is encoded on the way in and checked on the way out, so a fault in
// the array is caught.  What is NOT covered is everything between the
// core and the array -- address decode, bus muxing, the interconnect
// itself.  A fault there delivers the wrong word, correctly ECC'd, and
// nothing notices.
//
// E2E closes that by carrying the check bits with the payload from
// producer to consumer, so the consumer verifies what it received
// rather than trusting that the path was sound.  This module is the
// generator/checker pair; the bus carries e2e_word_t instead of raw
// data.
//
// Address is folded into the check: the same data at the wrong address
// must NOT pass.  That is what makes this end-to-end rather than merely
// a second data ECC -- a decode fault changes the address, which
// changes the expected syndrome, which the consumer sees as an error.
//
// Reuses the (39,32) Hsiao code the TCMs already use, so the same
// generator, the same proof and the same block-level bench apply.
//
// STATUS: NEW AND UNVERIFIED -- not through the O1-O9 gate.  Do not use.

`default_nettype none

module cdriscv_v2_e2e_gen (
    input  logic [31:0] data_i,
    input  logic [31:0] addr_i,
    output logic [6:0]  chk_o
);
  logic [6:0] data_chk;
  logic [31:0] cw_unused;
  cdriscv_ecc_enc u_enc (.data_i(data_i), .cw_o({data_chk, cw_unused}));

  // Fold the address in: a transfer that arrives at the wrong address
  // carries a syndrome that no longer matches.  XOR-folding to 7 bits
  // keeps the check width unchanged.
  logic [6:0] addr_fold;
  assign addr_fold = addr_i[6:0]   ^ addr_i[13:7]  ^ addr_i[20:14]
                   ^ addr_i[27:21] ^ {3'b0, addr_i[31:28]};

  assign chk_o = data_chk ^ addr_fold;
endmodule


module cdriscv_v2_e2e_chk (
    input  logic [31:0] data_i,
    input  logic [31:0] addr_i,
    input  logic [6:0]  chk_i,
    output logic        err_o
);
  logic [6:0] expect_chk;
  cdriscv_v2_e2e_gen u_gen (.data_i(data_i), .addr_i(addr_i), .chk_o(expect_chk));
  assign err_o = (expect_chk != chk_i);
endmodule
