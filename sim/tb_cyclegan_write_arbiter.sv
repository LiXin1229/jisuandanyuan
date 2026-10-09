`timescale 1ns/1ps
module tb_cyclegan_write_arbiter;
 reg clk=0,rstn=0;always #5 clk=~clk;
 reg [1:0] as=0,bs=0;integer ai=0,bi=0,ab=0,bb=0,ticks=0,received=0;
 wire a_awvalid=as==0 && ai<20,b_awvalid=bs==0 && bi<20;
 wire a_awready,b_awready,a_wready,b_wready,a_bvalid,b_bvalid;
 wire [31:0] a_awaddr=32'h1000+ai*64,b_awaddr=32'h5000+bi*64;
 wire [7:0] a_awlen=3,b_awlen=3;
 wire a_wvalid=as==1,b_wvalid=bs==1,a_wlast=ab==3,b_wlast=bb==3;
 wire [127:0] a_wdata={4{32'h10000000|(ai<<8)|ab}},b_wdata={4{32'h50000000|(bi<<8)|bb}};
 wire a_bready=as==2 && ticks%3!=0,b_bready=bs==2 && ticks%4!=0;
 wire awvalid,wvalid,wlast,bready;wire [31:0] awaddr;wire [7:0] awlen;wire [127:0] wdata;
 wire awready=!active && !bvalid && ticks%5==0,wready=active && ticks%7<3;
 reg bvalid=0,active=0,owner=0;integer id=0,beat=0,delay_count=0;
 reg pending_b=0,aw_stalled=0,w_stalled=0;reg [31:0] held_awaddr;reg [7:0] held_awlen;reg [127:0] held_wdata;reg held_wlast;
 cyclegan_write_arbiter dut(.*);
 always @(posedge clk) if(rstn) begin
  ticks<=ticks+1;
  if(aw_stalled && (!awvalid || awaddr!==held_awaddr || awlen!==held_awlen)) $fatal(1,"AW changed under backpressure");
  if(w_stalled && (!wvalid || wdata!==held_wdata || wlast!==held_wlast)) $fatal(1,"W changed under backpressure");
  aw_stalled<=awvalid&&!awready;held_awaddr<=awaddr;held_awlen<=awlen;
  w_stalled<=wvalid&&!wready;held_wdata<=wdata;held_wlast<=wlast;
  if(a_awvalid && a_awready) begin as<=1;ab<=0;end
  if(b_awvalid && b_awready) begin bs<=1;bb<=0;end
  if(a_wvalid && a_wready) begin if(a_wlast) as<=2;else ab<=ab+1;end
  if(b_wvalid && b_wready) begin if(b_wlast) bs<=2;else bb<=bb+1;end
  if(a_bvalid && a_bready) begin ai<=ai+1;as<=0;end
  if(b_bvalid && b_bready) begin bi<=bi+1;bs<=0;end
  if(awvalid && awready) begin
   if(awlen!=3 || awaddr[5:0]!=0) $fatal(1,"AW format");
   owner<=awaddr>=32'h5000;id<=((awaddr>=32'h5000 ? awaddr-32'h5000 : awaddr-32'h1000)>>6);beat<=0;active<=1;
  end
  if(wvalid && wready) begin
   if(wdata!=={4{(owner ? 32'h50000000 : 32'h10000000)|(id<<8)|beat}} || wlast!=(beat==3)) $fatal(1,"Interleaved write transaction");
   if(wlast) begin active<=0;pending_b<=1;delay_count<=7+ticks%9;end else beat<=beat+1;
  end
  if(pending_b) begin if(delay_count!=0) delay_count<=delay_count-1;else begin pending_b<=0;bvalid<=1;end end
  if(bvalid && bready) begin bvalid<=0;received<=received+1;end
  if(ai==20 && bi==20) begin
   if(received!=40) $fatal(1,"Response count");
   $display("PASS write arbiter: 40 concurrent transactions, AW/W/B backpressure, stable owner and payload");$finish;
  end
  if(ticks>10000) $fatal(1,"Arbiter timeout");
 end
 initial begin repeat(5) @(negedge clk);rstn=1;end
endmodule
