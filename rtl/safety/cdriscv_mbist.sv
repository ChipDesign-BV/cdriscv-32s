// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s -- memory BIST controller (March C-), APB slave.
//
// March C- covers stuck-at, transition, address decoder and most
// coupling faults in 10n operations:
//
//   1  up    w0
//   2  up    r0 w1
//   3  up    r1 w0
//   4  down  r0 w1
//   5  down  r1 w0
//   6  up    r0
//
// The controller drives the raw (39 bit) test port of a TCM, so it also
// tests the check bit storage, which the functional path can only reach
// indirectly.  Running the BIST destroys the memory contents; the
// intended use is a start-up test with the core still held in reset
// (AutoStart), before the application image is loaded.
//
//   +0x00  CTRL    RW  [0] start (self clearing) [1] abort
//   +0x04  STATUS  RO  [0] busy [1] done [2] fail [6:4] march element
//   +0x08  FAILADR RO  first failing address
//   +0x0c  FAILDAT RO  data read at the first failing address, bits 31:0
//   +0x10  FAILDATH RO the same word's seven ECC check bits, [38:32]
//
// Each controller decodes 32 bytes, so the two of them sit at +0x00
// and +0x40 without overlapping.
//
// STATUS: NOT VERIFIED YET -- DO NOT USE YET.

