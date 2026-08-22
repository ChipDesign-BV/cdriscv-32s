// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s -- windowed watchdog, APB slave.
//
//   0x00  CTRL     RW  [0] enable  [1] window mode  [2] lock (sticky)
//                      [3] reset request enable
//   0x04  PERIOD   RW  reload value of the down counter
//   0x08  WINDOW   RW  service is only accepted once the counter has
//                      fallen below this value (window mode)
//   0x0c  SERVICE  WO  two step key: write KEY_A, then KEY_B
//   0x10  STATUS   RW  [0] timeout (W1C) [1] bad service (W1C)
//                      [2] locked (RO)   [3] key state (RO)
//   0x14  COUNT    RO  current counter value
//
// Both failure modes of a watchdog are covered: servicing too late (the
// counter reaches zero) and servicing too early or with a wrong key,
// which catches a program that has run away into a loop that happens to
// contain a service call.  Once CTRL.lock is set, the configuration is
// frozen until the next reset, so a corrupted program cannot disable
// the watchdog.
//
// STATUS: NOT VERIFIED YET -- DO NOT USE YET.

`default_nettype none

module cdriscv_wdog #(
    parameter logic [31:0] KeyA = 32'ha5a5_5a5a,
    parameter logic [31:0] KeyB = 32'h5a5a_a5a5
)(
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic        psel_i,
    input  logic        penable_i,
    input  logic [11:0] paddr_i,
    input  logic        pwrite_i,
    input  logic [31:0] pwdata_i,
    output logic [31:0] prdata_o,
    output logic        pready_o,
    output logic        pslverr_o,

    output logic        fault_o,       // pulse: timeout or bad service
    output logic        reset_req_o,   // pulse: fault and reset enabled
    output logic        cfg_err_o      // level: configuration parity mismatch
);

  logic        enable_q, window_q, lock_q, rst_en_q;
  logic [31:0] period_q, window_val_q, count_q;
  logic        sts_timeout_q, sts_badsvc_q;
  logic        key_armed_q;            // KEY_A seen, waiting for KEY_B

  logic wr, rd;
  assign wr = psel_i && penable_i &&  pwrite_i;
  assign rd = psel_i && !pwrite_i;

  logic cfg_wr;
  assign cfg_wr = wr && !lock_q;

  // ------------------------------------------------------------------
  // Service decoding
  // ------------------------------------------------------------------
  logic svc_wr, svc_key_a, svc_key_b;
  assign svc_wr    = wr && (paddr_i[7:0] == 8'h0c);
  assign svc_key_a = svc_wr && (pwdata_i == KeyA);
  assign svc_key_b = svc_wr && (pwdata_i == KeyB);

  // A service completes on KEY_B while armed.
  logic svc_done, svc_bad_key, in_window, svc_early;
  assign svc_done    = svc_wr && svc_key_b && key_armed_q;
  assign svc_bad_key = svc_wr && !(svc_key_a || (svc_key_b && key_armed_q));
  assign in_window   = !window_q || (count_q <= window_val_q);
  assign svc_early   = svc_done && !in_window;

  logic timeout;
  assign timeout = enable_q && (count_q == 32'b0);

  assign fault_o     = timeout || svc_bad_key || svc_early;
  assign reset_req_o = fault_o && rst_en_q;

  // ------------------------------------------------------------------
  // Counter and registers
  // ------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      enable_q      <= 1'b0;
      window_q      <= 1'b0;
      lock_q        <= 1'b0;
      rst_en_q      <= 1'b0;
      period_q      <= 32'hffff_ffff;
      window_val_q  <= 32'h7fff_ffff;
      count_q       <= 32'hffff_ffff;
      sts_timeout_q <= 1'b0;
      sts_badsvc_q  <= 1'b0;
      key_armed_q   <= 1'b0;
    end else begin
      // down counter
      if (enable_q) begin
        if (count_q == 32'b0) count_q <= period_q;      // timeout, restart
        else                  count_q <= count_q - 32'd1;
      end

      // service: reload, and re-arm the key sequence
      if (svc_done && in_window) begin
        count_q     <= period_q;
        key_armed_q <= 1'b0;
      end else if (svc_key_a) begin
        key_armed_q <= 1'b1;
      end else if (svc_bad_key || svc_early) begin
        key_armed_q <= 1'b0;
      end

      // sticky status
      if (timeout)                    sts_timeout_q <= 1'b1;
      if (svc_bad_key || svc_early)   sts_badsvc_q  <= 1'b1;

      // register writes
      if (wr) begin
        unique case (paddr_i[7:0])
          8'h00: begin
            if (cfg_wr) begin
              enable_q <= pwdata_i[0];
              window_q <= pwdata_i[1];
              rst_en_q <= pwdata_i[3];
            end
            // the lock bit is set-only and survives the lock itself
            if (pwdata_i[2]) lock_q <= 1'b1;
          end
          8'h04: if (cfg_wr) begin
            period_q <= pwdata_i;
            count_q  <= pwdata_i;      // a new period restarts the counter
          end
          8'h08: if (cfg_wr) window_val_q <= pwdata_i;
          8'h10: begin
            if (pwdata_i[0]) sts_timeout_q <= 1'b0;
            if (pwdata_i[1]) sts_badsvc_q  <= 1'b0;
          end
          default: ;
        endcase
      end
    end
  end

  always_comb begin
    prdata_o = 32'b0;
    if (rd) begin
      unique case (paddr_i[7:0])
        8'h00:   prdata_o = {28'b0, rst_en_q, lock_q, window_q, enable_q};
        8'h04:   prdata_o = period_q;
        8'h08:   prdata_o = window_val_q;
        8'h10:   prdata_o = {28'b0, key_armed_q, lock_q, sts_badsvc_q, sts_timeout_q};
        8'h14:   prdata_o = count_q;
        default: prdata_o = 32'b0;
      endcase
    end
  end

  assign pready_o  = 1'b1;
  assign pslverr_o = 1'b0;

  // ------------------------------------------------------------------
  // Configuration parity (V29): CTRL fields, PERIOD, WINDOW.
  // count_q and the key/service state are dynamic and excluded.
  // ------------------------------------------------------------------
  cdriscv_cfg_parity #(.Width(68)) u_cfg_par (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .cfg_i  ({enable_q, window_q, lock_q, rst_en_q, period_q, window_val_q}),
      .wr_i   (wr && ((paddr_i[7:0] == 8'h00) ||
                      (paddr_i[7:0] == 8'h04) ||
                      (paddr_i[7:0] == 8'h08))),
      .err_o  (cfg_err_o)
  );

endmodule
