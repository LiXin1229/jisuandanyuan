`timescale 1ns/1ps
// Streaming gray-world AWB and the user's gamma table. No image buffer.
// A single restoring divider calculates three gains during frame blanking.
module camera_isp #(parameter GAMMA_FILE="camera_gamma.mem")(
 input wire clk,rstn,s_valid,s_sof,s_eof,input wire [23:0] s_rgb,
 output reg m_valid=0,m_sof=0,m_eof=0,output wire [23:0] m_rgb,
 output reg [9:0] gain_r=256,gain_g=256,gain_b=256);
 // 640x480 * 239 fits in 27 bits; the old 320x240 counters overflowed here.
 reg [26:0] sum_r=0,sum_g=0,sum_b=0;
 wire [7:0] r=s_rgb[23:16],g=s_rgb[15:8],b=s_rgb[7:0];
 wire useful=r>4 && g>4 && b>4 && r<240 && g<240 && b<240;
 wire [26:0] next_r=(s_sof ? 27'd0 : sum_r)+(useful ? {19'd0,r} : 27'd0);
 wire [26:0] next_g=(s_sof ? 27'd0 : sum_g)+(useful ? {19'd0,g} : 27'd0);
 wire [26:0] next_b=(s_sof ? 27'd0 : sum_b)+(useful ? {19'd0,b} : 27'd0);
 reg [1:0] state=0;reg [5:0] step=0;
 reg [34:0] quotient=0,numerator=0;reg [27:0] remainder=0;
 reg [26:0] denominator=0,green_sum=0,blue_sum=0;
 reg [9:0] pending_r=256,pending_g=256,pending_b=256;reg gain_ready=0;
 // Same target as the reference RAW statistics: R/4 + G/2 + B/4.
 wire [28:0] target_sum={2'd0,next_r}+({2'd0,next_g}<<1)+{2'd0,next_b};
 wire [27:0] shifted={remainder[26:0],quotient[34]};
 wire subtract=shifted>={1'b0,denominator};
 wire [34:0] quotient_next={quotient[33:0],subtract};
 function [9:0] bounded;input [34:0] q;
  begin bounded=q<128 ? 10'd128 : q>768 ? 10'd768 : q[9:0];end
 endfunction
 wire [11:0] smooth_r={2'd0,gain_r}+({2'd0,gain_r}<<1)+{2'd0,pending_r}+12'd2;
 wire [11:0] smooth_b={2'd0,gain_b}+({2'd0,gain_b}<<1)+{2'd0,pending_b}+12'd2;
 wire [11:0] smooth_g={2'd0,gain_g}+({2'd0,gain_g}<<1)+{2'd0,pending_g}+12'd2;
 // On SOF the first pixel uses exactly the gains latched for the new frame.
 wire [9:0] frame_r=s_sof && gain_ready ? smooth_r[11:2] : gain_r;
 wire [9:0] frame_b=s_sof && gain_ready ? smooth_b[11:2] : gain_b;
 wire [9:0] frame_g=s_sof && gain_ready ? smooth_g[11:2] : gain_g;
 reg [17:0] product_r=0,product_g=0,product_b=0;
 reg valid_d=0,sof_d=0,eof_d=0;
 wire [18:0] rounded_r={1'b0,product_r}+19'd128,rounded_b={1'b0,product_b}+19'd128;
 wire [18:0] rounded_g={1'b0,product_g}+19'd128;
 wire [7:0] corrected_r=|rounded_r[18:16] ? 8'd255 : rounded_r[15:8];
 wire [7:0] corrected_b=|rounded_b[18:16] ? 8'd255 : rounded_b[15:8];
 wire [7:0] corrected_g=|rounded_g[18:16] ? 8'd255 : rounded_g[15:8];
 (* syn_ramstyle="block_ram" *) reg [7:0] lut_r[0:255],lut_g[0:255],lut_b[0:255];
 reg [7:0] gamma_r=0,gamma_g=0,gamma_b=0;
 initial begin $readmemh(GAMMA_FILE,lut_r);$readmemh(GAMMA_FILE,lut_g);$readmemh(GAMMA_FILE,lut_b);end
 assign m_rgb={gamma_r,gamma_g,gamma_b};
 always @(posedge clk) begin
  gamma_r<=lut_r[corrected_r];gamma_g<=lut_g[corrected_g];gamma_b<=lut_b[corrected_b];
  m_valid<=valid_d;m_sof<=sof_d;m_eof<=eof_d;
  valid_d<=s_valid;sof_d<=s_valid && s_sof;eof_d<=s_valid && s_eof;
  if(s_valid) begin product_r<=r*frame_r;product_g<=g*frame_g;product_b<=b*frame_b;end
  if(!rstn) begin
   sum_r<=0;sum_g<=0;sum_b<=0;state<=0;step<=0;gain_r<=256;gain_g<=256;gain_b<=256;
   quotient<=0;numerator<=0;remainder<=0;denominator<=0;green_sum<=0;blue_sum<=0;gain_ready<=0;pending_r<=256;pending_g<=256;pending_b<=256;
   valid_d<=0;sof_d<=0;eof_d<=0;m_valid<=0;m_sof<=0;m_eof<=0;
  end else begin
   if(s_valid) begin
    sum_r<=next_r;sum_g<=next_g;sum_b<=next_b;
    if(s_sof && gain_ready) begin gain_r<=frame_r;gain_g<=frame_g;gain_b<=frame_b;gain_ready<=0;end
    if(s_eof && state==0 && next_r>=4096 && next_g>=4096 && next_b>=4096) begin
     quotient<={target_sum[28:2],8'd0};numerator<={target_sum[28:2],8'd0};remainder<=0;
     denominator<=next_r;green_sum<=next_g;blue_sum<=next_b;step<=0;state<=1;
    end
   end
   if(state!=0) begin
    quotient<=quotient_next;remainder<=subtract ? shifted-{1'b0,denominator} : shifted;
    if(step==34) begin
     if(state==1) begin
      pending_r<=bounded(quotient_next);denominator<=green_sum;quotient<=numerator;remainder<=0;state<=2;step<=0;
     end else if(state==2) begin
      pending_g<=bounded(quotient_next);denominator<=blue_sum;quotient<=numerator;remainder<=0;state<=3;step<=0;
     end else begin pending_b<=bounded(quotient_next);gain_ready<=1;state<=0;end
    end else step<=step+1;
   end
  end
 end
endmodule
