// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// KMAC/SHA3

`include "prim_assert.sv"

module kmac
  import kmac_pkg::*;
#(
  // EnMasking: Enable masking security hardening inside keccak_round
  // If it is enabled, the result digest will be two set of 1600bit.
  parameter int EnMasking = 0,

  // ReuseShare: If set, keccak_round logic only consumes small portion of
  // entropy, not 1600bit of entropy at every round. It uses adjacent shares
  // as entropy inside Domain-Oriented Masking AND logic.
  // This parameter only affects when `EnMasking` is set.
  parameter int ReuseShare = 0
) (
  input clk_i,
  input rst_ni,

  input  tlul_pkg::tl_h2d_t tl_i,
  output tlul_pkg::tl_d2h_t tl_o,

  // interrupts
  output logic intr_kmac_done_o,
  output logic intr_fifo_empty_o,
  output logic intr_kmac_err_o
);

  import kmac_reg_pkg::*;

  ////////////////
  // Parameters //
  ////////////////
  localparam int Share = (EnMasking) ? 2 : 1 ;

  /////////////////
  // Definitions //
  /////////////////

  /////////////
  // Signals //
  /////////////
  kmac_reg2hw_t reg2hw;
  kmac_hw2reg_t hw2reg;

  // devmode signals comes from LifeCycle.
  // TODO: Implement
  logic devmode;
  assign devmode = 1'b 1;

  // Window
  typedef enum int {
    WinState   = 0,
    WinMsgFifo = 1
  } tl_window_e;

  tlul_pkg::tl_h2d_t tl_win_h2d[2];
  tlul_pkg::tl_d2h_t tl_win_d2h[2];

  // SHA3 core control signals and its response.
  // Sequence: start --> process(multiple) --> get absorbed event --> {run -->} done
  logic sha3_start, sha3_run, sha3_done, sha3_absorbed;

  // Prefix: kmac_pkg defines Prefix based on N size and S size.
  // Then computes left_encode(len(N)) size and left_encode(len(S))
  // For given default value 32, 256 bits, the max
  // encode_string(N) || encode_string(S) is 328. So 11 Prefix registers are
  // created.
  logic [kmac_pkg::NSRegisterSize*8-1:0] ns_prefix;

  // NumWordsPrefix from kmac_reg_pkg
  `ASSERT_INIT(PrefixRegSameToPrefixPkg_A,
               kmac_reg_pkg::NumWordsPrefix*4 == kmac_pkg::NSRegisterSize)

  // Output state: this is used to redirect the digest to KeyMgr or Software
  // depends on the configuration.
  logic state_valid;
  logic [kmac_pkg::StateW-1:0] state [Share];

  // SHA3 Entropy interface
  logic sha3_rand_valid, sha3_rand_consumed;
  logic [kmac_pkg::StateW-1:0] sha3_rand_data;
  // TODO: Connect to entropy when ready
  assign sha3_rand_valid = 1'b 1;
  assign sha3_rand_data = '0;

  // FIFO related signals
  logic msgfifo_empty, msgfifo_full;
  logic [kmac_pkg::MsgFifoDepthW-1:0] msgfifo_depth;

  logic                          msgfifo_valid       ;
  logic [kmac_pkg::MsgWidth-1:0] msgfifo_data [Share];
  logic [kmac_pkg::MsgStrbW-1:0] msgfifo_strb        ;
  logic                          msgfifo_ready       ;

  if (EnMasking) begin : msgfifo_data_masked
    // In Masked mode, the input message data is split into two shares.
    // Only concern, however, here is the secret key. So message can be
    // put into only one share and other is 0.
    assign msgfifo_data[1] = '0;
  end

  // Process control signals
  // Process pulse propagates from register to SHA3 engine one by one.
  // Each module (MSG_FIFO, KMAC core, SHA3 core) generates the process pulse
  // after flushing internal data to the next module.
  logic reg2msgfifo_process, msgfifo2kmac_process, kmac2sha3_process;

  // SHA3 Error response
  err_t sha3_err;

  //////////////////////////////////////
  // Connecting Register IF to logics //
  //////////////////////////////////////

  // Function-name N and Customization input string S
  always_comb begin
    for (int i = 0 ; i < NumWordsPrefix; i++) begin
      ns_prefix[32*i+:32] = reg2hw.prefix[NumWordsPrefix-1 - i].q;
    end
  end

  // Command signals
  // TODO: FI tolerant?
  // TODO: Revise after KMAC core is designed
  assign sha3_start   = reg2hw.cmd.start.qe   & reg2hw.cmd.start.q   ;
  assign sha3_run     = reg2hw.cmd.run.qe     & reg2hw.cmd.run.q     ;
  assign sha3_done    = reg2hw.cmd.done.qe    & reg2hw.cmd.done.q    ;

  assign reg2msgfifo_process = reg2hw.cmd.process.qe & reg2hw.cmd.process.q ;

  // TODO: disconnect below after kmac core implemented
  assign kmac2sha3_process = msgfifo2kmac_process;

  // Status register ==========================================================
  // SHA3 Idle, Absorb, Squeeze aren't exposed yet.
  // TODO: implement
  assign hw2reg.status.sha3_idle.d     = 1'b 0;
  assign hw2reg.status.sha3_absorb.d   = 1'b 0;
  assign hw2reg.status.sha3_squeeze.d  = 1'b 0;

  // FIFO related status
  // TODO: handle if register width of `depth` is not same to MsgFifoDepthW
  assign hw2reg.status.fifo_depth.d[MsgFifoDepthW-1:0] = msgfifo_depth;
  assign hw2reg.status.fifo_empty.d  = msgfifo_empty;
  assign hw2reg.status.fifo_full.d   = msgfifo_full;

  // Configuration Register
  // TODO: Guard CFG write in operation
  logic engine_stable;
  assign engine_stable = 1'b 1;

  assign hw2reg.cfg_regwen.d = engine_stable;

  ///////////////
  // Interrupt //
  ///////////////

  logic event_msgfifo_empty, msgfifo_empty_q;

  // Hash process absorbed interrupt
  prim_intr_hw #(.Width(1)) intr_kmac_done (
    .clk_i,
    .rst_ni,
    .event_intr_i           (sha3_absorbed),
    .reg2hw_intr_enable_q_i (reg2hw.intr_enable.kmac_done.q),
    .reg2hw_intr_test_q_i   (reg2hw.intr_test.kmac_done.q),
    .reg2hw_intr_test_qe_i  (reg2hw.intr_test.kmac_done.qe),
    .reg2hw_intr_state_q_i  (reg2hw.intr_state.kmac_done.q),
    .hw2reg_intr_state_de_o (hw2reg.intr_state.kmac_done.de),
    .hw2reg_intr_state_d_o  (hw2reg.intr_state.kmac_done.d),
    .intr_o                 (intr_kmac_done_o)
  );

  `ASSERT(Sha3AbsorbedPulse_A, $rose(sha3_absorbed) |=> !sha3_absorbed)

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) msgfifo_empty_q <= 1'b1;
    else         msgfifo_empty_q <= msgfifo_empty;
  end

  assign event_msgfifo_empty = ~msgfifo_empty_q & msgfifo_empty;

  prim_intr_hw #(.Width(1)) intr_fifo_empty (
    .clk_i,
    .rst_ni,
    .event_intr_i           (event_msgfifo_empty),
    .reg2hw_intr_enable_q_i (reg2hw.intr_enable.fifo_empty.q),
    .reg2hw_intr_test_q_i   (reg2hw.intr_test.fifo_empty.q),
    .reg2hw_intr_test_qe_i  (reg2hw.intr_test.fifo_empty.qe),
    .reg2hw_intr_state_q_i  (reg2hw.intr_state.fifo_empty.q),
    .hw2reg_intr_state_de_o (hw2reg.intr_state.fifo_empty.de),
    .hw2reg_intr_state_d_o  (hw2reg.intr_state.fifo_empty.d),
    .intr_o                 (intr_fifo_empty_o)
  );

  // TODO: Error

  ///////////////
  // Instances //
  ///////////////

  // SHA3 hashing engine
  sha3core #(
    .EnMasking (EnMasking),
    .ReuseShare (ReuseShare)
  ) u_sha3 (
    .clk_i,
    .rst_ni,

    // MSG_FIFO interface (or from KMAC)
    .msg_valid_i (msgfifo_valid),
    .msg_data_i  (msgfifo_data), // always store to 0 regardless of EnMasking
    .msg_strb_i  (msgfifo_strb),
    .msg_ready_o (msgfifo_ready),

    // Entropy interface
    .rand_valid_i    (sha3_rand_valid),
    .rand_data_i     (sha3_rand_data),
    .rand_consumed_o (sha3_rand_consumed),

    // N, S: Used in cSHAKE mode
    .ns_data_i       (ns_prefix),

    // Configurations
    .mode_i     (sha3_mode_e'(reg2hw.cfg.mode.q)),
    .strength_i (keccak_strength_e'(reg2hw.cfg.strength.q)),

    // Controls (CMD register)
    .start_i    (sha3_start       ),
    .process_i  (kmac2sha3_process),
    .run_i      (sha3_run         ),
    .done_i     (sha3_done        ),

    .absorbed_o (sha3_absorbed),

    .state_valid_o (state_valid),
    .state_o       (state), // [Share]

    .error_o (sha3_err)
  );

  // Message FIFO
  kmac_msgfifo #(
    .InWidth (32),
    .InDepth (512), // Shall be matched to the reg window size
    .OutWidth (kmac_pkg::MsgWidth),
    .MsgDepth (kmac_pkg::MsgFifoDepth)
  ) u_msgfifo (
    .clk_i,
    .rst_ni,

    .tl_i (tl_win_h2d[WinMsgFifo]),
    .tl_o (tl_win_d2h[WinMsgFifo]),

    .msg_valid_o (msgfifo_valid),
    .msg_data_o  (msgfifo_data[0]),
    .msg_strb_o  (msgfifo_strb),
    .msg_ready_i (msgfifo_ready),

    .fifo_empty_o (msgfifo_emtpy), // intr and status
    .fifo_full_o  (msgfifo_full),  // connected to status only
    .fifo_depth_o (msgfifo_depth),

    .endian_swap_i (reg2hw.cfg.msg_endianness.q),

    .clear_i (sha3_done),

    .process_i (reg2msgfifo_process ),
    .process_o (msgfifo2kmac_process)
  );

  // State (Digest) reader
  kmac_staterd #(
    .AddrW     (9), // 512B
    .EnMasking (EnMasking)
  ) u_staterd (
    .clk_i,
    .rst_ni,

    .tl_i (tl_win_h2d[WinState]),
    .tl_o (tl_win_d2h[WinState]),

    .valid_i (state_valid),
    .state_i (state),

    .endian_swap_i (reg2hw.cfg.state_endianness.q)
  );

  // Register top
  kmac_reg_top u_reg (
    .clk_i,
    .rst_ni,

    .tl_i,
    .tl_o,

    .tl_win_o (tl_win_h2d),
    .tl_win_i (tl_win_d2h),

    .reg2hw,
    .hw2reg,

    .devmode_i (devmode)
  );

  ////////////////
  // Assertions //
  ////////////////

  // Assert known for output values
  `ASSERT_KNOWN(KmacDone_A, intr_kmac_done_o)
  `ASSERT_KNOWN(FifoEmpty_A, intr_fifo_empty_o)
  `ASSERT_KNOWN(KmacErr_A, intr_kmac_err_o)

endmodule

