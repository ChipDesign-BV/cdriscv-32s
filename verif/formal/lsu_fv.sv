// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// Formal properties for cdriscv_lsu.
//
// The load/store unit drives its bus outputs combinationally from the
// core's request, which means the core owes it stability: the address,
// size and write data must not move while an access is in progress.
// That obligation is written here as an assumption, so it is visible
// rather than implied, and the properties then check what the LSU owes
// in return.

`default_nettype none

module lsu_fv
  import cdriscv_pkg::*;
(
    input  logic        clk_i,
    input  logic        req_i,
    input  logic        we_i,
    input  logic [1:0]  size_i,
    input  logic        sign_ext_i,
    input  logic [31:0] addr_i,
    input  logic [31:0] wdata_i,
    input  logic        data_gnt_i,
    input  logic        data_rvalid_i,
    input  logic [31:0] data_rdata_i,
    input  logic        data_err_i
);

  logic [1:0] rst_cnt = 2'b00;
  logic       rst_ni;
  always @(posedge clk_i) if (rst_cnt != 2'b11) rst_cnt <= rst_cnt + 2'd1;
  assign rst_ni = (rst_cnt == 2'b11);

  logic        busy, valid, err;
  logic [31:0] rdata;
  logic        data_req, data_we;
  logic [3:0]  data_be;
  logic [31:0] data_addr, data_wdata;

  cdriscv_lsu u_dut (
      .clk_i         (clk_i),
      .rst_ni        (rst_ni),
      .req_i         (req_i),
      .we_i          (we_i),
      .size_i        (size_i),
      .sign_ext_i    (sign_ext_i),
      .addr_i        (addr_i),
      .wdata_i       (wdata_i),
      .kill_i        (1'b0),
      .busy_o        (busy),
      .valid_o       (valid),
      .rdata_o       (rdata),
      .err_o         (err),
      .data_req_o    (data_req),
      .data_gnt_i    (data_gnt_i),
      .data_rvalid_i (data_rvalid_i),
      .data_we_o     (data_we),
      .data_be_o     (data_be),
      .data_addr_o   (data_addr),
      .data_wdata_o  (data_wdata),
      .data_rdata_i  (data_rdata_i),
      .data_err_i    (data_err_i)
  );

  // one transaction in flight, tracked by the environment
  logic env_out;
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)                          env_out <= 1'b0;
    else if (data_req && data_gnt_i)      env_out <= 1'b1;
    else if (data_rvalid_i)               env_out <= 1'b0;
  end

  // expected byte enables, written from the RISC-V semantics
  logic [3:0] be_ref;
  always_comb begin
    case (size_i)
      LS_BYTE: be_ref = 4'b0001 << addr_i[1:0];
      LS_HALF: be_ref = 4'b0011 << addr_i[1:0];
      LS_WORD: be_ref = 4'b1111;
      default: be_ref = 4'b0000;
    endcase
  end

  always @(posedge clk_i) begin
    if (rst_ni) begin
      // ---- the core's side of the contract ----
      a_gnt_needs_req:      assume (!data_gnt_i || data_req);
      a_rvalid_needs_out:   assume (!data_rvalid_i || env_out);
      a_no_gnt_with_rvalid: assume (!(data_gnt_i && data_rvalid_i));

      // The core holds the request and its payload stable while the
      // access is in progress; the LSU has no address register of its
      // own and relies on this.
      if ($past(rst_ni) && $past(busy)) begin
        a_addr_stable:  assume (addr_i  == $past(addr_i));
        a_we_stable:    assume (we_i    == $past(we_i));
        a_size_stable:  assume (size_i  == $past(size_i));
        a_wdata_stable: assume (wdata_i == $past(wdata_i));
      end

      // ---- what the LSU owes ----

      // Never two accesses in flight.
      p_single_outstanding: assert (!(data_req && env_out));

      // Bus addresses are word aligned; the byte lanes carry the offset.
      p_addr_aligned: assert (data_addr[1:0] == 2'b00);
      p_addr_matches: assert (!data_req || (data_addr == {addr_i[31:2], 2'b00}));

      // Byte enables follow the access size and offset.
      p_be_correct: assert (!data_req || (data_be == be_ref));

      // A completion is reported only when a response actually arrives.
      p_valid_needs_rvalid: assert (!valid || data_rvalid_i);
      p_valid_needs_out:    assert (!valid || env_out);

      // The unit is busy for exactly as long as something is in flight
      // or waiting for a grant.
      p_busy_when_out: assert (!env_out || busy);
    end
  end

endmodule
