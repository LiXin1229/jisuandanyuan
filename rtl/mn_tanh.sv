// Derived from pe10_10/generator/rtl/tanh_bram.v; same Q4.8-to-uint8 LUT.
`timescale 1ns/1ps
// One synchronous 4096x8 BRAM ROM, shared by every pixel and RGB channel.
module mn_tanh_bram(input wire clk,rd_en,input wire [11:0] addr,output reg [7:0] data);
 (* syn_ramstyle="block_ram" *) reg [7:0] rom[0:4095];
 initial $readmemh("rtl/mn_tanh_u8.mem",rom);
 always @(posedge clk) if(rd_en) data<=rom[addr];
endmodule

// The exported table has exact byte symmetry: LUT[a]=255-LUT[4096-a]
// for a>2048. Read only its lower 2048 entries; zero is handled explicitly.
// Two synchronous ports process a pixel pair in one cycle.
module mn_tanh_bram_dual(input wire clk,rd_en,input wire [11:0] addr0,addr1,
 output wire [7:0] data0,data1);
 (* syn_ramstyle="block_ram" *) reg [7:0] rom[0:4095];
 initial $readmemh("rtl/mn_tanh_u8.mem",rom);
 wire [10:0] index0=addr0[11] ? -addr0[10:0] : addr0[10:0];
 wire [10:0] index1=addr1[11] ? -addr1[10:0] : addr1[10:0];
 reg [7:0] raw0,raw1;reg flip0,flip1,zero0,zero1;
 always @(posedge clk) if(rd_en) begin
  raw0<=rom[{1'b0,index0}];raw1<=rom[{1'b0,index1}];
  flip0<=addr0[11];flip1<=addr1[11];
  zero0<=addr0==2048;zero1<=addr1==2048;
 end
 assign data0=zero0 ? 8'd128 : (flip0 ? 8'd255-raw0 : raw0);
 assign data1=zero1 ? 8'd128 : (flip1 ? 8'd255-raw1 : raw1);
endmodule

// DSP outputs remain stable until lookup completes; no 100x36 result copy.
// Decode the lane index once; four OR-reduced banks share the selection bits.
module mn_tanh_tile(input wire clk,rstn,start,input wire [3199:0] in_data,
 output wire busy,output reg valid,input wire ready,output wire [799:0] data);
 wire [35:0] sum[0:99];
 genvar lane;
 generate for(lane=0;lane<100;lane=lane+1) begin:g_sum
 assign sum[lane]={{4{in_data[lane*32+31]}},in_data[lane*32+:32]};
 end endgenerate
 reg active=0;reg bank_d=0;reg [5:0] issue=0;
 // Values outside signed 16-bit range already saturate the Tanh address.
 // Select {overflow,true_sign,low16} instead of the full signed result.
 // The overflow test is also used by the shared compute quantizer.
 wire [17:0] compact[0:99];
 reg [17:0] group_q[0:3],raw_q[0:1];reg [11:0] addr_q[0:1];
 wire [24:0] select_lane=25'b1<<issue[5:1];
 reg [3:0] v=0;reg [5:0] tag[0:3];reg [7:0] pixel[0:99];
 wire [7:0] rom_q[0:1];assign busy=active || valid;
 function [11:0] address;
  input [17:0] value;reg signed [16:0] rounded;
  begin
   rounded=($signed({value[15],value[15:0]})+17'sd8) >>> 4;
   if(value[17]) address=value[16] ? 0 : 4095;
   else if(rounded>2047) address=4095;
   else if(rounded< -2048) address=0;
   else address=rounded[11:0]^12'h800;
  end
 endfunction
 mn_tanh_bram_dual u_lut(.clk(clk),.rd_en(v[2]),.addr0(addr_q[0]),.addr1(addr_q[1]),.data0(rom_q[0]),.data1(rom_q[1]));
 genvar g;
 generate for(g=0;g<100;g=g+1) begin:g_compact
  assign compact[g]={sum[g][31] ? !(&sum[g][30:15]) : |sum[g][30:15],sum[g][31],sum[g][15:0]};
 end
 for(g=0;g<4;g=g+1) begin:g_select
  reg [17:0] selected;integer k;
  always @* begin
   selected=0;
   for(k=0;k<25;k=k+1) selected=selected|(compact[k*4+g]&{18{select_lane[k]}});
  end
  always @(posedge clk) if(active && issue<50) group_q[g]<=selected;
 end
 for(g=0;g<100;g=g+1) begin:g_out
  localparam R=g/10,C=g%10,B=((R/5)*2+C/5)*200+((R%5)*5+C%5)*8;
  initial pixel[g]=0;
  always @(posedge clk) if(v[3] && tag[3]==g/2) pixel[g]<=rom_q[g%2];
  assign data[B+:8]=pixel[g];
 end endgenerate
 integer i;
 always @(posedge clk) begin
  v<={v[2:0],active && issue<50};
  tag[0]<=issue;for(i=1;i<4;i=i+1) tag[i]<=tag[i-1];
  bank_d<=issue[0];
  if(v[0]) begin raw_q[0]<=group_q[{bank_d,1'b0}];raw_q[1]<=group_q[{bank_d,1'b1}];end
  if(v[1]) begin addr_q[0]<=address(raw_q[0]);addr_q[1]<=address(raw_q[1]);end
  if(!rstn) begin active<=0;valid<=0;v<=0;issue<=0;bank_d<=0;end
  else begin
   if(valid && ready) valid<=0;
   if(start && !busy) begin active<=1;issue<=0;end
   if(active && issue<50) begin
    issue<=issue+1;
   end
   if(v[3] && tag[3]==49) begin active<=0;valid<=1;end
  end
 end
endmodule
