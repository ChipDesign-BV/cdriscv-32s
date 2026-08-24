// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s -- analog / mixed-signal interface, APB slave.
//
// This is the block that makes the subsystem useful in a mixed-signal
// SoC: it sequences an on-chip ADC, keeps the last conversion result
// per channel, checks every result against a programmable window, and
// drives the trim/DAC and analog test bus controls.  A conversion that
// never answers (analog block stuck, missing clock, missing bias) times
// out, so the digital side always makes progress.
//
// Out-of-range results and the analog flag inputs are routed to the
// safety controller, which turns the analog domain into a monitored
// safety element rather than an unobserved black box.
//
//   0x00        CTRL     RW [0] sequencer enable [1] continuous
//                           [2] analog test enable [7:4] test mux select
//                           [8] interrupt enable
//   0x04        PERIOD   RW cycles between two sequencer starts
//   0x08        CHMASK   RW [NumCh-1:0] channels to convert
//   0x0c        STATUS   RW [0] busy [1] done (W1C) [2] timeout (W1C)
//                           [23:8] out of range per channel (W1C)
//                           [27:24] analog flag inputs (level)
//   0x10+4n     RESULT n RO last conversion result of channel n
//   0x30+4n     LIMIT  n RW [15:0] low limit, [31:16] high limit
//   0x50        DAC      RW [AdcW-1:0] trim / DAC output, write strobes dac_we_o
//   0x54        FLAGCFG  RW [3:0] analog flag inputs that raise a fault
//   0x58        TIMEOUT  RW [15:0] conversion time-out in cycles
//
// STATUS: verified to the O1-O7 gate of doc/verification_plan.md
//         (2026-08-24) -- may be used in a project.  O8-O9 and the
//         FMEDA are open: NOT qualified for safety-critical use.

