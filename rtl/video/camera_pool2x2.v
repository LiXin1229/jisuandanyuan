`timescale 1ns/1ps
// RGB channel-wise 2x2 maximum. Only 320 horizontal maxima are retained.
// SOF restarts coordinates; abort discards a partial frame until the next SOF.
module camera_pool2x2(input wire clk,rstn,abort,
 input wire s_valid,s_sof,s_eof,input wire [23:0] s_rgb,
 output reg m_valid=0,m_sof=0,m_eof=0,output reg [23:0] m_rgb=0);
 reg [9:0] x=0;reg [8:0] y=0;reg active=0;reg [23:0] left=0;
 wire [9:0] sx=s_sof ? 10'd0 : x;
 wire [8:0] sy=s_sof ? 9'd0 : y;
 wire take=s_valid && (active || s_sof) && !abort;
 wire [23:0] horizontal;
 genvar c;
 generate for(c=0;c<3;c=c+1) begin:g_channel
  assign horizontal[c*8+:8]=left[c*8+:8]>s_rgb[c*8+:8] ? left[c*8+:8] : s_rgb[c*8+:8];
  (* syn_ramstyle="block_ram" *) reg [7:0] line[0:511];reg [7:0] q;
  always @(posedge clk) begin
   q<=line[sx[9:1]];
   if(take && sx[0] && !sy[0]) line[sx[9:1]]<=horizontal[c*8+:8];
   if(take && sx[0] && sy[0])
    m_rgb[c*8+:8]<=q>horizontal[c*8+:8] ? q : horizontal[c*8+:8];
  end
 end endgenerate
 always @(posedge clk) begin
  m_valid<=0;m_sof<=0;m_eof<=0;
  if(!rstn || abort) begin x<=0;y<=0;active<=0;left<=0;end
  else if(take) begin
   left<=s_rgb;active<=!s_eof;
   if(sx==639) begin x<=0;y<=sy+1;end else begin x<=sx+1;y<=sy;end
   if(sx[0] && sy[0]) begin
    m_valid<=1;m_sof<=sx==1 && sy==1;m_eof<=sx==639 && sy==479 && s_eof;
   end
  end
 end
endmodule
