`timescale 1ns/1ps
module tb_isp640;
 reg clk=0;always #5 clk=~clk;
 reg rstn=0,valid=0,sof=0,eof=0;reg [23:0] rgb=24'hefad51;
 wire mv,ms,me;wire [23:0] mrgb;wire [9:0] gr,gg,gb;
 camera_isp dut(.clk(clk),.rstn(rstn),.s_valid(valid),.s_sof(sof),.s_eof(eof),.s_rgb(rgb),
  .m_valid(mv),.m_sof(ms),.m_eof(me),.m_rgb(mrgb),.gain_r(gr),.gain_g(gg),.gain_b(gb));
 reg [7:0] lut[0:255];integer i,count=0;reg second=0;
 always @(negedge clk) if(rstn && mv) begin
  if(!second) begin
   if(mrgb!=={lut[239],lut[173],lut[81]} || ms!==(count==0) || me!==(count==307199))
    $fatal(1,"640 ISP frame pixel=%0d RGB/tags",count);
   count=count+1;
  end else if(mrgb!=={lut[221],lut[172],lut[103]} || !ms || me)
   $fatal(1,"640 ISP next-frame corrected RGB=%h",mrgb);
 end
 initial begin
  $readmemh("camera_gamma.mem",lut);repeat(8) @(negedge clk);rstn=1;
  for(i=0;i<307200;i=i+1) begin
   @(negedge clk);valid=1;sof=i==0;eof=i==307199;
  end
  @(negedge clk);valid=0;sof=0;eof=0;repeat(140) @(negedge clk);
  if(count!=307200 || gr!=256 || gg!=256 || gb!=256) $fatal(1,"frame locking/count");
  // Independent gray-world ratio: floor(166.5*256 / [239,173,81]) = [178,246,526].
  // Quarter-step smoothing from unity gives [237,254,324].
  second=1;valid=1;sof=1;@(negedge clk);valid=0;sof=0;repeat(5) @(negedge clk);
  if(gr!=237 || gg!=254 || gb!=324) $fatal(1,"AWB full-size sums overflow: %0d/%0d/%0d",gr,gg,gb);
  $display("PASS camera ISP640: 307200 high-valued pixels, exact gamma/frame tags, 27-bit statistics and next-frame AWB gains");$finish;
 end
 initial begin #4000000;$fatal(1,"ISP640 timeout");end
endmodule