`default_nettype none

module cdriscv_mbist #(
    parameter int unsigned Depth     = 4096,
    parameter logic [7:0]  RegBase   = 8'h00,
    parameter bit          AutoStart = 1'b0
)(
    input  logic        clk_i,
    input  logic        rst_ni,

    input  logic        psel_i,
    input  logic        penable_i,
    input  logic [11:0] paddr_i,
    input  logic        pwrite_i,
    input  logic [31:0] pwdata_i,
    output logic [31:0] prdata_o,
    output logic        psel_hit_o,     // this instance owns paddr_i
    output logic        pready_o,
    output logic        pslverr_o,

    output logic        busy_o,
    output logic        done_o,
    output logic        fail_o,

    // raw memory test port
    output logic        bist_en_o,
    output logic        bist_we_o,
    output logic [31:0] bist_addr_o,
    output logic [38:0] bist_wdata_o,
    input  logic [38:0] bist_rdata_i
);

  localparam int unsigned AW = (Depth > 1) ? $clog2(Depth) : 1;

  localparam logic [38:0] PatZero = 39'h0;
  localparam logic [38:0] PatOne  = {39{1'b1}};

  typedef enum logic [1:0] {
    BS_IDLE,
    BS_EXEC,
    BS_CAPTURE,
    BS_DONE
  } state_e;

  state_e        state_q, state_d;
  logic [2:0]    elem_q;
  logic          op_q;                 // operation index inside the element
  logic [AW-1:0] addr_q;
  logic          fail_q;
  logic [AW-1:0] fail_addr_q;
  logic [38:0]   fail_data_q;
  logic          start_q, abort_q;

  // ------------------------------------------------------------------
  // March element description
  // ------------------------------------------------------------------
  logic       op_is_write, op_data, elem_down;
  logic       elem_two_ops;

  always_comb begin
    op_is_write  = 1'b1;
    op_data      = 1'b0;
    elem_down    = 1'b0;
    elem_two_ops = 1'b1;

    unique case (elem_q)
      3'd0: begin elem_two_ops = 1'b0; op_is_write = 1'b1; op_data = 1'b0; end
      3'd1: begin op_is_write = op_q;  op_data = op_q;                     end // r0 w1
      3'd2: begin op_is_write = op_q;  op_data = ~op_q;                    end // r1 w0
      3'd3: begin elem_down = 1'b1; op_is_write = op_q; op_data = op_q;    end // r0 w1
      3'd4: begin elem_down = 1'b1; op_is_write = op_q; op_data = ~op_q;   end // r1 w0
      3'd5: begin elem_two_ops = 1'b0; op_is_write = 1'b0; op_data = 1'b0; end // r0
      default: begin elem_two_ops = 1'b0; op_is_write = 1'b1; op_data = 1'b0; end
    endcase
  end

  logic [38:0] op_pattern;
  assign op_pattern = op_data ? PatOne : PatZero;

  logic last_addr, last_op, last_elem;
  assign last_addr = elem_down ? (addr_q == '0) : (addr_q == AW'(Depth - 1));
  assign last_op   = !elem_two_ops || op_q;
  assign last_elem = (elem_q == 3'd5);

  // ------------------------------------------------------------------
  // Sequencer
  // ------------------------------------------------------------------
  logic advance;   // the current operation has completed

  always_comb begin
    state_d = state_q;
    unique case (state_q)
      BS_IDLE:    if (start_q)          state_d = BS_EXEC;
      BS_EXEC:    if (op_is_write)      state_d = BS_EXEC;   // stays, address advances
                  else                  state_d = BS_CAPTURE;
      BS_CAPTURE:                       state_d = BS_EXEC;
      BS_DONE:    if (start_q)          state_d = BS_EXEC;
      default:                          state_d = BS_IDLE;
    endcase
    if (abort_q) state_d = BS_IDLE;
    if ((state_q == BS_EXEC) && op_is_write && last_op && last_addr && last_elem) begin
      state_d = BS_DONE;
    end
    if ((state_q == BS_CAPTURE) && last_op && last_addr && last_elem) begin
      state_d = BS_DONE;
    end
  end

  // an operation completes at the end of BS_EXEC for writes and at the
  // end of BS_CAPTURE for reads
  assign advance = ((state_q == BS_EXEC) && op_is_write) || (state_q == BS_CAPTURE);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q     <= BS_IDLE;
      elem_q      <= 3'd0;
      op_q        <= 1'b0;
      addr_q      <= '0;
      fail_q      <= 1'b0;
      fail_addr_q <= '0;
      fail_data_q <= '0;
    end else begin
      state_q <= state_d;

      if (start_q) begin
        elem_q      <= 3'd0;
        op_q        <= 1'b0;
        addr_q      <= '0;
        fail_q      <= 1'b0;
        fail_addr_q <= '0;
        fail_data_q <= '0;
      end else if (advance) begin
        if (!last_op) begin
          op_q <= 1'b1;
        end else begin
          op_q <= 1'b0;
          if (!last_addr) begin
            addr_q <= elem_down ? (addr_q - 1'b1) : (addr_q + 1'b1);
          end else begin
            elem_q <= elem_q + 3'd1;
            // the next element starts at the far end when it counts down
            addr_q <= ((elem_q == 3'd2) || (elem_q == 3'd3)) ? AW'(Depth - 1) : '0;
          end
        end
      end

      // read data check
      if ((state_q == BS_CAPTURE) && !fail_q) begin
        if (bist_rdata_i != op_pattern) begin
          fail_q      <= 1'b1;
          fail_addr_q <= addr_q;
          fail_data_q <= bist_rdata_i;
        end
      end
    end
  end

  // ------------------------------------------------------------------
  // Memory port
  // ------------------------------------------------------------------
  assign busy_o       = (state_q == BS_EXEC) || (state_q == BS_CAPTURE);
  assign bist_en_o    = busy_o;
  assign bist_we_o    = (state_q == BS_EXEC) && op_is_write;
  assign bist_addr_o  = {{(32-AW-2){1'b0}}, addr_q, 2'b00};
  assign bist_wdata_o = op_pattern;

  assign done_o = (state_q == BS_DONE);
  assign fail_o = fail_q;

  // ------------------------------------------------------------------
  // APB
  // ------------------------------------------------------------------
  // Each controller claims 32 bytes, not 16.  It used to claim 16, and
  // that is why finding V0-F1 sat open: the fix it proposed put
  // FAILDAT_HI at +0x10, which was outside the range the controller
  // decoded, so the register would have answered with a bus error.
  // Widening the claim by one address bit leaves the two controllers
  // where they were -- the I-TCM one at +0x00 now owns 0x00..0x1f and
  // the D-TCM one at +0x40 owns 0x40..0x5f -- and they still do not
  // overlap.
  logic wr, rd;
  assign psel_hit_o = psel_i && (paddr_i[7:5] == RegBase[7:5]);
  assign wr = psel_hit_o && penable_i &&  pwrite_i;
  assign rd = psel_hit_o && !pwrite_i;

  logic [4:0] reg_ofs;
  assign reg_ofs = paddr_i[4:0];

  logic auto_start_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      start_q      <= 1'b0;
      abort_q      <= 1'b0;
      auto_start_q <= AutoStart;
    end else begin
      start_q      <= 1'b0;
      abort_q      <= 1'b0;
      auto_start_q <= 1'b0;
      if (auto_start_q) start_q <= 1'b1;
      if (wr && (reg_ofs == 5'h00)) begin
        start_q <= pwdata_i[0];
        abort_q <= pwdata_i[1];
      end
    end
  end

  always_comb begin
    prdata_o = 32'b0;
    if (rd) begin
      unique case (reg_ofs)
        5'h00:   prdata_o = 32'b0;
        5'h04:   prdata_o = {25'b0, elem_q, 1'b0, fail_q, done_o, busy_o};
        5'h08:   prdata_o = {{(32-AW){1'b0}}, fail_addr_q};
        5'h0c:   prdata_o = fail_data_q[31:0];
        // The seven check bits of the failing code word.  Without them
        // a failure in the check-bit half of the array -- the part only
        // the raw test port can reach -- could not be diagnosed at all.
        5'h10:   prdata_o = {25'b0, fail_data_q[38:32]};
        default: prdata_o = 32'b0;
      endcase
    end
  end

  assign pready_o  = 1'b1;
  assign pslverr_o = 1'b0;

endmodule
