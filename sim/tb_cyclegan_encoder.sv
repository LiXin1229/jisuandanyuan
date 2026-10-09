`timescale 1ns/1ps
module tb_cyclegan_encoder;
 reg clk=0;always #5 clk=~clk;
 reg rstn=0,start=0;wire busy,done,fault;
 wire [31:0] cycles,mac_cycles,first_output_cycle,command_wait_cycles,data_wait_cycles;
 wire [31:0] input_checksum;reg [31:0] expected_crc[0:0];
 wire req_valid,req_ready,rsp_ready;wire [31:0] req_addr;wire [2:0] req_beats;
 reg rsp_valid=0;reg [511:0] rsp_data=0;
 reg dbg_rd=0;reg [10:0] dbg_addr=0;wire [799:0] dbg_data;wire dbg_valid;
 wire [4:0] raw_rows,stage1_rows,stage2_rows,stage3_rows;
 integer ticks=0,pending=0,delay_count=0,addr=0,i,j,index,co,col,quad,checks=0,loads=0,overlap=0,commands=0,ddr_delay=2;
 reg [127:0] memory[0:19199];reg [799:0] gold0[0:1535],gold1[0:767],gold2[0:383];reg [799:0] expected;
 string vectors;
 assign req_ready=!pending && !rsp_valid && ticks%7!=0;
 cyclegan_encoder dut(.*,.output_completed(),.output_cycles(),.frame_base(32'd0),.pause_each_block(1'b0),.resume(1'b0),
  .layers_completed(),.decoder_cycles(),.layer_cycles(),.feature_write_valid(),.feature_write_ready(1'b1),.feature_write_addr(),.feature_write_data(),
  .paused(),.blocks_completed(),.residual_output_base(),.encoder_cycles(),.residual_cycles(),.block_cycles());
 always @(posedge clk) if(rstn) begin
  ticks<=ticks+1;
  if($test$plusargs("debug") && (ticks<40 || ticks%1000==0))
   $display("DEBUG tick=%0d state=%0d load_state=%0d phase=%0d core_state=%0d q=%0d",ticks,dut.state,dut.loader.state,dut.phase,dut.unit.state,dut.queued);
  if(ticks%20000==0) $display("ENCODER_TICK %0d state=%0d raw=%0d rows=%0d/%0d/%0d checks=%0d",ticks,dut.state,raw_rows,stage1_rows,stage2_rows,stage3_rows,checks);
  if(req_valid && req_ready) begin
   if(req_beats!=3 || req_addr[3:0]!=0) $fatal(1,"DDR alignment");
   addr=req_addr>>4;pending<=1;delay_count<=ddr_delay+(ddr_delay==2 ? ticks%9 : ticks%29);
  end
  if(pending) begin
   if(delay_count!=0) delay_count<=delay_count-1;
   else begin
    for(i=0;i<3;i=i+1) rsp_data[i*128+:128]<=memory[addr+i];
    rsp_valid<=1;pending<=0;
   end
  end
  if(rsp_valid && rsp_ready) rsp_valid<=0;
  if(dut.load_wr) begin
   loads=loads+1;
   if(dut.core_busy) overlap=overlap+1;
   if(dut.unit.cache_rd_en && dut.unit.cache_rd_addr==dut.load_addr) $fatal(1,"DMA/read ownership collision");
   if(dut.unit.result_write && dut.unit.dst_base==dut.load_addr) $fatal(1,"DMA/write ownership collision");
  end
  if(dut.unit.fifo_pop) commands=commands+1;
  if(dut.unit.result_write && dut.unit.cmd[46]) begin
   quad=dut.unit.write_mode-1;
   if(dut.stage==0) begin
    co=(dut.unit.dst_base-288)%8;col=((dut.unit.dst_base-288)%128)/8;
    index=co*192+(dut.y>>1)*16+col;expected=gold0[index];
   end else if(dut.stage==1) begin
    co=(dut.unit.dst_base-672)%16;col=((dut.unit.dst_base-672)%128)/16;
    index=co*48+(dut.y>>1)*8+col;expected=gold1[index];
   end else begin index=dut.unit.dst_base-1056;expected=gold2[index];end
   for(j=0;j<25;j=j+1) if(dut.unit.pdata[j*8+:8]!==expected[quad*200+j*8+:8])
    $fatal(1,"Pool mismatch stage=%0d y=%0d dst=%0d quad=%0d pixel=%0d got=%0d expected=%0d",dut.stage,dut.y,dut.unit.dst_base,quad,j,$signed(dut.unit.pdata[j*8+:8]),$signed(expected[quad*200+j*8+:8]));
   checks=checks+25;
  end
  if(dut.state==dut.SELECT && dut.completed!=0 && dut.stage==0)
   $display("ENCODER_PROGRESS raw=%0d rows=%0d/%0d/%0d cycles=%0d",raw_rows,stage1_rows,stage2_rows,stage3_rows,cycles);
  if(fault) $fatal(1,"Core fault error=%0d rows=%0d/%0d/%0d",dut.error_code,stage1_rows,stage2_rows,stage3_rows);
  if(ticks>3000000) $fatal(1,"Timeout state=%0d loaded=%0d rows=%0d/%0d/%0d",dut.state,raw_rows,stage1_rows,stage2_rows,stage3_rows);
 end
 initial begin
  if($value$plusargs("ddr-delay=%d",ddr_delay)) $display("DDR base latency=%0d",ddr_delay);
  if(!$value$plusargs("vectors=%s",vectors)) vectors="build/stage1/vectors";
  $readmemh({vectors,"/frame_rgbx.mem"},memory);$readmemh({vectors,"/stage1_tiles.mem"},gold0);
  $readmemh({vectors,"/input_crc.mem"},expected_crc);
  $readmemh({vectors,"/stage2_tiles.mem"},gold1);$readmemh({vectors,"/stage3_tiles.mem"},gold2);
  repeat(5) @(negedge clk);rstn=1;repeat(3) @(negedge clk);start=1;@(negedge clk);start=0;
  wait(done);@(negedge clk);
  if(input_checksum!==expected_crc[0]) $fatal(1,"Input CRC got=%h expected=%h",input_checksum,expected_crc[0]);
  if(checks!=268800 || loads!=23040 || commands!=28416 || command_wait_cycles!=0 || overlap==0)
   $fatal(1,"Counts checks=%0d loads=%0d commands=%0d command_wait=%0d overlap=%0d",checks,loads,commands,command_wait_cycles,overlap);
  for(index=0;index<384;index=index+1) begin
   @(negedge clk);dbg_addr=1056+index;dbg_rd=1;@(negedge clk);dbg_rd=0;
   if(!dbg_valid || dbg_data!==gold2[index]) $fatal(1,"Final tile %0d",index);
  end
  $display("PASS stage1: values=%0d final_tiles=384 commands=%0d cycles=%0d busy=%0d command_wait=%0d data_wait=%0d overlapping_row_writes=%0d first_output=%0d",checks,commands,cycles,mac_cycles,command_wait_cycles,data_wait_cycles,overlap,first_output_cycle);
  $finish;
 end
endmodule
