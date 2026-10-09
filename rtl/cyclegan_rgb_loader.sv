// Derived from pe10_10/generator/rtl/generator_input_tile_loader.v.
`timescale 1ns/1ps
// Hold the bridge response until all three channels have been scattered.
// Reuse its response bank and ten quantizers; keep only one channel's row.
// Every tile is complete before done; no change to input quantization/packing.
module cyclegan_rgb_loader(input wire clk,rstn,start,input wire [31:0] frame_base,
 input wire [4:0] tile_x,tile_y,output wire busy,output reg done,
 output reg req_valid,input wire req_ready,output reg [31:0] req_addr,
 output wire [2:0] req_beats,input wire rsp_valid,output wire rsp_ready,input wire [511:0] rsp_data,
 input wire cache_ready,output wire cache_wr,output wire [10:0] cache_addr,output wire [799:0] cache_data,
 output wire [39:0] cache_we);
 localparam IDLE=0,REQ=1,RESP=2,WRITE=3,END=4;
 reg [2:0] state=IDLE;reg [4:0] x,y;reg [3:0] row;
 reg [1:0] channel;reg [31:0] base;
 reg [7:0] row_pixels[0:9];
 wire [1:0] quant_channel=state==RESP ? 0 : channel==0 ? 1 : 2;
 wire [7:0] selected[0:9];wire [2:0] row5=row<5 ? row : row-5;
 assign cache_wr=state==WRITE && cache_ready;assign cache_addr=(y%3)*96+x*3+channel;
 assign req_beats=3;assign rsp_ready=state==WRITE && channel==2 && cache_ready;assign busy=state!=IDLE;
 genvar g;generate for(g=0;g<10;g=g+1) begin:g_select
  wire [7:0] rgb0=x[0] ? rsp_data[(g+2)*32+:8] : rsp_data[g*32+:8];
  wire [7:0] rgb1=x[0] ? rsp_data[(g+2)*32+8+:8] : rsp_data[g*32+8+:8];
  wire [7:0] rgb2=x[0] ? rsp_data[(g+2)*32+16+:8] : rsp_data[g*32+16+:8];
  wire [7:0] byte_value=quant_channel==0 ? rgb0 : quant_channel==1 ? rgb1 : rgb2;
  wire signed [8:0] centered=$signed({1'b0,byte_value})-9'sd124;
  // Prepare channel zero while waiting for the response, then prepare each
  // following channel in parallel with the preceding cache write.
  always @(posedge clk)
   if((state==RESP && rsp_valid) || (state==WRITE && channel<2 && cache_ready)) row_pixels[g]<=centered>>>3;
  assign selected[g]=row_pixels[g];
 end
 for(g=0;g<100;g=g+1) begin:g_pack
  localparam Q=g/25,J=g%25,C=J%5;
  assign cache_data[g*8+:8]=selected[(Q%2)*5+C];
 end
 for(g=0;g<40;g=g+1) begin:g_mask
  localparam Q=g/10,R=(g%10)/2;
  assign cache_we[g]=(Q/2==(row>=5)) && R==row5;
 end endgenerate
 always @(posedge clk) begin
  done<=0;
  if(!rstn) begin state<=IDLE;x<=0;y<=0;row<=0;channel<=0;base<=0;req_valid<=0;req_addr<=0;end
  else case(state)
   IDLE:if(start) begin x<=tile_x;y<=tile_y;row<=0;base<=frame_base;state<=REQ;end
   REQ:begin
    req_addr<=base+(y*10+row)*1280+((x*10)&32'hfffffffc)*4;req_valid<=1;
    if(req_valid && req_ready) begin req_valid<=0;state<=RESP;end
   end
   RESP:if(rsp_valid) begin
    channel<=0;state<=WRITE;
   end
   WRITE:if(!cache_ready) begin end else if(channel<2) channel<=channel+1;
    else if(row==9) state<=END;else begin row<=row+1;state<=REQ;end
   END:begin done<=1;state<=IDLE;end
   default:state<=IDLE;
  endcase
 end
endmodule