`default_nettype none

module cdriscv_ams_if #(
    parameter int unsigned NumCh = 8,
    parameter int unsigned AdcW  = 12
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

    // ADC control
    output logic                 adc_start_o,
    output logic [2:0]           adc_ch_o,
    input  logic                 adc_valid_i,
    input  logic [AdcW-1:0]      adc_data_i,

    // DAC / trim
    output logic [AdcW-1:0]      dac_data_o,
    output logic                 dac_we_o,

    // analog test bus
    output logic                 atest_en_o,
    output logic [3:0]           atest_sel_o,

    // analog supervisor flags (asynchronous)
    input  logic [3:0]           ana_flag_i,

    // to the interrupt controller / safety controller
    output logic                 irq_o,
    output logic                 fault_o,
    output logic                 cfg_err_o   // level: configuration parity mismatch
);

  // ------------------------------------------------------------------
  // Registers
  // ------------------------------------------------------------------
  logic              seq_en_q, cont_q, atest_en_q, irq_en_q;
  logic [3:0]        atest_sel_q;
  logic [31:0]       period_q;
  logic [NumCh-1:0]  chmask_q;
  logic              sts_done_q, sts_timeout_q;
  logic [NumCh-1:0]  sts_range_q;
  logic [3:0]        flagcfg_q;
  logic [15:0]       timeout_q;
  logic [AdcW-1:0]   dac_q;

  logic [AdcW-1:0]   result_q [NumCh];
  logic [15:0]       lim_lo_q [NumCh];
  logic [15:0]       lim_hi_q [NumCh];

  logic wr, rd;
  assign wr = psel_i && penable_i &&  pwrite_i;
  assign rd = psel_i && !pwrite_i;

  logic [7:0] ofs;
  assign ofs = paddr_i[7:0];

  // word index inside the RESULT (0x10..0x2c) and LIMIT (0x30..0x4c)
  // register arrays
  logic [2:0] res_idx, lim_idx;
  assign res_idx = 3'((ofs - 8'h10) >> 2);
  assign lim_idx = 3'((ofs - 8'h30) >> 2);

  // Written as an if/else chain rather than a `case ... inside` with
  // range items: the register arrays occupy address ranges, and not
  // every simulator accepts range items in a case (Icarus does not).
  logic in_result_range, in_limit_range;
  assign in_result_range = (ofs >= 8'h10) && (ofs < (8'h10 + 8'(4*NumCh)));
  assign in_limit_range  = (ofs >= 8'h30) && (ofs < (8'h30 + 8'(4*NumCh)));

  // ------------------------------------------------------------------
  // Analog flag synchronisation
  // ------------------------------------------------------------------
  logic [3:0] ana_flag_sync;

  for (genvar i = 0; i < 4; i++) begin : g_flag_sync
    cdriscv_sync_lvl #(.Stages(2)) u_sync (
        .clk_i  (clk_i),
        .rst_ni (rst_ni),
        .d_i    (ana_flag_i[i]),
        .q_o    (ana_flag_sync[i])
    );
  end

  // ------------------------------------------------------------------
  // Sequencer
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {
    AS_IDLE,
    AS_START,
    AS_WAIT
  } state_e;

  state_e            state_q, state_d;
  logic [31:0]       period_cnt_q;
  logic [15:0]       to_cnt_q;
  logic [2:0]        ch_q;
  logic              seq_trigger;

  assign seq_trigger = seq_en_q && (period_cnt_q == 32'b0);

  logic ch_selected;
  assign ch_selected = chmask_q[ch_q];

  logic last_ch;
  assign last_ch = (ch_q == 3'(NumCh - 1));

  always_comb begin
    state_d = state_q;
    unique case (state_q)
      AS_IDLE:  if (seq_trigger) state_d = AS_START;
      AS_START: begin
        // no ternary here: the two arms are enum literals and a strict
        // simulator wants an explicit cast on the result
        if (ch_selected) state_d = AS_WAIT;
        else             state_d = AS_START;
      end
      AS_WAIT:  if (adc_valid_i || (to_cnt_q == 16'b0)) state_d = AS_START;
      default:  state_d = AS_IDLE;
    endcase
    // the sequence ends after the last channel
    if ((state_q == AS_START) && !ch_selected && last_ch) state_d = AS_IDLE;
    if ((state_q == AS_WAIT) && (adc_valid_i || (to_cnt_q == 16'b0)) && last_ch) begin
      state_d = AS_IDLE;
    end
    if (!seq_en_q) state_d = AS_IDLE;
  end

  logic conv_done, conv_timeout;
  assign conv_done    = (state_q == AS_WAIT) && adc_valid_i;
  assign conv_timeout = (state_q == AS_WAIT) && !adc_valid_i && (to_cnt_q == 16'b0);

  // range check on the captured result
  logic result_low, result_high, result_bad;
  assign result_low  = ({{(16-AdcW){1'b0}}, adc_data_i} <  lim_lo_q[ch_q]);
  assign result_high = ({{(16-AdcW){1'b0}}, adc_data_i} >  lim_hi_q[ch_q]);
  assign result_bad  = conv_done && (result_low || result_high);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q      <= AS_IDLE;
      period_cnt_q <= 32'b0;
      to_cnt_q     <= 16'b0;
      ch_q         <= 3'b0;
    end else begin
      state_q <= state_d;

      // sequence period
      if (!seq_en_q) begin
        period_cnt_q <= period_q;
      end else if (state_q == AS_IDLE) begin
        if (period_cnt_q != 32'b0) period_cnt_q <= period_cnt_q - 32'd1;
      end else begin
        period_cnt_q <= period_q;
      end

      // channel walk
      if (state_q == AS_IDLE) begin
        ch_q <= 3'b0;
      end else if ((state_q == AS_START) && !ch_selected) begin
        ch_q <= ch_q + 3'd1;
      end else if (conv_done || conv_timeout) begin
        ch_q <= ch_q + 3'd1;
      end

      // conversion time-out
      if (state_q == AS_START) to_cnt_q <= timeout_q;
      else if ((state_q == AS_WAIT) && (to_cnt_q != 16'b0)) to_cnt_q <= to_cnt_q - 16'd1;
    end
  end

  assign adc_start_o = (state_q == AS_START) && ch_selected;
  assign adc_ch_o    = ch_q;

  // ------------------------------------------------------------------
  // Results, limits and control registers
  // ------------------------------------------------------------------
  logic seq_finished;
  assign seq_finished = (state_q != AS_IDLE) && (state_d == AS_IDLE);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      seq_en_q      <= 1'b0;
      cont_q        <= 1'b0;
      atest_en_q    <= 1'b0;
      irq_en_q      <= 1'b0;
      atest_sel_q   <= 4'b0;
      period_q      <= 32'd1000;
      chmask_q      <= '0;
      sts_done_q    <= 1'b0;
      sts_timeout_q <= 1'b0;
      sts_range_q   <= '0;
      flagcfg_q     <= 4'b0;
      timeout_q     <= 16'd1000;
      dac_q         <= '0;
      dac_we_o      <= 1'b0;
      for (int unsigned c = 0; c < NumCh; c++) begin
        result_q[c] <= '0;
        lim_lo_q[c] <= 16'h0000;
        lim_hi_q[c] <= 16'hffff;
      end
    end else begin
      dac_we_o <= 1'b0;

      if (conv_done)    result_q[ch_q] <= adc_data_i;
      if (result_bad)   sts_range_q[ch_q] <= 1'b1;
      if (conv_timeout) sts_timeout_q <= 1'b1;
      if (seq_finished) sts_done_q <= 1'b1;

      // a one shot sequence disarms itself
      if (seq_finished && !cont_q) seq_en_q <= 1'b0;

      if (wr) begin
        unique case (ofs)
          8'h00: begin
            seq_en_q    <= pwdata_i[0];
            cont_q      <= pwdata_i[1];
            atest_en_q  <= pwdata_i[2];
            atest_sel_q <= pwdata_i[7:4];
            irq_en_q    <= pwdata_i[8];
          end
          8'h04: period_q  <= pwdata_i;
          8'h08: chmask_q  <= pwdata_i[NumCh-1:0];
          8'h0c: begin
            if (pwdata_i[1]) sts_done_q    <= 1'b0;
            if (pwdata_i[2]) sts_timeout_q <= 1'b0;
            sts_range_q <= sts_range_q & ~pwdata_i[8 +: NumCh];
          end
          8'h50: begin
            dac_q    <= pwdata_i[AdcW-1:0];
            dac_we_o <= 1'b1;
          end
          8'h54: flagcfg_q <= pwdata_i[3:0];
          8'h58: timeout_q <= pwdata_i[15:0];
          default: begin
            if (in_limit_range) begin
              lim_lo_q[lim_idx] <= pwdata_i[15:0];
              lim_hi_q[lim_idx] <= pwdata_i[31:16];
            end
          end
        endcase
      end
    end
  end

  assign dac_data_o  = dac_q;
  assign atest_en_o  = atest_en_q;
  assign atest_sel_o = atest_sel_q;

  // ------------------------------------------------------------------
  // Read back
  // ------------------------------------------------------------------
  always_comb begin
    prdata_o = 32'b0;
    if (rd) begin
      if (in_result_range) begin
        prdata_o = {{(32-AdcW){1'b0}}, result_q[res_idx]};
      end else if (in_limit_range) begin
        prdata_o = {lim_hi_q[lim_idx], lim_lo_q[lim_idx]};
      end else begin
        unique case (ofs)
          8'h00:   prdata_o = {23'b0, irq_en_q, atest_sel_q, 1'b0, atest_en_q, cont_q, seq_en_q};
          8'h04:   prdata_o = period_q;
          8'h08:   prdata_o = {{(32-NumCh){1'b0}}, chmask_q};
          8'h0c:   prdata_o = {4'b0, ana_flag_sync,
                               {(16-NumCh){1'b0}}, sts_range_q,
                               5'b0, sts_timeout_q, sts_done_q, (state_q != AS_IDLE)};
          8'h50:   prdata_o = {{(32-AdcW){1'b0}}, dac_q};
          8'h54:   prdata_o = {28'b0, flagcfg_q};
          8'h58:   prdata_o = {16'b0, timeout_q};
          default: prdata_o = 32'b0;
        endcase
      end
    end
  end

  assign pready_o  = 1'b1;
  assign pslverr_o = 1'b0;

  assign irq_o   = irq_en_q && (sts_done_q || sts_timeout_q || (|sts_range_q));
  assign fault_o = (|sts_range_q) || sts_timeout_q || (|(ana_flag_sync & flagcfg_q));

  // ------------------------------------------------------------------
  // Configuration parity (V29): the channel mask (90/90 latent in the
  // campaign), the sequencing and test-mux configuration, the limits
  // and the DAC value.  seq_en_q is excluded: a one-shot sequence
  // clears it in hardware, and a self-updating field in the parity
  // vector would raise a permanent false error the first time it did.
  // ------------------------------------------------------------------
  logic [NumCh*32-1:0] lim_flat;
  always_comb begin
    for (int unsigned c = 0; c < NumCh; c++) begin
      lim_flat[c*32 +: 32] = {lim_hi_q[c], lim_lo_q[c]};
    end
  end

  cdriscv_cfg_parity #(.Width(3 + 4 + 32 + NumCh + 4 + 16 + AdcW + NumCh*32))
  u_cfg_par (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .cfg_i  ({cont_q, atest_en_q, irq_en_q, atest_sel_q, period_q,
                chmask_q, flagcfg_q, timeout_q, dac_q, lim_flat}),
      .wr_i   (wr && (ofs != 8'h0c)),
      .err_o  (cfg_err_o)
  );

endmodule
