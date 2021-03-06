// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`include "prim_assert.sv"

package otbn_pkg;

  // Global Constants ==============================================================================

  // Data path width for BN (wide) instructions, in bits.
  parameter int WLEN = 256;

  // Number of 32-bit words per WLEN
  parameter int BaseWordsPerWLEN = WLEN / 32;

  // Number of flag groups
  parameter int NFlagGroups = 2;

  // Width of the GPR index/address
  parameter int GprAw = 5;

  // Number of General Purpose Registers (GPRs)
  parameter int NGpr = 2 ** GprAw;

  // Width of the WDR index/address
  parameter int WdrAw = 5;

  // Number of Wide Data Registers (WDRs)
  parameter int NWdr = 2 ** WdrAw;


  // Toplevel constants ============================================================================

  parameter int AlertImemUncorrectable = 0;
  parameter int AlertDmemUncorrectable = 1;
  parameter int AlertRegUncorrectable = 2;

  // Error codes
  typedef enum logic [31:0] {
    ErrCodeNoError     = 32'h 0000_0000,
    ErrCodeBadDataAddr = 32'h 0000_0001
  } err_code_e;

  // Constants =====================================================================================

  typedef enum logic {
    InsnSubsetBase = 1'b0,  // Base (RV32/Narrow) Instruction Subset
    InsnSubsetBignum = 1'b1 // Big Number (BN/Wide) Instruction Subset
  } insn_subset_e;

  // Opcodes (field [6:0] in the instruction), matching the RISC-V specification for the base
  // instruction subset.
  typedef enum logic [6:0] {
    InsnOpcodeBaseLoad           = 7'h03,
    InsnOpcodeBaseMemMisc        = 7'h0f,
    InsnOpcodeBaseOpImm          = 7'h13,
    InsnOpcodeBaseAuipc          = 7'h17,
    InsnOpcodeBaseStore          = 7'h23,
    InsnOpcodeBaseOp             = 7'h33,
    InsnOpcodeBaseLui            = 7'h37,
    InsnOpcodeBaseBranch         = 7'h63,
    InsnOpcodeBaseJalr           = 7'h67,
    InsnOpcodeBaseJal            = 7'h6f,
    InsnOpcodeBaseSystem         = 7'h73,
    InsnOpcodeBignumMisc         = 7'h0B,
    InsnOpcodeBignumArith        = 7'h2B,
    InsnOpcodeBignumMulqacc      = 7'h3B,
    InsnOpcodeBignumShiftLogical = 7'h7B
  } insn_opcode_e;

  typedef enum logic [3:0] {
    AluOpBaseAdd,
    AluOpBaseSub,

    AluOpBaseXor,
    AluOpBaseOr,
    AluOpBaseAnd,
    AluOpBaseNot,

    AluOpBaseSra,
    AluOpBaseSrl,
    AluOpBaseSll
  } alu_op_base_e;

  // TODO: Can we arrange this to simplify decoding logic?
  typedef enum logic [3:0] {
    AluOpBignumAdd,
    AluOpBignumAddc,
    AluOpBignumAddm,

    AluOpBignumSub,
    AluOpBignumSubb,
    AluOpBignumSubm,

    AluOpBignumRshi,

    AluOpBignumXor,
    AluOpBignumOr,
    AluOpBignumAnd,
    AluOpBignumNot
  } alu_op_bignum_e;

  typedef enum logic {
    ComparisonOpBaseEq,
    ComparisonOpBaseNeq
  } comparison_op_base_e;

  // Operand a source selection
  typedef enum logic [1:0] {
    OpASelRegister  = 'd0,
    OpASelZero = 'd1,
    OpASelFwd = 'd2,
    OpASelCurrPc = 'd3
  } op_a_sel_e;

  // Operand b source selection
  typedef enum logic {
    OpBSelRegister  = 1'b0,
    OpBSelImmediate = 1'b1
  } op_b_sel_e;

  // Immediate a selection for base ISA
  typedef enum logic {
    ImmBaseAZero
  } imm_a_sel_base_e;

  // Immediate b selection for base ISA
  typedef enum logic [2:0] {
    ImmBaseBI,
    ImmBaseBS,
    ImmBaseBB,
    ImmBaseBU,
    ImmBaseBJ
  } imm_b_sel_base_e;

  // Shift amount select for bignum ISA
  typedef enum logic {
    ShamtSelBignumA,
    ShamtSelBignumS
  } shamt_sel_bignum_e;

  // Regfile write data selection
  typedef enum logic [1:0] {
    RfWdSelEx,
    RfWdSelNextPc,
    RfWdSelLsu,
    RfWdSelIspr
  } rf_wd_sel_e;

  // Control and Status Registers (CSRs)
  parameter int CsrNumWidth = 12;
  typedef enum logic [CsrNumWidth-1:0] {
    CsrFlags = 12'h7C0,
    CsrMod0  = 12'h7D0,
    CsrMod1  = 12'h7D1,
    CsrMod2  = 12'h7D2,
    CsrMod3  = 12'h7D3,
    CsrMod4  = 12'h7D4,
    CsrMod5  = 12'h7D5,
    CsrMod6  = 12'h7D6,
    CsrMod7  = 12'h7D7,
    CsrRnd   = 12'hFC0
  } csr_e;

  // Wide Special Purpose Registers (WSRs)
  parameter int NWsr = 3; // Number of WSRs
  parameter int WsrNumWidth = $clog2(NWsr);
  typedef enum logic [WsrNumWidth-1:0] {
    WsrMod   = 'd0,
    WsrRnd   = 'd1,
    WsrAcc   = 'd2
  } wsr_e;

  // Internal Special Purpose Registers (ISPRs)
  // CSRs and WSRs have some overlap into what they map into. ISPRs are the actual registers in the
  // design which CSRs and WSRs are mapped on to.
  parameter int NIspr = NWsr + 1;
  parameter int IsprNumWidth = $clog2(NIspr);
  typedef enum logic [IsprNumWidth-1:0] {
    IsprMod   = 'd0,
    IsprRnd   = 'd1,
    IsprAcc   = 'd2,
    IsprFlags = 'd3
  } ispr_e;

  typedef logic [$clog2(NFlagGroups)-1:0] flag_group_t;

  typedef struct packed {
    logic Z;
    logic M;
    logic L;
    logic C;
  } flags_t;

  localparam int FlagsWidth = $bits(flags_t);

  // TODO: Figure out how to add assertions for the enum type width; initial blocks, as produced by
  // ASSERT_INIT, aren't allowed in packages.
  //`ASSERT_INIT(WsrESizeMatchesParameter_A, $bits(wsr_e) == WsrNumWidth)

  // Structures for decoded instructions, grouped into three:
  // - insn_dec_shared_t - Anything that applies to both bignum and base ISAs, all fields valid when
  // instruction is valid.
  // - insn_dec_base_t - Anything that only applies to base ISA, fields only valid when `subset` in
  // `insn_dec_shared_t` indicates a base ISA instruction.
  // - insn_dec_bignum_t - Anything that only applies to bignum ISA, fields only valid when `subset` in
  // `insn_dec_shared_t` indicates a bignum ISA instruction.
  //
  // TODO: The variable names are rather short, especially "i" is confusing. Think about renaming.
  //
  typedef struct packed {
    insn_subset_e   subset;
    op_a_sel_e      op_a_sel;
    op_b_sel_e      op_b_sel;
    logic           rf_we;
    rf_wd_sel_e     rf_wdata_sel;
    logic           ecall_insn;
    logic           ld_insn;
    logic           st_insn;
    logic           branch_insn;
    logic           jump_insn;
    logic           ispr_rw_insn;
    logic           ispr_rs_insn;
  } insn_dec_shared_t;

  typedef struct packed {
    logic [4:0]          d;             // Destination register
    logic [4:0]          a;             // First source register
    logic [4:0]          b;             // Second source register
    logic [31:0]         i;             // Immediate
    alu_op_base_e        alu_op;
    comparison_op_base_e comparison_op;
  } insn_dec_base_t;

  typedef struct packed {
    logic [WdrAw-1:0]        d;           // Destination register
    logic [WdrAw-1:0]        a;           // First source register
    logic [WdrAw-1:0]        b;           // Second source register
    logic [WLEN-1:0]         i;           // Immediate

    // Shifting only applies to a subset of ALU operations
    logic [$clog2(WLEN)-1:0] shift_amt;   // Shift amount
    logic                    shift_right; // Shift right if set otherwise left

    flag_group_t             flag_group;
    alu_op_bignum_e          alu_op;
  } insn_dec_bignum_t;

  typedef struct packed {
    alu_op_base_e     op;
    logic [31:0] operand_a;
    logic [31:0] operand_b;
  } alu_base_operation_t;

  typedef struct packed {
    comparison_op_base_e op;
    logic [31:0] operand_a;
    logic [31:0] operand_b;
  } alu_base_comparison_t;

  typedef struct packed {
    alu_op_bignum_e op;
    logic [WLEN-1:0]         operand_a;
    logic [WLEN-1:0]         operand_b;
    logic                    shift_right;
    logic [$clog2(WLEN)-1:0] shift_amt;
    flag_group_t             flag_group;
  } alu_bignum_operation_t;

endpackage
