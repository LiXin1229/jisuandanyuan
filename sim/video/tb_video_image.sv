`timescale 1ns/1ps
// Exact upload/copy/display protocol gate. Board reference checks arithmetic.
module tb_video_image;
 reg vclk=0,dclk=0,cclk=0;always #6.720430 vclk=~vclk;
 always #5.208333 dclk=~dclk;always #2.916667 cclk=~cclk;
 cyclegan_camera_board #(.HOST_IMAGE(1)) dut(.clk_video(vclk),.clk_video_5x(1'b0),.clk_video_fb(dclk),.video_pll_lock(1'b1),
  .camera_pll_lock(1'b1),.clk_camera_fb(dclk),.clk_27m(dclk),.key_data(2'b11),
  .clk_sys(dclk),.clk_compute(cclk),.sys_pll_lock(1'b1),.core_clk(dclk),.tdqss_clk(dclk),.tac_clk(dclk),.twd_clk(dclk),.ddr_pll_lock(1'b1),
  .i_dq_hi(16'd0),.i_dq_lo(16'd0),.i_dqs_hi(2'd0),.i_dqs_lo(2'd0),
  .bscan_CAPTURE(1'b0),.bscan_DRCK(1'b0),.bscan_RESET(1'b0),.bscan_RUNTEST(1'b0),.bscan_SEL(1'b0),
  .bscan_SHIFT(1'b0),.bscan_TCK(1'b0),.bscan_TDI(1'b0),.bscan_TMS(1'b0),.bscan_UPDATE(1'b0));
 defparam dut.u_core.CORE_DELAY=1000;
 reg [127:0] image[0:19199];reg [799:0] gold[0:2303];
 reg toggle=0;integer i,j,base,checks=0;reg [511:0] packet;reg [127:0] word;
 task command(input [2:0] op,input [27:0] arg,input [511:0] payload);
  integer timeout;
  begin
   @(negedge dclk);toggle=~toggle;
   dut.g_image_debug.u_debug.vio0_payload0=payload[255:0];
   dut.g_image_debug.u_debug.vio0_payload1=payload[511:256];
   dut.g_image_debug.u_debug.vio0_command={toggle,op,arg};
   timeout=0;
   while(dut.ack!=toggle) begin
    @(negedge dclk);timeout=timeout+1;
    if(timeout>100000) $fatal(1,"JTAG command timeout op=%0d",op);
   end
   @(negedge dclk);
  end
 endtask
 always @(posedge dclk) if(dut.drstn && (dut.pp_fault || dut.bridge_fault || dut.core_fault || dut.video_fault || dut.overflow_frames || dut.video_underflows || dut.video_checksum_errors))
  $fatal(1,"Fixed-image video fault status=%h",dut.status);
 initial begin
  $readmemh("build/stage4/vectors/frame_rgbx.mem",image);
  $readmemh("build/stage4/vectors/output_u8_tiles.mem",gold);
  wait(dut.enable);repeat(100) @(negedge dclk);
  command(2,0,0);if(!dut.protocol_error) $fatal(1,"Unarmed packet accepted");
  command(1,0,0);if(dut.protocol_error) $fatal(1,"Frame begin rejected");
  command(1,0,0);if(!dut.protocol_error) $fatal(1,"Duplicate begin accepted");
  for(i=0;i<4800;i=i+1) begin
   for(j=0;j<4;j=j+1) packet[j*128+:128]=image[i*4+j];
   command(2,0,packet);
   if(dut.protocol_error) $fatal(1,"Packet rejected index=%0d",i);
   repeat(i%9) @(negedge dclk);
  end
  wait(dut.captured_frames==1);
  if(dut.host_armed || dut.frames || dut.slots!=2) $fatal(1,"Input committed before/after wrong boundary");
  for(i=0;i<19200;i=i+1) if(dut.u_ddr.memory[i]!==image[i]) $fatal(1,"Upload RGBx word=%0d",i);
  command(2,0,0);if(!dut.protocol_error) $fatal(1,"Excess packet accepted");
  command(3,3,0);wait(dut.frames==1);command(3,7,0);
  wait(dut.active_style && dut.frame_ack_toggle==dut.ready_toggle);
  base=dut.styled_write_base>>4;
  for(i=0;i<2304;i=i+1) begin
   for(j=0;j<8;j=j+1) begin
    word=dut.u_ddr.memory[base+i*8+j];
    if(j%4==3) begin
     if(word[127:16]!==0) $fatal(1,"Output padding tile=%0d beat=%0d",i,j);
     if(word[15:0]!==gold[i][(j/4)*400+384+:16]) $fatal(1,"Output tail");
    end else if(word!==gold[i][(j/4)*400+(j%4)*128+:128]) $fatal(1,"Output word");
   end
   checks=checks+100;
  end
  base=dut.copy_destination>>4;
  for(i=0;i<19200;i=i+1) if(dut.u_ddr.memory[base+i]!==image[i]) $fatal(1,"Original copy word=%0d",i);
  for(i=0;i<16;i=i+1) begin
   command(6,(dut.copy_destination+i*64)>>4,0);
   for(j=0;j<4;j=j+1) if(dut.read_data[j*128+:128]!==image[i*4+j]) $fatal(1,"Debug DDR word");
  end
  command(3,5,0);wait(!dut.active_style);repeat(2500000) @(negedge dclk);
  if(dut.video_underflows || dut.video_checksum_errors || dut.frames!=1 || dut.slots || checks!=230400)
   $fatal(1,"Frozen original HDMI failure");
  command(3,7,0);wait(dut.active_style);
  $display("PASS camera fixed image: 307200 uploaded RGBx bytes, 230400 output bytes, original copy, delayed ACK, invalid packets, debug DDR, frozen HDMI, zero faults");$finish;
 end
 initial begin #120000000;$fatal(1,"Fixed image timeout frames=%0d",dut.frames);end
endmodule
