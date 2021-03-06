// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`include "prim_assert.sv"

/**
 * OTBN instruction Decoder
 */
module otbn_decoder
  import otbn_pkg::*;
(
  // For assertions only.
  input  logic                 clk_i,
  input  logic                 rst_ni,

  // instruction data to be decoded
  input  logic [31:0]          insn_fetch_resp_data_i,
  input  logic                 insn_fetch_resp_valid_i,

  // Decoded instruction
  output logic                 insn_valid_o,
  output logic                 insn_illegal_o,

  output insn_dec_base_t       insn_dec_base_o,
  output insn_dec_bignum_t     insn_dec_bignum_o,
  output insn_dec_shared_t     insn_dec_shared_o
);

  logic        illegal_insn;
  logic        rf_we;

  logic [31:0] insn;
  logic [31:0] insn_alu;

  // Source/Destination register instruction index
  logic [4:0] insn_rs1;
  logic [4:0] insn_rs2;
  logic [4:0] insn_rd;

  insn_opcode_e     opcode;
  insn_opcode_e     opcode_alu;

  // To help timing the flops containing the current instruction are replicated to reduce fan-out.
  // insn_alu is used to determine the ALU control logic and associated operand/imm select signals
  // as the ALU is often on the more critical timing paths. insn is used for everything else.
  // TODO: Actually replicate flops, if needed.
  assign insn     = insn_fetch_resp_data_i;
  assign insn_alu = insn_fetch_resp_data_i;

  //////////////////////////////////////
  // Register and immediate selection //
  //////////////////////////////////////
  imm_a_sel_base_e   imm_a_mux_sel_base; // immediate selection for operand a in base ISA
  imm_b_sel_base_e   imm_b_mux_sel_base; // immediate selection for operand b in base ISA
  shamt_sel_bignum_e shift_amt_mux_sel_bignum; // shift amount selection in bignum ISA

  logic [31:0] imm_i_type_base;
  logic [31:0] imm_s_type_base;
  logic [31:0] imm_b_type_base;
  logic [31:0] imm_u_type_base;
  logic [31:0] imm_j_type_base;

  alu_op_base_e   alu_operator_base;   // ALU operation selection for base ISA
  alu_op_bignum_e alu_operator_bignum; // ALU operation selection for bignum ISA
  op_a_sel_e      alu_op_a_mux_sel;    // operand a selection: reg value, PC, immediate or zero
  op_b_sel_e      alu_op_b_mux_sel;    // operand b selection: reg value or immediate

  comparison_op_base_e comparison_operator_base;

  logic rf_ren_a;
  logic rf_ren_b;

  // immediate extraction and sign extension
  assign imm_i_type_base = { {20{insn[31]}}, insn[31:20] };
  assign imm_s_type_base = { {20{insn[31]}}, insn[31:25], insn[11:7] };
  assign imm_b_type_base = { {19{insn[31]}}, insn[31], insn[7], insn[30:25], insn[11:8], 1'b0 };
  assign imm_u_type_base = { insn[31:12], 12'b0 };
  assign imm_j_type_base = { {12{insn[31]}}, insn[19:12], insn[20], insn[30:21], 1'b0 };

  logic [WLEN-1:0] imm_i_type_bignum;

  assign imm_i_type_bignum = {{(WLEN-10){1'b0}}, insn[29:20]};

  // Shift amount for ALU instructions other than BN.RSHI
  logic [$clog2(WLEN)-1:0] shift_amt_a_type_bignum;
  // Shift amount for BN.RSHI
  logic [$clog2(WLEN)-1:0] shift_amt_s_type_bignum;

  assign shift_amt_a_type_bignum = {insn[29:25], 3'b0};
  assign shift_amt_s_type_bignum = {insn[31:25], insn[14]};

  logic shift_right_bignum;

  assign shift_right_bignum = insn[30];

  flag_group_t flag_group_bignum;

  assign flag_group_bignum = insn[31];

  // source registers
  assign insn_rs1 = insn[19:15];
  assign insn_rs2 = insn[24:20];

  // destination register
  assign insn_rd = insn[11:7];

  insn_subset_e insn_subset;
  rf_wd_sel_e rf_wdata_sel;

  logic ecall_insn;
  logic ld_insn;
  logic st_insn;
  logic branch_insn;
  logic jump_insn;
  logic ispr_rw_insn;
  logic ispr_rs_insn;

  // Reduced main ALU immediate MUX for Operand B
  logic [31:0] imm_b_base;
  always_comb begin : immediate_b_mux
    unique case (imm_b_mux_sel_base)
      ImmBaseBI:   imm_b_base = imm_i_type_base;
      ImmBaseBS:   imm_b_base = imm_s_type_base;
      ImmBaseBU:   imm_b_base = imm_u_type_base;
      ImmBaseBB:   imm_b_base = imm_b_type_base;
      ImmBaseBJ:   imm_b_base = imm_j_type_base;
      default: imm_b_base = imm_i_type_base;
    endcase
  end

  logic [$clog2(WLEN)-1:0] shift_amt_bignum;
  always_comb begin
    unique case (shift_amt_mux_sel_bignum)
      ShamtSelBignumA: shift_amt_bignum = shift_amt_a_type_bignum;
      ShamtSelBignumS: shift_amt_bignum = shift_amt_s_type_bignum;
      default:      shift_amt_bignum = shift_amt_a_type_bignum;
    endcase
  end

  assign insn_valid_o   = insn_fetch_resp_valid_i & ~illegal_insn;
  assign insn_illegal_o = insn_fetch_resp_valid_i & illegal_insn;

  assign insn_dec_base_o = '{
    a:             insn_rs1,
    b:             insn_rs2,
    d:             insn_rd,
    i:             imm_b_base,
    alu_op:        alu_operator_base,
    comparison_op: comparison_operator_base
  };

  assign insn_dec_bignum_o = '{
    a:           insn_rs1,
    b:           insn_rs2,
    d:           insn_rd,
    i:           imm_i_type_bignum,
    shift_amt:   shift_amt_bignum,
    shift_right: shift_right_bignum,
    flag_group:  flag_group_bignum,
    alu_op:      alu_operator_bignum
  };

  assign insn_dec_shared_o = '{
    subset:        insn_subset,
    op_a_sel:      alu_op_a_mux_sel,
    op_b_sel:      alu_op_b_mux_sel,
    rf_we:         rf_we,
    rf_wdata_sel:  rf_wdata_sel,
    ecall_insn:    ecall_insn,
    ld_insn:       ld_insn,
    st_insn:       st_insn,
    branch_insn:   branch_insn,
    jump_insn:     jump_insn,
    ispr_rw_insn:  ispr_rw_insn,
    ispr_rs_insn:  ispr_rs_insn
  };

  /////////////
  // Decoder //
  /////////////

  always_comb begin
    rf_wdata_sel          = RfWdSelEx;
    rf_we                 = 1'b0;
    rf_ren_a              = 1'b0;
    rf_ren_b              = 1'b0;

    illegal_insn          = 1'b0;
    ecall_insn            = 1'b0;
    ld_insn               = 1'b0;
    st_insn               = 1'b0;
    branch_insn           = 1'b0;
    jump_insn             = 1'b0;
    ispr_rw_insn          = 1'b0;
    ispr_rs_insn          = 1'b0;

    opcode                = insn_opcode_e'(insn[6:0]);

    unique case (opcode)
      //////////////
      // Base ALU //
      //////////////

      InsnOpcodeBaseLui: begin  // Load Upper Immediate
        insn_subset      = InsnSubsetBase;
        rf_we            = 1'b1;
      end

      InsnOpcodeBaseOpImm: begin // Register-Immediate ALU Operations
        insn_subset      = InsnSubsetBase;
        rf_ren_a         = 1'b1;
        rf_we            = 1'b1;

        unique case (insn[14:12])
          3'b000,
          3'b010,
          3'b011,
          3'b100,
          3'b110,
          3'b111: illegal_insn = 1'b0;

          3'b001: begin
            unique case (insn[31:27])
              5'b0_0000: illegal_insn = 1'b0;   // slli
              default: illegal_insn = 1'b1;
            endcase
          end

          3'b101: begin
            if (!insn[26]) begin
              unique case (insn[31:27])
                5'b0_0000,                      // srli
                5'b0_1000: illegal_insn = 1'b0; // srai

                default: illegal_insn = 1'b1;
              endcase
            end
          end

          default: illegal_insn = 1'b1;
        endcase
      end

      InsnOpcodeBaseOp: begin  // Register-Register ALU operation
        insn_subset     = InsnSubsetBase;
        rf_ren_a        = 1'b1;
        rf_ren_b        = 1'b1;
        rf_we           = 1'b1;
        if ({insn[26], insn[13:12]} != {1'b1, 2'b01}) begin
          unique case ({insn[31:25], insn[14:12]})
            // RV32I ALU operations
            {7'b000_0000, 3'b000},
            {7'b010_0000, 3'b000},
            {7'b000_0000, 3'b010},
            {7'b000_0000, 3'b011},
            {7'b000_0000, 3'b100},
            {7'b000_0000, 3'b110},
            {7'b000_0000, 3'b111},
            {7'b000_0000, 3'b001},
            {7'b000_0000, 3'b101},
            {7'b010_0000, 3'b101}: illegal_insn = 1'b0;
            default: begin
              illegal_insn = 1'b1;
            end
          endcase
        end
      end

      ///////////////////////
      // Base Loads/Stores //
      ///////////////////////

      InsnOpcodeBaseLoad: begin
        insn_subset  = InsnSubsetBase;
        ld_insn      = 1'b1;
        rf_ren_a     = 1'b1;
        rf_we        = 1'b1;
        rf_wdata_sel = RfWdSelLsu;

        if (insn[14:12] != 3'b010) begin
          illegal_insn = 1'b1;
        end
      end

      InsnOpcodeBaseStore: begin
        insn_subset = InsnSubsetBase;
        st_insn     = 1'b1;
        rf_ren_a    = 1'b1;
        rf_ren_b    = 1'b1;

        if (insn[14:12] != 3'b010) begin
          illegal_insn = 1'b1;
        end
      end

      //////////////////////
      // Base Branch/Jump //
      //////////////////////

      InsnOpcodeBaseBranch: begin
        insn_subset = InsnSubsetBase;
        branch_insn = 1'b1;
        rf_ren_a    = 1'b1;
        rf_ren_b    = 1'b1;

        // Only EQ & NE comparisons allowed
        if (insn[14:13] != 2'b00) begin
          illegal_insn = 1'b1;
        end
      end

      InsnOpcodeBaseJal: begin
        insn_subset  = InsnSubsetBase;
        jump_insn    = 1'b1;
        rf_we        = 1'b1;
        rf_wdata_sel = RfWdSelNextPc;
      end

      InsnOpcodeBaseJalr: begin
        insn_subset  = InsnSubsetBase;
        jump_insn    = 1'b1;
        rf_ren_a     = 1'b1;
        rf_we        = 1'b1;
        rf_wdata_sel = RfWdSelNextPc;

        if (insn[14:12] != 3'b000) begin
          illegal_insn = 1'b1;
        end
      end

      //////////////////
      // Base Special //
      //////////////////

      InsnOpcodeBaseSystem: begin
        insn_subset = InsnSubsetBase;
        if (insn[14:12] == 3'b000) begin
          // non CSR related SYSTEM instructions
          unique case (insn[31:20])
            12'h000:  // ECALL
              ecall_insn = 1'b1;

            default:
              illegal_insn = 1'b1;
          endcase

          // rs1 and rd must be 0
          if (insn_rs1 != 5'b0 || insn_rd != 5'b0) begin
            illegal_insn = 1'b1;
          end
        end else begin
          rf_we        = 1'b1;
          rf_wdata_sel = RfWdSelIspr;
          rf_ren_a     = 1'b1;

          if (insn[14:12] == 3'b001) begin
            ispr_rw_insn = 1'b1;
          end else if(insn[14:12] == 3'b010) begin
            ispr_rs_insn = 1'b1;
          end else begin
            illegal_insn = 1'b1;
          end
        end
      end

      ////////////////
      // Bignum ALU //
      ////////////////

      InsnOpcodeBignumArith: begin
        insn_subset = InsnSubsetBignum;
        rf_we       = 1'b1;
        rf_ren_a    = 1'b1;

        if (insn[14:12] != 3'b100) begin
          // All Alu instructions other than BN.ADDI/BN.SUBI
          rf_ren_b = 1'b1;
        end

        unique case(insn[14:12])
          3'b110,
          3'b111: illegal_insn = 1'b1;
          default: ;
        endcase
      end

      ////////////////////////
      // Bignum Right Shift //
      ////////////////////////

      InsnOpcodeBignumShiftLogical: begin
        insn_subset = InsnSubsetBignum;
        rf_we       = 1'b1;
        rf_ren_a    = 1'b1;

        // BN.NOT doesn't read register B
        if (insn[14:12] != 3'b101) begin
          rf_ren_b = 1'b1;
        end

        unique case(insn[14:12])
          3'b000,
          3'b001: illegal_insn = 1'b1;
          default: ;
        endcase
      end

      ////////////////////////////
      // Bignum WSR/LID/SID/MOV //
      ////////////////////////////

      InsnOpcodeBignumMisc: begin
        insn_subset = InsnSubsetBignum;

        if (insn[14:12] == 3'b111) begin //BN.WSRRS/BN.WSRRW
          rf_we         = 1'b1;
          rf_ren_a      = 1'b1;
          rf_wdata_sel  = RfWdSelIspr;

          if (insn[31]) begin
            ispr_rw_insn = 1'b1;
          end else begin
            ispr_rs_insn = 1'b1;
          end
        end else begin
          illegal_insn = 1'b1;
        end
      end

      default: illegal_insn = 1'b1;
    endcase


    // make sure illegal instructions detected in the decoder do not propagate from decoder
    // NOTE: instructions can also be detected to be illegal inside the CSRs (upon accesses with
    // insufficient privileges). These cases are not handled here.
    if (illegal_insn) begin
      rf_we           = 1'b0;
    end
  end

  /////////////////////////////
  // Decoder for ALU control //
  /////////////////////////////

  always_comb begin
    alu_operator_base        = AluOpBaseAdd;
    alu_operator_bignum      = AluOpBignumAdd;
    comparison_operator_base = ComparisonOpBaseEq;
    alu_op_a_mux_sel         = OpASelRegister;
    alu_op_b_mux_sel         = OpBSelImmediate;

    imm_a_mux_sel_base       = ImmBaseAZero;
    imm_b_mux_sel_base       = ImmBaseBI;
    shift_amt_mux_sel_bignum = ShamtSelBignumA;

    opcode_alu               = insn_opcode_e'(insn_alu[6:0]);

    unique case (opcode_alu)
      //////////////
      // Base ALU //
      //////////////

      InsnOpcodeBaseLui: begin  // Load Upper Immediate
        alu_op_a_mux_sel   = OpASelZero;
        alu_op_b_mux_sel   = OpBSelImmediate;
        imm_a_mux_sel_base = ImmBaseAZero;
        imm_b_mux_sel_base = ImmBaseBU;
        alu_operator_base  = AluOpBaseAdd;
      end

      InsnOpcodeBaseAuipc: begin  // Add Upper Immediate to PC
        alu_op_a_mux_sel   = OpASelCurrPc;
        alu_op_b_mux_sel   = OpBSelImmediate;
        imm_b_mux_sel_base = ImmBaseBU;
        alu_operator_base  = AluOpBaseAdd;
      end

      InsnOpcodeBaseOpImm: begin // Register-Immediate ALU Operations
        alu_op_a_mux_sel   = OpASelRegister;
        alu_op_b_mux_sel   = OpBSelImmediate;
        imm_b_mux_sel_base = ImmBaseBI;

        unique case (insn_alu[14:12])
          3'b000: alu_operator_base = AluOpBaseAdd;  // Add Immediate
          3'b100: alu_operator_base = AluOpBaseXor;  // Exclusive Or with Immediate
          3'b110: alu_operator_base = AluOpBaseOr;   // Or with Immediate
          3'b111: alu_operator_base = AluOpBaseAnd;  // And with Immediate

          3'b001: begin
            alu_operator_base = AluOpBaseSll; // Shift Left Logical by Immediate
          end

          3'b101: begin
            if (insn_alu[31:27] == 5'b0_0000) begin
              alu_operator_base = AluOpBaseSrl;               // Shift Right Logical by Immediate
            end else if (insn_alu[31:27] == 5'b0_1000) begin
              alu_operator_base = AluOpBaseSra;               // Shift Right Arithmetically by Immediate
            end
          end

          default: ;
        endcase
      end

      InsnOpcodeBaseOp: begin  // Register-Register ALU operation
        alu_op_a_mux_sel = OpASelRegister;
        alu_op_b_mux_sel = OpBSelRegister;

        if (!insn_alu[26]) begin
          unique case ({insn_alu[31:25], insn_alu[14:12]})
            // RV32I ALU operations
            {7'b000_0000, 3'b000}: alu_operator_base = AluOpBaseAdd;   // Add
            {7'b010_0000, 3'b000}: alu_operator_base = AluOpBaseSub;   // Sub
            {7'b000_0000, 3'b100}: alu_operator_base = AluOpBaseXor;   // Xor
            {7'b000_0000, 3'b110}: alu_operator_base = AluOpBaseOr;    // Or
            {7'b000_0000, 3'b111}: alu_operator_base = AluOpBaseAnd;   // And
            {7'b000_0000, 3'b001}: alu_operator_base = AluOpBaseSll;   // Shift Left Logical
            {7'b000_0000, 3'b101}: alu_operator_base = AluOpBaseSrl;   // Shift Right Logical
            {7'b010_0000, 3'b101}: alu_operator_base = AluOpBaseSra;   // Shift Right Arithmetic
            default: ;
          endcase
        end
      end

      ///////////////////////
      // Base Loads/Stores //
      ///////////////////////

      InsnOpcodeBaseLoad: begin
        alu_op_a_mux_sel   = OpASelRegister;
        alu_op_b_mux_sel   = OpBSelImmediate;
        alu_operator_base  = AluOpBaseAdd;
        imm_b_mux_sel_base = ImmBaseBI;
      end

      InsnOpcodeBaseStore: begin
        alu_op_a_mux_sel   = OpASelRegister;
        alu_op_b_mux_sel   = OpBSelImmediate;
        alu_operator_base  = AluOpBaseAdd;
        imm_b_mux_sel_base = ImmBaseBS;
      end

      //////////////////////
      // Base Branch/Jump //
      //////////////////////

      InsnOpcodeBaseBranch: begin
        alu_op_a_mux_sel         = OpASelCurrPc;
        alu_op_b_mux_sel         = OpBSelImmediate;
        alu_operator_base        = AluOpBaseAdd;
        imm_b_mux_sel_base       = ImmBaseBB;
        comparison_operator_base = insn_alu[12] ? ComparisonOpBaseNeq : ComparisonOpBaseEq;
      end

      InsnOpcodeBaseJal: begin
        alu_op_a_mux_sel   = OpASelCurrPc;
        alu_op_b_mux_sel   = OpBSelImmediate;
        alu_operator_base  = AluOpBaseAdd;
        imm_b_mux_sel_base = ImmBaseBJ;
      end

      InsnOpcodeBaseJalr: begin
        alu_op_a_mux_sel   = OpASelRegister;
        alu_op_b_mux_sel   = OpBSelImmediate;
        alu_operator_base  = AluOpBaseAdd;
        imm_b_mux_sel_base = ImmBaseBI;
      end

      //////////////////
      // Base Special //
      //////////////////

      InsnOpcodeBaseSystem: begin
        // The only instructions with System opcode that care about operands are CSR access
        alu_op_a_mux_sel   = OpASelRegister;
        imm_b_mux_sel_base = ImmBaseBI;
      end
      default: ;

      ////////////////
      // Bignum ALU //
      ////////////////

      InsnOpcodeBignumArith: begin
        alu_op_a_mux_sel         = OpASelRegister;
        shift_amt_mux_sel_bignum = ShamtSelBignumA;

        unique case(insn_alu[14:12])
          3'b000: alu_operator_bignum = AluOpBignumAdd;
          3'b001: alu_operator_bignum = AluOpBignumSub;
          3'b010: alu_operator_bignum = AluOpBignumAddc;
          3'b011: alu_operator_bignum = AluOpBignumSubb;
          3'b100: begin
            if (insn_alu[30]) begin
              alu_operator_bignum = AluOpBignumSub;
            end else begin
              alu_operator_bignum = AluOpBignumAdd;
            end
          end
          3'b101: begin
            if (insn_alu[30]) begin
              alu_operator_bignum = AluOpBignumSubm;
            end else begin
              alu_operator_bignum = AluOpBignumAddm;
            end
          end
          default: ;
        endcase

        if (insn_alu[14:12] != 3'b100) begin
          alu_op_b_mux_sel = OpBSelRegister;
        end else begin
          alu_op_b_mux_sel = OpBSelImmediate;
        end
      end

      /////////////////
      // Bignum RSHI //
      /////////////////

      InsnOpcodeBignumShiftLogical: begin
        alu_op_a_mux_sel = OpASelRegister;
        alu_op_b_mux_sel = OpBSelRegister;

        unique case(insn_alu[14:12])
          3'b010: begin
            shift_amt_mux_sel_bignum = ShamtSelBignumA;
            alu_operator_bignum      = AluOpBignumAnd;
          end
          3'b100: begin
            shift_amt_mux_sel_bignum = ShamtSelBignumA;
            alu_operator_bignum      = AluOpBignumOr;
          end
          3'b101: begin
            shift_amt_mux_sel_bignum = ShamtSelBignumA;
            alu_operator_bignum      = AluOpBignumNot;
          end
          3'b110: begin
            shift_amt_mux_sel_bignum = ShamtSelBignumA;
            alu_operator_bignum      = AluOpBignumXor;
          end
          3'b011,
          3'b111: begin
            shift_amt_mux_sel_bignum = ShamtSelBignumS;
            alu_operator_bignum      = AluOpBignumRshi;
          end
          default: ;
        endcase
      end
    endcase
  end

  ////////////////
  // Assertions //
  ////////////////

  // Selectors must be known/valid.
  `ASSERT(IbexRegImmAluOpBaseKnown, (opcode == InsnOpcodeBaseOpImm) |->
      !$isunknown(insn[14:12]))
endmodule
