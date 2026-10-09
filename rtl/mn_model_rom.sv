// Derived from pe10_10/generator/rtl/generator_param_rom.v.
`timescale 1ns/1ps
// Epoch11 output kernel is fixed below.
module mn_model_rom #(parameter PACKED=1)(input wire clk,rd_en,input wire [14:0] addr,output wire [15:0] data);
 generate if(PACKED) begin:g_packed
  // Restore every exact Q8.8 word from compact planes and sparse exceptions.
  // Dense native slices are retained for checkpoints with many large words.
  // Both encodings retain one-cycle read and disabled-cycle output hold.
  localparam WORDS=7==7 ? 22016 : 20992;
  localparam ROWS=(WORDS+4)/5;
  localparam BANKS=(ROWS+511)/512;
  `include "mn_model_params_init.vh"
  if(PARAM_ROM_COMPACT) begin:g_compact
   localparam LOW_BANKS=(WORDS+1023)/1024,HIGH_BANKS=(WORDS+8191)/8192;
   wire [9:0] low_q[0:LOW_BANKS-1];wire high_q[0:HIGH_BANKS-1];
   reg [4:0] low_bank;reg [1:0] high_bank;
   reg exception_valid;reg [15:0] exception_q;
   wire [PARAM_ROM_EXCEPTION_COUNT>0 ? PARAM_ROM_EXCEPTION_COUNT-1 : 0:0] hit;
   genvar b,e;
   if(PARAM_ROM_EXCEPTION_COUNT==0) assign hit=0;
   for(e=0;e<PARAM_ROM_EXCEPTION_COUNT;e=e+1) begin:g_exception
    assign hit[e]=addr==param_exception_addr(e);
   end
   reg [15:0] exceptional;integer n;
   always @* begin
    exceptional=0;
    for(n=0;n<PARAM_ROM_EXCEPTION_COUNT;n=n+1)
     exceptional=exceptional|(param_exception_value(n)&{16{hit[n]}});
   end
   for(b=0;b<LOW_BANKS;b=b+1) begin:g_low
    EFX_RAM10 #(.READ_WIDTH(10),.WRITE_WIDTH(10),.OUTPUT_REG(0),.RESET_RAM("NONE"),
     .INIT_0(packed_rom_init(b,0)),
     .INIT_1(packed_rom_init(b,1)),
     .INIT_2(packed_rom_init(b,2)),
     .INIT_3(packed_rom_init(b,3)),
     .INIT_4(packed_rom_init(b,4)),
     .INIT_5(packed_rom_init(b,5)),
     .INIT_6(packed_rom_init(b,6)),
     .INIT_7(packed_rom_init(b,7)),
     .INIT_8(packed_rom_init(b,8)),
     .INIT_9(packed_rom_init(b,9)),
     .INIT_A(packed_rom_init(b,10)),
     .INIT_B(packed_rom_init(b,11)),
     .INIT_C(packed_rom_init(b,12)),
     .INIT_D(packed_rom_init(b,13)),
     .INIT_E(packed_rom_init(b,14)),
     .INIT_F(packed_rom_init(b,15)),
     .INIT_10(packed_rom_init(b,16)),
     .INIT_11(packed_rom_init(b,17)),
     .INIT_12(packed_rom_init(b,18)),
     .INIT_13(packed_rom_init(b,19)),
     .INIT_14(packed_rom_init(b,20)),
     .INIT_15(packed_rom_init(b,21)),
     .INIT_16(packed_rom_init(b,22)),
     .INIT_17(packed_rom_init(b,23)),
     .INIT_18(packed_rom_init(b,24)),
     .INIT_19(packed_rom_init(b,25)),
     .INIT_1A(packed_rom_init(b,26)),
     .INIT_1B(packed_rom_init(b,27)),
     .INIT_1C(packed_rom_init(b,28)),
     .INIT_1D(packed_rom_init(b,29)),
     .INIT_1E(packed_rom_init(b,30)),
     .INIT_1F(packed_rom_init(b,31)),
     .INIT_20(packed_rom_init(b,32)),
     .INIT_21(packed_rom_init(b,33)),
     .INIT_22(packed_rom_init(b,34)),
     .INIT_23(packed_rom_init(b,35)),
     .INIT_24(packed_rom_init(b,36)),
     .INIT_25(packed_rom_init(b,37)),
     .INIT_26(packed_rom_init(b,38)),
     .INIT_27(packed_rom_init(b,39))) u_rom(
      .RCLK(clk),.RE(rd_en && addr[14:10]==b),.RST(1'b0),.RADDREN(1'b1),
      .RADDR(addr[9:0]),.RDATA(low_q[b]),
      .WCLK(clk),.WCLKE(1'b0),.WADDREN(1'b0),.WE(2'b00),.WADDR(10'd0),.WDATA(10'd0));
   end
   for(b=0;b<HIGH_BANKS;b=b+1) begin:g_high
    EFX_RAM10 #(.READ_WIDTH(1),.WRITE_WIDTH(1),.OUTPUT_REG(0),.RESET_RAM("NONE"),
     .INIT_0(packed_rom_init(LOW_BANKS+b,0)),
     .INIT_1(packed_rom_init(LOW_BANKS+b,1)),
     .INIT_2(packed_rom_init(LOW_BANKS+b,2)),
     .INIT_3(packed_rom_init(LOW_BANKS+b,3)),
     .INIT_4(packed_rom_init(LOW_BANKS+b,4)),
     .INIT_5(packed_rom_init(LOW_BANKS+b,5)),
     .INIT_6(packed_rom_init(LOW_BANKS+b,6)),
     .INIT_7(packed_rom_init(LOW_BANKS+b,7)),
     .INIT_8(packed_rom_init(LOW_BANKS+b,8)),
     .INIT_9(packed_rom_init(LOW_BANKS+b,9)),
     .INIT_A(packed_rom_init(LOW_BANKS+b,10)),
     .INIT_B(packed_rom_init(LOW_BANKS+b,11)),
     .INIT_C(packed_rom_init(LOW_BANKS+b,12)),
     .INIT_D(packed_rom_init(LOW_BANKS+b,13)),
     .INIT_E(packed_rom_init(LOW_BANKS+b,14)),
     .INIT_F(packed_rom_init(LOW_BANKS+b,15)),
     .INIT_10(packed_rom_init(LOW_BANKS+b,16)),
     .INIT_11(packed_rom_init(LOW_BANKS+b,17)),
     .INIT_12(packed_rom_init(LOW_BANKS+b,18)),
     .INIT_13(packed_rom_init(LOW_BANKS+b,19)),
     .INIT_14(packed_rom_init(LOW_BANKS+b,20)),
     .INIT_15(packed_rom_init(LOW_BANKS+b,21)),
     .INIT_16(packed_rom_init(LOW_BANKS+b,22)),
     .INIT_17(packed_rom_init(LOW_BANKS+b,23)),
     .INIT_18(packed_rom_init(LOW_BANKS+b,24)),
     .INIT_19(packed_rom_init(LOW_BANKS+b,25)),
     .INIT_1A(packed_rom_init(LOW_BANKS+b,26)),
     .INIT_1B(packed_rom_init(LOW_BANKS+b,27)),
     .INIT_1C(packed_rom_init(LOW_BANKS+b,28)),
     .INIT_1D(packed_rom_init(LOW_BANKS+b,29)),
     .INIT_1E(packed_rom_init(LOW_BANKS+b,30)),
     .INIT_1F(packed_rom_init(LOW_BANKS+b,31)),
     .INIT_20(packed_rom_init(LOW_BANKS+b,32)),
     .INIT_21(packed_rom_init(LOW_BANKS+b,33)),
     .INIT_22(packed_rom_init(LOW_BANKS+b,34)),
     .INIT_23(packed_rom_init(LOW_BANKS+b,35)),
     .INIT_24(packed_rom_init(LOW_BANKS+b,36)),
     .INIT_25(packed_rom_init(LOW_BANKS+b,37)),
     .INIT_26(packed_rom_init(LOW_BANKS+b,38)),
     .INIT_27(packed_rom_init(LOW_BANKS+b,39))) u_rom(
      .RCLK(clk),.RE(rd_en && addr[14:13]==b),.RST(1'b0),.RADDREN(1'b1),
      .RADDR(addr[12:0]),.RDATA(high_q[b]),
      .WCLK(clk),.WCLKE(1'b0),.WADDREN(1'b0),.WE(2'b00),.WADDR(13'd0),.WDATA(1'd0));
   end
   always @(posedge clk) if(rd_en) begin
    low_bank<=addr[14:10];high_bank<=addr[14:13];
    exception_valid<=|hit;exception_q<=exceptional;
   end
   assign data=exception_valid ? exception_q : {{5{high_q[high_bank]}},high_q[high_bank],low_q[low_bank]};
  end else begin:g_dense
  wire [79:0] q[0:BANKS-1];reg [3:0] bank;reg [2:0] lane;
  wire [12:0] row_addr=addr/15'd5;
  wire [2:0] word_lane=addr%15'd5;
  genvar b,s;
  for(b=0;b<BANKS;b=b+1) begin:g_bank
   for(s=0;s<4;s=s+1) begin:g_slice
    EFX_RAM10 #(.READ_WIDTH(20),.WRITE_WIDTH(20),.OUTPUT_REG(0),.RESET_RAM("NONE"),
     .INIT_0(packed_rom_init(b*4+s,0)),
     .INIT_1(packed_rom_init(b*4+s,1)),
     .INIT_2(packed_rom_init(b*4+s,2)),
     .INIT_3(packed_rom_init(b*4+s,3)),
     .INIT_4(packed_rom_init(b*4+s,4)),
     .INIT_5(packed_rom_init(b*4+s,5)),
     .INIT_6(packed_rom_init(b*4+s,6)),
     .INIT_7(packed_rom_init(b*4+s,7)),
     .INIT_8(packed_rom_init(b*4+s,8)),
     .INIT_9(packed_rom_init(b*4+s,9)),
     .INIT_A(packed_rom_init(b*4+s,10)),
     .INIT_B(packed_rom_init(b*4+s,11)),
     .INIT_C(packed_rom_init(b*4+s,12)),
     .INIT_D(packed_rom_init(b*4+s,13)),
     .INIT_E(packed_rom_init(b*4+s,14)),
     .INIT_F(packed_rom_init(b*4+s,15)),
     .INIT_10(packed_rom_init(b*4+s,16)),
     .INIT_11(packed_rom_init(b*4+s,17)),
     .INIT_12(packed_rom_init(b*4+s,18)),
     .INIT_13(packed_rom_init(b*4+s,19)),
     .INIT_14(packed_rom_init(b*4+s,20)),
     .INIT_15(packed_rom_init(b*4+s,21)),
     .INIT_16(packed_rom_init(b*4+s,22)),
     .INIT_17(packed_rom_init(b*4+s,23)),
     .INIT_18(packed_rom_init(b*4+s,24)),
     .INIT_19(packed_rom_init(b*4+s,25)),
     .INIT_1A(packed_rom_init(b*4+s,26)),
     .INIT_1B(packed_rom_init(b*4+s,27)),
     .INIT_1C(packed_rom_init(b*4+s,28)),
     .INIT_1D(packed_rom_init(b*4+s,29)),
     .INIT_1E(packed_rom_init(b*4+s,30)),
     .INIT_1F(packed_rom_init(b*4+s,31)),
     .INIT_20(packed_rom_init(b*4+s,32)),
     .INIT_21(packed_rom_init(b*4+s,33)),
     .INIT_22(packed_rom_init(b*4+s,34)),
     .INIT_23(packed_rom_init(b*4+s,35)),
     .INIT_24(packed_rom_init(b*4+s,36)),
     .INIT_25(packed_rom_init(b*4+s,37)),
     .INIT_26(packed_rom_init(b*4+s,38)),
     .INIT_27(packed_rom_init(b*4+s,39))) u_rom(
      .RCLK(clk),.RE(rd_en && row_addr[12:9]==b),.RST(1'b0),.RADDREN(1'b1),
      .RADDR(row_addr[8:0]),.RDATA(q[b][s*20+:20]),
      .WCLK(clk),.WCLKE(1'b0),.WADDREN(1'b0),.WE(2'b00),.WADDR(9'd0),.WDATA(20'd0));
   end
  end
  always @(posedge clk) if(rd_en) begin bank<=row_addr[12:9];lane<=word_lane;end
  assign data=q[bank][lane*16+:16];
  end
 end else begin:g_banked
 // 7x7 tail uses 1024+128 words rather than a padded 2048-word bank.
 (* syn_ramstyle="block_ram" *) reg [15:0] bank0[0:16383];
 (* syn_ramstyle="block_ram" *) reg [15:0] bank1[0:4095];
 reg [15:0] q0,q1,q2,q3;reg [1:0] select_bank=0;
 initial begin
  $readmemh("generator_params_bank0.mem",bank0);
  $readmemh("generator_params_bank1.mem",bank1);
 end
 if(7==7) begin:g_wide
  (* syn_ramstyle="block_ram" *) reg [15:0] bank2[0:1023];
  (* syn_ramstyle="block_ram" *) reg [15:0] bank3[0:127];
  initial begin
   $readmemh("generator_params_bank2.mem",bank2);
   $readmemh("generator_params_bank3.mem",bank3);
  end
  always @(posedge clk) if(rd_en) begin q2<=bank2[addr[9:0]];q3<=bank3[addr[6:0]];end
 end else begin:g_small
  (* syn_ramstyle="block_ram" *) reg [15:0] bank2[0:511];
  initial $readmemh("generator_params_bank2.mem",bank2);
  always @(posedge clk) if(rd_en) q2<=bank2[addr[8:0]];
  always @(*) q3=0;
 end
 always @(posedge clk) if(rd_en) begin
  q0<=bank0[addr[13:0]];q1<=bank1[addr[11:0]];
  select_bank<=!addr[14] ? 0 : !addr[12] ? 1 :
               (7==7 && addr[10]) ? 3 : 2;
 end
 assign data=select_bank==0 ? q0 : select_bank==1 ? q1 : select_bank==2 ? q2 : q3;
 end endgenerate
endmodule
