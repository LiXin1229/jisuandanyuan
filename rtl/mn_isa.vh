`ifndef MN_ISA_VH
`define MN_ISA_VH
`define MN_OP_PW   4'd0
`define MN_OP_NORM 4'd1
`define MN_OP_DW   4'd2
`define MN_OP_NOP  4'd3
`define MN_OP_CONV 4'd4
`define MN_OP_ADD  4'd5
`define MN_ACT_NONE 2'd0
`define MN_ACT_RELU 2'd1
`define MN_ACT_RELU6 2'd2
`define MN_PAD_NONE 2'd0
`define MN_PAD_ZERO 2'd1
`define MN_PAD_REFLECT 2'd2
`define MN_WRITE_FULL 3'd0
// Instruction fields: see docs/implementation.md.
`endif
