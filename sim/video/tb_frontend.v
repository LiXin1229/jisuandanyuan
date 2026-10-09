`timescale 1ns/1ps
module tb_frontend;
 reg cclk=0,dclk=0;always #2.67 cclk=~cclk;always #5.208333 dclk=~dclk;
 reg rstn=0,fv=0,lv=0,pv=0;reg [31:0] pixels=0;
 wire cv,cs,ce,valid,sof,eof,abort;wire [23:0] crop_rgb,rgb,isp_rgb;wire iv,is,ie;wire [15:0] frames,overruns;wire [10:0] line_pixels;
 camera_crop_bayer dut(.cclk(cclk),.crstn(rstn),.frame_valid(fv),.line_valid(lv),.pixels_valid(pv),.pixels(pixels),
  .dclk(dclk),.drstn(rstn),.rgb_valid(cv),.rgb_sof(cs),.rgb_eof(ce),.frame_abort(abort),.rgb(crop_rgb),
  .source_frames(frames),.overruns(overruns),.last_line_pixels(line_pixels));
 camera_isp isp(.clk(dclk),.rstn(rstn),.s_valid(cv),.s_sof(cs),.s_eof(ce),.s_rgb(crop_rgb),
  .m_valid(iv),.m_sof(is),.m_eof(ie),.m_rgb(isp_rgb),.gain_r(),.gain_g(),.gain_b());
 camera_pool2x2 pool(.clk(dclk),.rstn(rstn),.abort(abort),.s_valid(iv),.s_sof(is),.s_eof(ie),.s_rgb(isp_rgb),
  .m_valid(valid),.m_sof(sof),.m_eof(eof),.m_rgb(rgb));
 reg [7:0] lut[0:255];
 function [7:0] raw;input integer x,y;begin
  // Known BGGR colour fields, edges, and isolated bright/dark defects.
  raw=x%2==1 && y%2==1 ? 180 : x%2==0 && y%2==0 ? 40 : 100;
  if(x>=960) raw=raw+20;
  if(x==901 && y==501) raw=255;
  if(x==1020 && y==600) raw=0;
 end endfunction
 function integer cleaned;input integer x,y;integer l,r,c;
  begin l=raw(x-2,y);r=raw(x+2,y);c=raw(x,y);
   cleaned=c;
  end
 endfunction
 function [23:0] expected;input integer x,y;
  integer center,cross_total,corners,horiz,vert,r,g,b;
  begin
   center=cleaned(x,y);cross_total=cleaned(x,y-1)+cleaned(x-1,y)+cleaned(x+1,y)+cleaned(x,y+1);
   corners=cleaned(x-1,y-1)+cleaned(x+1,y-1)+cleaned(x-1,y+1)+cleaned(x+1,y+1);
   horiz=cleaned(x-1,y)+cleaned(x+1,y);vert=cleaned(x,y-1)+cleaned(x,y+1);
   if(x%2==1 && y%2==1) begin r=center;g=cross_total/4;b=corners/4;end
   else if(x%2==0 && y%2==0) begin r=corners/4;g=cross_total/4;b=center;end
   else begin g=center;r=y%2==1 ? horiz/2 : vert/2;b=y%2==1 ? vert/2 : horiz/2;end
   expected={r[7:0],g[7:0],b[7:0]};
  end
 endfunction
 function [23:0] pooled(input integer i);
  integer a,b,c,v,x,y;reg [23:0] value;begin
   x=640+2*(i%320);y=300+2*(i/320);
   for(c=0;c<3;c=c+1) begin
    v=0;
    for(a=0;a<2;a=a+1) for(b=0;b<2;b=b+1) begin
     value=expected(x+a,y+b);
     if(lut[value[c*8+:8]]>v) v=lut[value[c*8+:8]];
    end
    pooled[c*8+:8]=v;
   end
  end
 endfunction
 integer count=0,sofs=0,eofs=0,x,y,i;
 always @(negedge dclk) if(rstn) begin
  if(abort || overruns) $fatal(1,"crop overrun");
  if(valid) begin
   if(rgb!==pooled(count)) $fatal(1,"crop pixel %0d got=%h expected=%h",count,rgb,pooled(count));
   if(sof) begin if(count!=0) $fatal(1,"SOF alignment");sofs=sofs+1;end
   if(eof) begin if(count!=76799) $fatal(1,"EOF alignment");eofs=eofs+1;end
   count=count+1;
  end
 end
 initial begin
  $readmemh("camera_gamma.mem",lut);repeat(10) @(negedge cclk);rstn=1;repeat(10) @(negedge cclk);fv=1;
  for(y=0;y<1080;y=y+1) begin
   @(negedge cclk);lv=1;
   for(x=0;x<1920;x=x+4) begin
    pixels={raw(x+3,y),raw(x+2,y),raw(x+1,y),raw(x,y)};pv=1;@(negedge cclk);
   end
   pv=0;lv=0;repeat(2200) @(negedge cclk);
  end
  fv=0;repeat(400) @(negedge dclk);
  if(count!=76800 || sofs!=1 || eofs!=1 || frames!=1 || line_pixels!=0) $fatal(1,"crop counts %0d",count);
  $display("PASS camera frontend: SC2210 1920x1080 RAW -> centered 640x480 -> BGGR/ISP/gamma -> 76800 exact RGB channel-wise maxpool pixels, frame tags and real CSI/system clocks");$finish;
 end
 initial begin #20000000;$fatal(1,"crop timeout");end
endmodule
