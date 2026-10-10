`timescale 1ns/1ps
// Optional fixed-image source. VIO holds each RGBx packet until chunk_done.
// Eight clocks per pixel leave the existing camera FIFO/DDR writer headroom.
module camera_jtag_input #(parameter PIXELS=76800)(
 input wire clk,rstn,begin_frame,load_chunk,input wire [511:0] payload,
 output reg armed=0,busy=0,chunk_done=0,
 output wire valid,sof,eof,output wire [23:0] rgb);
 localparam PW=$clog2(PIXELS+1);
 reg [PW-1:0] pixels=0;
 reg [3:0] part=0;
 reg [2:0] gap=0;
 wire [31:0] pixel=payload[part*32+:32];
 assign valid=busy && gap==0;
 assign sof=valid && pixels==0;
 assign eof=valid && pixels==PIXELS-1;
 assign rgb={pixel[7:0],pixel[15:8],pixel[23:16]};
 always @(posedge clk) begin
  chunk_done<=0;
  if(!rstn) begin armed<=0;busy<=0;pixels<=0;part<=0;gap<=0;chunk_done<=0;end
  else if(begin_frame && !busy) begin armed<=1;pixels<=0;part<=0;gap<=0;end
  else if(load_chunk && armed && !busy) begin busy<=1;part<=0;gap<=0;end
  else if(busy) begin
   if(gap!=0) gap<=gap-1;
   else begin
    pixels<=pixels+1;gap<=7;
    if(part==15) begin busy<=0;chunk_done<=1;end else part<=part+1;
    if(pixels==PIXELS-1) armed<=0;
   end
  end
 end
endmodule
