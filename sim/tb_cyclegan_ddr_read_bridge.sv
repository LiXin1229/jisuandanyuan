`timescale 1ns/1ps
module tb_cyclegan_ddr_read_bridge;
 reg cclk=0,dclk=0;always #3.333 cclk=~cclk;always #5.208 dclk=~dclk;
 reg crstn=0,drstn=0,req_valid=0,rsp_ready=0;
 reg [31:0] req_addr=0;reg [2:0] req_beats=3;
 wire req_ready,rsp_valid,fault,arvalid,rready;wire [511:0] rsp_data;
 wire [31:0] araddr;wire [7:0] arlen;wire [1:0] state_debug;
 reg rvalid=0,rlast=0;reg [127:0] rdata=0;
 integer dticks=0,active=0,beat=0,last=0,delay_count=0,requests=0;
 reg [31:0] address=0;reg [511:0] expected;
 wire arready=dticks%5!=0;
 cyclegan_ddr_read_bridge dut(.*,.enable(1'b1),.rresp(2'b00));
 function automatic [127:0] pattern(input [31:0] a);
  integer j;begin for(j=0;j<16;j=j+1) pattern[j*8+:8]=(a>>4)^(a>>12)^(j*19)^8'h5a;end
 endfunction
 always @(posedge dclk) begin
  dticks<=dticks+1;
  if(!drstn) begin active<=0;rvalid<=0;requests<=0;end
  else begin
   if(arvalid && arready) begin
    if(active) $fatal(1,"Multiple outstanding DDR reads");
    active<=1;address<=araddr;last<=arlen;beat<=0;delay_count<=dticks%13;requests<=requests+1;
   end
   if(active && !rvalid) begin
    if(delay_count!=0) delay_count<=delay_count-1;
    else begin rvalid<=1;rdata<=pattern(address+beat*16);rlast<=beat==last;end
   end
   if(rvalid && rready) begin
    rvalid<=0;
    if(rlast) active<=0;else begin beat<=beat+1;delay_count<=dticks%7;end
   end
  end
 end
 initial begin
  repeat(8) @(negedge dclk);drstn=1;
  repeat(8) @(negedge cclk);crstn=1;
  for(integer n=0;n<2000;n=n+1) begin
   @(negedge cclk);req_addr=n*48;req_beats=n%2 ? 4 : 3;req_valid=1;
   do @(posedge cclk);while(!req_ready);
   @(negedge cclk);req_valid=0;
   expected=0;for(integer b=0;b<req_beats;b=b+1) expected[b*128+:128]=pattern(req_addr+b*16);
   wait(rsp_valid);@(negedge cclk);
   repeat(2+n%11) begin
    if(!rsp_valid || rsp_data!==expected || req_ready) $fatal(1,"Response/ownership n=%0d got=%h expected=%h",n,rsp_data,expected);
    @(negedge cclk);
   end
   rsp_ready=1;@(negedge cclk);rsp_ready=0;
   if(fault) $fatal(1,"Unexpected bridge fault");
  end
  if(requests!=2000) $fatal(1,"Request count %0d",requests);
  $display("PASS DDR bridge: 2000 asynchronous requests, 3/4 beats, response stalls, stable bank ownership");$finish;
 end
 initial begin #30000000;$fatal(1,"Bridge timeout");end
endmodule
