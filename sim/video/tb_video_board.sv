`timescale 1ns/1ps
// Real capture/copy, CDC bridges, writer, DDR arbitration and HDMI.
// Network protocol model checks every input word and emits golden half tiles.
// Numerical computation is checked on the board against fresh integer models.
module tb_video_board;
 reg vclk=0,dclk=0,cclk=0;always #6.720430 vclk=~vclk;
 always #5.208333 dclk=~dclk;always #2.916667 cclk=~cclk;
 cyclegan_camera_board #(.SIM_CAMERA(1)) dut(.clk_video(vclk),.clk_video_5x(1'b0),.clk_video_fb(dclk),.video_pll_lock(1'b1),
  .camera_pll_lock(1'b1),.clk_camera_fb(dclk),.clk_27m(dclk),.key_data(2'b11),
  .clk_sys(dclk),.clk_compute(cclk),.sys_pll_lock(1'b1),.core_clk(dclk),.tdqss_clk(dclk),.tac_clk(dclk),.twd_clk(dclk),.ddr_pll_lock(1'b1),
  .i_dq_hi(16'd0),.i_dq_lo(16'd0),.i_dqs_hi(2'd0),.i_dqs_lo(2'd0),
  .bscan_CAPTURE(1'b0),.bscan_DRCK(1'b0),.bscan_RESET(1'b0),.bscan_RUNTEST(1'b0),.bscan_SEL(1'b0),
  .bscan_SHIFT(1'b0),.bscan_TCK(1'b0),.bscan_TDI(1'b0),.bscan_TMS(1'b0),.bscan_UPDATE(1'b0));
 reg [127:0] image0[0:19199],image1[0:19199];reg [799:0] gold0[0:2303],gold1[0:2303];
 integer checks=0,overlapped_starts=0;
 always @(posedge dclk) if(dut.drstn) begin
  if(dut.schedule_start && dut.ready_toggle!=dut.frame_ack_toggle) overlapped_starts=overlapped_starts+1;
  if(dut.copy_start && dut.ready_toggle!=dut.frame_ack_toggle)
   $fatal(1,"Copy overwrote a display-owned original bank");
 end
 always @(posedge cclk) if(dut.crstn && dut.u_output.s_valid && dut.feature_write_addr[31:20]==12'h006 && !dut.output_bank_ready)
  $fatal(1,"Final write reached a display-owned output bank");
 task inject(input integer variant);
  integer p;reg [31:0] pixel;
  begin
   for(p=0;p<76800;p=p+1) begin
    pixel=variant ? image1[p/4][(p%4)*32+:32] : image0[p/4][(p%4)*32+:32];
    @(negedge dclk);dut.g_sim.inject_valid=1;dut.g_sim.inject_sof=p==0;dut.g_sim.inject_eof=p==76799;
    dut.g_sim.inject_rgb={pixel[7:0],pixel[15:8],pixel[23:16]};
    @(negedge dclk);dut.g_sim.inject_valid=0;dut.g_sim.inject_sof=0;dut.g_sim.inject_eof=0;
    repeat(6) @(negedge dclk);
   end
  end
 endtask
 task check_frame(input integer variant);
  integer i,j,base,original,slot;reg [799:0] actual,expected;reg [127:0] word;
  begin
   slot=dut.styled_write_base[20];base=dut.styled_write_base>>4;
   original=dut.copy_destination>>4;
   if(slot!=variant || dut.read_id!=variant) $fatal(1,"Frame/bank pairing variant=%0d slot=%0d id=%0d",variant,slot,dut.read_id);
   for(i=0;i<2304;i=i+1) begin
    actual=0;
    for(j=0;j<4;j=j+1) begin
     word=dut.u_ddr.memory[base+i*8+j];
     if(j<3) actual[j*128+:128]=word;
     else begin actual[384+:16]=word[15:0];if(word[127:16]!==0) $fatal(1,"Lower half padding");end
     word=dut.u_ddr.memory[base+i*8+4+j];
     if(j<3) actual[400+j*128+:128]=word;
     else begin actual[784+:16]=word[15:0];if(word[127:16]!==0) $fatal(1,"Upper half padding");end
    end
    expected=variant ? gold1[i] : gold0[i];
    if(actual!==expected) $fatal(1,"Video network mismatch frame=%0d tile=%0d",variant,i);
    checks=checks+100;
   end
   for(i=0;i<19200;i=i+1) if(dut.u_ddr.memory[original+i] !== (variant ? image1[i] : image0[i]))
    $fatal(1,"Matched original copy frame=%0d word=%0d",variant,i);
   if(dut.command_wait_cycles!=0 || dut.blocks_completed!=9 || dut.layers_completed!=3 || !dut.output_completed)
    $fatal(1,"Network completion/command starvation");
   $display("VIDEO_PROTOCOL_FRAME_PASS frame=%0d slot=%0d RGB=230400 cycles=%0d command_wait=%0d",variant,slot,dut.cycles,dut.command_wait_cycles);
  end
 endtask
 always @(posedge dclk) if(dut.drstn && (dut.pp_fault || dut.bridge_fault || dut.core_fault || dut.video_fault || dut.overflow_frames || dut.video_underflows || dut.video_checksum_errors))
  $fatal(1,"Video pipeline fault status=%h",dut.status);
 initial begin
  $readmemh("build/stage4/vectors/frame_rgbx.mem",image0);$readmemh("build/stage4/vectors_inverted/frame_rgbx.mem",image1);
  $readmemh("build/stage4/vectors/output_u8_tiles.mem",gold0);$readmemh("build/stage4/vectors_inverted/output_u8_tiles.mem",gold1);
  wait(dut.enable);repeat(100) @(negedge dclk);
  inject(0);wait(dut.core_busy);inject(1);
  // Both input slots are owned: the complete third camera frame is dropped.
  inject(0);
  wait(dut.core_done);force dut.frame_ack_toggle=0;@(negedge cclk);check_frame(0);
  // Delay acknowledgement beyond the next network's final-output request.
  // Its input reads may proceed, but neither copy nor final write may proceed.
  wait(!dut.core_done);wait(dut.feature_write_valid && !dut.bank_ready_c2);
  repeat(100) @(negedge cclk);
  if(dut.feature_write_ready || dut.u_output.s_valid || dut.copy_busy || dut.frames!=1)
   $fatal(1,"Delayed VSYNC ownership did not backpressure final output");
  release dut.frame_ack_toggle;
  wait(dut.core_done);@(negedge cclk);check_frame(1);
  dut.control=4;wait(!dut.running);wait(dut.active_slot==1 && dut.frame_ack_toggle==dut.ready_toggle);
  repeat(100) @(negedge dclk);
  if(dut.frames!=2 || dut.captured_frames!=2 || dut.dropped_frames!=1 || checks!=460800 || dut.slots!=0 || overlapped_starts==0)
   $fatal(1,"Capture lifecycle frames=%0d captured=%0d dropped=%0d slots=%h",dut.frames,dut.captured_frames,dut.dropped_frames,dut.slots);
  $display("PASS camera board protocol: 460800 exact output RGB bytes, complete input/copy checks, real CDC/writer/DDR arbiters, encoder starts before prior VSYNC ack, final writes gated by output ownership, full-frame drop, no faults/underflow");$finish;
 end
 initial begin #180000000;$fatal(1,"Video integration timeout state=%0d frames=%0d",dut.u_schedule.state,dut.frames);end
endmodule
