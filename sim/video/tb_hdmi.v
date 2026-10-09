`timescale 1ns/1ps
module tb_hdmi;
 reg dclk=0,pclk=0;always #5.208333 dclk=~dclk;always #6.720430 pclk=~pclk;
 reg rstn=0,ready_toggle=0,slot=0,style=1;
 wire va,vr,vv,vready,vlast,video_read_active,video_read_urgent;wire [31:0] vaddr;wire [7:0] vlen;wire [127:0] vd;
 wire av,ardy,rv,rr,rlast;wire [31:0] aa;wire [7:0] al;reg [127:0] rd;
 wire ack,active_slot,active_style;
 wire [9:0] txc,b,g,r;wire [23:0] rgb;wire de,hs,vs,fault;
 wire [15:0] frames,misses;wire [31:0] lines,checksum;
 reg [31:0] expected0=0,expected1=0;wire [15:0] checksum_errors;
 camera_hdmi #(.CHECK_ORIGINAL_SUM(1)) dut(.dclk(dclk),.drstn(rstn),.pclk(pclk),.prstn(rstn),
  .checksum0(expected0),.checksum1(expected1),.checksum_errors(checksum_errors),
  .frame_ready_toggle(ready_toggle),.frame_slot(slot),.select_style(style),
  .frame_ack_toggle(ack),.active_slot(active_slot),.active_style(active_style),
  .arvalid(va),.read_active(video_read_active),.read_urgent(video_read_urgent),.arready(vr),.araddr(vaddr),.arlen(vlen),.rvalid(vv),.rready(vready),.rdata(vd),.rlast(vlast),.rresp(2'd0),
  .txc(txc),.txd0(b),.txd1(g),.txd2(r),.loaded_lines(lines),.fault(fault),
  .displayed_frames(frames),.underflows(misses),.pixel_sum(checksum),.video_rgb(rgb),.video_de(de),.video_hs(hs),.video_vs(vs));
 wire pv,pr,prv,prlast;wire [127:0] pd;reg p_wait=0,p_request=0,traffic_enable=1;integer p_sent=0,p_done=0,ticks=0;
 integer fair_core=0,urgent_video=0,style_ars=0,style_bytes=0,raw_ars=0;
 assign pv=p_request;
 axi_read_arbiter2 #(.VIDEO_WINDOW(1)) arb(.clk(dclk),.rstn(rstn),.v_hold(video_read_urgent),.p_valid(pv),.p_ready(pr),.p_addr(32'ha00000),.p_len(8'd7),
  .p_rvalid(prv),.p_rready(1'b1),.p_data(pd),.p_last(prlast),
  .v_valid(va),.v_ready(vr),.v_addr(vaddr),.v_len(vlen),.v_rvalid(vv),.v_rready(vready),.v_data(vd),.v_last(vlast),
  .arvalid(av),.arready(ardy),.araddr(aa),.arlen(al),.rvalid(rv),.rready(rr),.rdata(rd),.rlast(rlast));
 // Use the real registered board address mux; a direct AR model misses ownership races.
 wire [31:0] native_addr;wire [7:0] native_len;wire nv,nready;
 AXI4_AWARMux #(.AID_LEN(4),.AADDR_LEN(32)) mux(.aclk_i(dclk),.arst_i(!rstn),
  .awid_i(4'd0),.awaddr_i(32'd0),.awlen_i(8'd0),.awvalid_i(1'b0),.awready_o(),
  .arid_i(4'd1),.araddr_i(aa),.arlen_i(al),.arvalid_i(av),.arready_o(ardy),
  .aid_o(),.aaddr_o(native_addr),.alen_o(native_len),.atype_o(),.avalid_o(nv),.aready_i(nready));
 function [7:0] color;input integer bank,raw,c,x,y;begin color=(bank*53+raw*37+c*71+x*13+y*19+(x*y)%251)&255;end endfunction
 function [7:0] byte_at;input integer addr;integer tile,off,c,x,y,q,j,bank;
  begin
   if(addr>=32'ha00000) byte_at=8'h5a;
   else if(addr>=32'h800000) begin
    bank=(addr>=32'h900000);off=addr-(bank ? 32'h900000 : 32'h800000);
    c=off%4;x=(off/4)%320;y=off/1280;
    byte_at=c<3 ? color(bank,1,c,x,y) : 0;
   end else begin
    bank=addr>=32'h700000;off=addr-(bank ? 32'h700000 : 32'h600000);tile=off/128;off=off%128;
    c=tile/768;x=(tile%32)*10;y=((tile%768)/32)*10;
    if(off%64<50) off=(off/64)*50+off%64;else off=100;
    q=off/25;j=off%25;
    byte_at=off<100 ? color(bank,0,c,x+(q%2)*5+j%5,y+(q/2)*5+j/5) : 0;
   end
  end
 endfunction
 integer beat=0,length=0,i,reply_delay=0;reg reading=0,valid=0;reg [31:0] address=0;reg inject_bad_read=0;
 assign nready=rstn && !reading && ticks%9!=0;
 assign rv=valid;assign rlast=beat==length;
 reg ar_stalled=0;reg [31:0] saved_ar;reg [7:0] saved_len;
 always @(posedge dclk) begin
  ticks<=ticks+1;
  if(vv && !vready) $fatal(1,"HDMI stalled a DDR response beat");
  if(ar_stalled && (!av || aa!==saved_ar || al!==saved_len)) $fatal(1,"AR changed while registered mux stalled");
  ar_stalled<=av && !ardy;saved_ar<=aa;saved_len<=al;
  // Continuous competing eight-beat reads, plus delayed video responses.
  if(rstn && traffic_enable && !p_wait && !p_request) p_request<=1;
  if(pv && pr) begin
   p_request<=0;p_wait<=1;p_sent<=p_sent+1;
   if(video_read_active && !video_read_urgent) fair_core<=fair_core+1;
  end
  if(va && vr) begin
   if(video_read_urgent) urgent_video<=urgent_video+1;
   if(dut.raw_mode) raw_ars=raw_ars+1;
   else begin style_ars=style_ars+1;style_bytes=style_bytes+(vlen+1)*16;end
  end
  if((dut.state==3 || (vv && dut.raw_mode)) && dut.v>=145 && dut.v<625 &&
     dut.store_bank==dut.display_y[1:0]) $fatal(1,"DMA overwrote displayed row: v=%0d h=%0d display_y=%0d source_y=%0d bank=%0d want=%0d raw=%0d",dut.v,dut.h,dut.display_y,dut.source_y,dut.store_bank,dut.want_y,dut.raw_mode);
  if(prv) begin
   if(pd!=={16{8'h5a}}) $fatal(1,"arbiter response owner changed");
   if(prlast) begin p_wait<=0;p_done<=p_done+1;end
  end
  if(nv && nready) begin
   address<=native_addr;length<=native_len;beat<=0;reading<=1;
   reply_delay<=native_addr>=32'ha00000 ? 64 : 40;
  end
  if(valid && rr) begin valid<=0;if(beat==length) reading<=0;else beat<=beat+1;end
  if(reply_delay>0) reply_delay<=reply_delay-1;
  if(reading && !valid && reply_delay==0 && ticks%7!=0) begin
   for(i=0;i<16;i=i+1)
    rd[i*8+:8]<=inject_bad_read && address+beat*16+i==32'h900064 ? 8'd0 : byte_at(address+beat*16+i);
   valid<=1;
  end
 end
 integer h1=0,v1=0,h2=0,v2=0,checked=0,tmds_checked=0,x,y,c,epoch=0;
 reg expected_slot=0,expected_raw=0;reg [23:0] prev_rgb=0;reg prev_de=0;
 function [7:0] decode;input [9:0] code;reg [7:0] q,value;integer j;
  begin q=code[7:0]^{8{code[9]}};value[0]=q[0];
   for(j=1;j<8;j=j+1) value[j]=code[8] ? q[j]^q[j-1] : ~(q[j]^q[j-1]);decode=value;
  end
 endfunction
 always @(posedge pclk) begin
  h1<=dut.h;v1<=dut.v;h2<=h1;v2<=v1;prev_rgb<=rgb;prev_de<=de;
  if(rstn && dut.h==0 && dut.v==0) begin
   if(epoch>=2 && epoch<6) begin
    if(!expected_raw && (style_ars!=11520 || style_bytes!=663552 || raw_ars!=0))
     $fatal(1,"Paired frame AR=%0d bytes=%0d raw=%0d",style_ars,style_bytes,raw_ars);
    if(expected_raw && (raw_ars!=2400 || style_ars!=0))
     $fatal(1,"RGBx frame AR=%0d style=%0d",raw_ars,style_ars);
   end
   style_ars=0;style_bytes=0;raw_ars=0;
   epoch<=epoch+1;
   if(dut.ready2!=dut.ready_seen) expected_slot<=slot;
   expected_raw<=!dut.style2;
  end
 end
 always @(negedge pclk) if(rstn && epoch>=2 && epoch<6) begin
  if(de!==(h2>=260 && h2<1540 && v2>=25 && v2<745)) $fatal(1,"data enable alignment");
  if(de && h2>=580 && h2<1220 && v2>=145 && v2<625) begin
   x=(h2-580)/2;y=(v2-145)/2;
   if(rgb!=={color(expected_slot,expected_raw,0,x,y),color(expected_slot,expected_raw,1,x,y),color(expected_slot,expected_raw,2,x,y)})
    $fatal(1,"RGB slot=%0d raw=%0d x=%0d y=%0d got=%h",expected_slot,expected_raw,x,y,rgb);
   checked=checked+1;
  end else if(rgb!==0) $fatal(1,"black border");
  if(prev_de) begin
   if({decode(r),decode(g),decode(b)}!==prev_rgb) $fatal(1,"TMDS decode");tmds_checked=tmds_checked+3;
  end
 end
 initial begin
  for(integer sy=0;sy<240;sy=sy+1) for(integer sx=0;sx<320;sx=sx+1) for(integer sc=0;sc<3;sc=sc+1) begin
   expected0=expected0+4*color(0,1,sc,sx,sy);expected1=expected1+4*color(1,1,sc,sx,sy);
  end
  repeat(10) @(negedge pclk);rstn=1;ready_toggle=1;
  wait(epoch==2 && dut.v==400);@(negedge pclk);style=0;
  wait(epoch==3 && dut.v==400);@(negedge pclk);slot=1;ready_toggle=0;
  wait(epoch==4 && dut.v==400);@(negedge pclk);style=1;
  wait(epoch==6);@(negedge pclk);
  traffic_enable=0;
  wait(!p_wait && !p_request);repeat(5) @(negedge dclk);
  if(fault || misses || checksum_errors || checked!=4*307200 || p_sent!=p_done || fair_core==0 || urgent_video==0 || ack!==ready_toggle)
   $fatal(1,"HDMI pixels=%0d underflows=%0d core=%0d/%0d ack=%0b",checked,misses,p_sent,p_done,ack);
  style=0;inject_bad_read=1;
  wait(epoch==8);@(negedge pclk);
  repeat(10) @(negedge dclk);
  if(checksum_errors!=1 || dut.error_expected_sum!==expected1 ||
     dut.error_ddr_sum!==expected1-4*color(1,1,0,25,0) || dut.error_video_sum!==dut.error_ddr_sum ||
     dut.error_context[8:0]!==9'd240 || dut.error_context[9]!==1'b1)
   $fatal(1,"Bad-read diagnosis errors=%0d expected=%0d DDR=%0d video=%0d context=%h",
    checksum_errors,dut.error_expected_sum,dut.error_ddr_sum,dut.error_video_sum,dut.error_context);
  $display("PASS camera HDMI: %0d exact scaled pixels, %0d TMDS values, 11520 AR/663552 bytes per style frame, four-row ownership, %0d core reads (%0d during relaxed video), %0d urgent video grants, registered mux stalls, no underflow; injected corruption localized",checked,tmds_checked,p_done,fair_core,urgent_video);$finish;
 end
 initial begin #150000000;$fatal(1,"HDMI timeout");end
endmodule

