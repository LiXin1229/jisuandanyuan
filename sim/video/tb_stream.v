`timescale 1ns/1ps
module tb_stream;
 reg clk=0;always #5 clk=~clk;reg rstn=0;
 reg valid=0,sof=0,eof=0,abort_frame=0,acquire=0,release_frame=0,copy_start=0;
 reg [23:0] rgb=0;reg [31:0] source=0,destination=32'h600000;
 wire acquired,committed,pp_fault,copy_done,copy_busy,copy_fault,write_active;
 wire [31:0] read_base,read_id,read_checksum;wire [3:0] slots;wire [15:0] captured,dropped,overflow;
 wire pa,par,pw,pwr,pwl,pb,pbr,ta,tar,tw,twr,twl,tb,tbr;
 wire [31:0] paa,taa;wire [7:0] pal,tal;wire [127:0] pwd,twd;
 wire aw,awr,w,wr,wl,b,br,ar,arr,rv,rr,rl;
 wire [31:0] awa,ara;wire [7:0] awl,arl;wire [127:0] wd,rd;wire [1:0] bresp,rresp;
 camera_frame_pingpong #(.PIXELS(64),.FIFO_DEPTH(128)) pp(.clk(clk),.rstn(rstn),.enable(1'b1),
  .s_valid(valid),.s_sof(sof),.s_eof(eof),.s_abort(abort_frame),.s_rgb(rgb),
  .acquire(acquire),.release_frame(release_frame),.acquired(acquired),.committed(committed),
  .read_base(read_base),.read_id(read_id),.read_checksum(read_checksum),.slots(slots),.write_active(write_active),.fault(pp_fault),.captured_frames(captured),.dropped_frames(dropped),.overflow_frames(overflow),
  .awvalid(pa),.awready(par),.awaddr(paa),.awlen(pal),.wvalid(pw),.wready(pwr),.wdata(pwd),.wlast(pwl),.bvalid(pb),.bresp(bresp),.bready(pbr));
 camera_frame_copy #(.BURSTS(2)) cp(.clk(clk),.rstn(rstn),.start(copy_start),.source_base(source),.destination_base(destination),
  .busy(copy_busy),.done(copy_done),.fault(copy_fault),.arvalid(ar),.arready(arr),.araddr(ara),.arlen(arl),
  .rvalid(rv),.rready(rr),.rdata(rd),.rlast(rl),.rresp(rresp),
  .awvalid(ta),.awready(tar),.awaddr(taa),.awlen(tal),.wvalid(tw),.wready(twr),.wdata(twd),.wlast(twl),.bvalid(tb),.bresp(bresp),.bready(tbr));
 axi_write_arbiter2 #(.PRIORITY_WINDOW(1)) arb(.clk(clk),.rstn(rstn),.p_hold(write_active),.p_awvalid(pa),.p_awready(par),.p_awaddr(paa),.p_awlen(pal),
  .p_wvalid(pw),.p_wready(pwr),.p_wdata(pwd),.p_wlast(pwl),.p_bvalid(pb),.p_bready(pbr),
  .t_awvalid(ta),.t_awready(tar),.t_awaddr(taa),.t_awlen(tal),
  .t_wvalid(tw),.t_wready(twr),.t_wdata(twd),.t_wlast(twl),.t_bvalid(tb),.t_bready(tbr),
  .awvalid(aw),.awready(awr),.awaddr(awa),.awlen(awl),.wvalid(w),.wready(wr),.wdata(wd),.wlast(wl),.bvalid(b),.bready(br));
 wire [3:0] aid;wire [31:0] addr;wire [7:0] len;wire atype,avalid,aready;
 AXI4_AWARMux #(.AID_LEN(4),.AADDR_LEN(32)) mux(.aclk_i(clk),.arst_i(!rstn),
  .awid_i(4'd0),.awaddr_i(awa),.awlen_i(awl),.awvalid_i(aw),.awready_o(awr),
  .arid_i(4'd1),.araddr_i(ara),.arlen_i(arl),.arvalid_i(ar),.arready_o(arr),
  .aid_o(aid),.aaddr_o(addr),.alen_o(len),.atype_o(atype),.avalid_o(avalid),.aready_i(aready));
 DdrCtrl mem(.clk(clk),.reset_n(rstn),.axi_aid({4'd0,aid}),.axi_aaddr(addr),.axi_alen(len),.axi_avalid(avalid),.axi_aready(aready),.axi_atype(atype),
  .axi_wdata(wd),.axi_wlast(wl),.axi_wvalid(w),.axi_wready(wr),.axi_bvalid(b),.axi_bready(br),.axi_bresp(bresp),
  .axi_rvalid(rv),.axi_rready(rr),.axi_rdata(rd),.axi_rlast(rl),.axi_rresp(rresp));
 function [23:0] pixel;input integer frame_id,i;begin pixel={(8'(frame_id*31+i)),8'(frame_id*17+i*3),8'(frame_id*7+i*5)};end endfunction
 task send_frame(input integer frame_id,count);
  integer i;
  begin
   for(i=0;i<count;i=i+1) begin
    @(negedge clk);valid=1;sof=i==0;eof=i==count-1;rgb=pixel(frame_id,i);
    @(negedge clk);valid=0;sof=0;eof=0;
   end
  end
 endtask
 task check(input integer base,frame_id);
  integer i;reg [31:0] p;reg [23:0] rgb_ref;
  begin
   for(i=0;i<64;i=i+1) begin
    p=mem.memory[(base>>4)+i/4][(i%4)*32+:32];rgb_ref=pixel(frame_id,i);
    if(p!=={8'd0,rgb_ref[7:0],rgb_ref[15:8],rgb_ref[23:16]}) $fatal(1,"RGBx base=%h i=%0d got=%h",base,i,p);
   end
  end
 endtask
 task take(input integer expected_base,expected_id);
  integer sum,i;reg [31:0] packed_pixel;
  begin
   @(negedge clk);acquire=1;@(negedge clk);acquire=0;wait(acquired);@(negedge clk);
   if(read_base!=expected_base || read_id!=expected_id) $fatal(1,"read ownership/id");
   sum=0;
   for(i=0;i<64;i=i+1) begin packed_pixel=mem.memory[(expected_base>>4)+i/4][(i%4)*32+:32];sum=sum+packed_pixel[7:0]+packed_pixel[15:8]+packed_pixel[23:16];end
   if(read_checksum!==sum) $fatal(1,"capture checksum %0d expected %0d",read_checksum,sum);
  end
 endtask
 task free_read;
  begin @(negedge clk);release_frame=1;@(negedge clk);release_frame=0;end
 endtask
 reg aw_stalled=0;reg [31:0] saved_aw;reg [7:0] saved_len;
 always @(posedge clk) begin
  if(aw_stalled && (!aw || awa!==saved_aw || awl!==saved_len)) $fatal(1,"AW changed during native mux stall");
  aw_stalled<=aw && !awr;saved_aw<=awa;saved_len<=awl;
  if(pa && par && ((paa<32'h100000 && slots[1:0]==3) || (paa>=32'h100000 && slots[3:2]==3))) $fatal(1,"overwrote READING slot");
 end
 initial begin
  repeat(8) @(negedge clk);rstn=1;
  send_frame(0,64);wait(captured==1);check(0,0);take(0,0);
  source=read_base;copy_start=1;@(negedge clk);copy_start=0;
  send_frame(1,64);wait(captured==2 && !copy_busy);check(32'h100000,1);check(32'h600000,0);
  send_frame(2,64);repeat(20) @(negedge clk);
  if(captured!=2 || dropped!=1 || slots!=4'b1011) $fatal(1,"busy frame not dropped intact slots=%b",slots);
  check(0,0);check(32'h100000,1);free_read;take(32'h100000,1);
  source=read_base;destination=32'h700000;copy_start=1;@(negedge clk);copy_start=0;
  send_frame(3,64);wait(captured==3 && !copy_busy);check(0,3);check(32'h700000,1);
  free_read;take(0,3);free_read;
  // An interrupted crop must free its slot and never publish a partial frame.
  @(negedge clk);valid=1;sof=1;rgb=24'habcdef;@(negedge clk);valid=0;sof=0;abort_frame=1;
  @(negedge clk);abort_frame=0;repeat(15) @(negedge clk);
  if(slots || captured!=3) $fatal(1,"abort publication");
  force mem.axi_aready=0;
  send_frame(4,140);release mem.axi_aready;repeat(400) @(negedge clk);
  if(overflow!=1 || slots || captured!=3) $fatal(1,"FIFO overflow cleanup overflow=%0d slots=%b",overflow,slots);
  send_frame(5,64);wait(captured==4);check(0,5);
  if(pp_fault || copy_fault) $fatal(1,"protocol fault");
  $display("PASS camera stream: RGBx packing, two input slots, locked-reader whole-frame drop, concurrent BRAM-buffered DMA and capture priority, native AW/AR stalls, crop abort, FIFO overflow and recovery, final B commit");$finish;
 end
 initial begin #1000000;$fatal(1,"stream timeout");end
endmodule
