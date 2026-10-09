`timescale 1ns/1ps
module tb_pool;
 reg clk=0;always #5 clk=~clk;
 reg rstn=0,abort=0,valid=0,sof=0,eof=0;reg [23:0] rgb=0;
 wire mv,ms,me;wire [23:0] mrgb;
 camera_pool2x2 dut(.clk(clk),.rstn(rstn),.abort(abort),.s_valid(valid),.s_sof(sof),.s_eof(eof),.s_rgb(rgb),
  .m_valid(mv),.m_sof(ms),.m_eof(me),.m_rgb(mrgb));
 function integer color(input integer x,y,c,f);
  color=(x*37+y*83+c*71+f*29+((x*y)%(251-c*11)))&255;
 endfunction
 function [23:0] expected(input integer i,f);
  integer x,y,c,a,b,v;begin x=(i%320)*2;y=(i/320)*2;
   for(c=0;c<3;c=c+1) begin
    v=0;for(a=0;a<2;a=a+1) for(b=0;b<2;b=b+1)
     if(color(x+a,y+b,c,f)>v) v=color(x+a,y+b,c,f);
    expected[c*8+:8]=v;
   end
  end
 endfunction
 integer count=0,frames=0,f=0,x,y,c,sofs=0,eofs=0;
 always @(negedge clk) if(mv && rstn) begin
  if(mrgb!==expected(count,f) || ms!==(count==0) || me!==(count==76799))
   $fatal(1,"pool frame=%0d pixel=%0d got=%h expected=%h SOF=%b EOF=%b",f,count,mrgb,expected(count,f),ms,me);
  count=count+1;if(ms) sofs=sofs+1;if(me) begin eofs=eofs+1;frames=frames+1;end
 end
 initial begin
  repeat(8) @(negedge clk);rstn=1;
  // Abort before a complete 2x2 region, then reject stale pixels until SOF.
  valid=1;sof=1;rgb=24'hffffff;@(negedge clk);sof=0;@(negedge clk);
  abort=1;@(negedge clk);abort=0;repeat(10) @(negedge clk);valid=0;
  for(f=0;f<3;f=f+1) begin
   count=0;
   for(y=0;y<480;y=y+1) begin
    for(x=0;x<640;x=x+1) begin
     @(negedge clk);
     if((x+y)%47==5) begin valid=0;sof=0;eof=0;repeat(3) @(negedge clk);end
     valid=1;sof=x==0 && y==0;eof=x==639 && y==479;
     for(c=0;c<3;c=c+1) rgb[c*8+:8]=color(x,y,c,f);
    end
    @(negedge clk);valid=0;sof=0;eof=0;repeat(y%9) @(negedge clk);
   end
   repeat(8) @(negedge clk);
   if(count!=76800) $fatal(1,"pool count %0d",count);
  end
  if(frames!=3 || sofs!=3 || eofs!=3) $fatal(1,"pool frame tags");
  $display("PASS camera pool: 230400 channel-wise 2x2 maxima, 3 frames, valid gaps, SOF/EOF, abort/restart and row-cache reuse");$finish;
 end
 initial begin #20000000;$fatal(1,"pool timeout");end
endmodule
