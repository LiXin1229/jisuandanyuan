`timescale 1ns/1ps
// Real compute RTL, both CDC bridges and randomized DDR backpressure.
// Starts from the independently generated ninth residual output.
module tb_cyclegan_decoder #(parameter FULL_PREFIX=0);
 reg clk=0,dclk=0;always #3.333 clk=~clk;always #5.208 dclk=~dclk;
 reg rstn=0,start=0,seed_wr=0;reg [10:0] seed_addr=0;reg [799:0] seed_data=0;
 wire [127:0] instruction;wire instruction_valid,instruction_ready,core_busy,memory_ready;wire [2:0] queued;
 wire core_done,wb_valid;wire [10:0] wb_addr;wire [3:0] wb_opcode,error_code;
 wire done,paused;reg pause_each_layer=1,resume=0;wire [1:0] layers_completed;
 wire [31:0] cycles,layer_cycles,command_wait_cycles,data_wait_cycles;
 wire req_valid,req_ready,rsp_valid,rsp_ready;wire [31:0] req_addr;wire [2:0] req_beats;wire [511:0] rsp_data;
 wire cache_wr,cache_ready,cache_rd,cache_read_ready,cache_rvalid;wire [10:0] cache_waddr,cache_raddr;
 wire [799:0] cache_wdata,cache_rdata;wire [39:0] cache_we;
 wire write_valid,write_ready;wire [31:0] write_addr;wire [399:0] write_data;
 wire awvalid,awready,wvalid,wready,wlast,bready;wire [31:0] awaddr;wire [7:0] awlen;wire [127:0] wdata;
 reg bvalid=0;wire writer_fault,bridge_fault;
 wire arvalid,arready,rready;wire [31:0] araddr;wire [7:0] arlen;
 reg rvalid=0,rlast=0;reg [127:0] rdata=0;
 reg [127:0] memory[0:376831];reg [799:0] seed[0:383],gold1[0:767],gold2[0:1535],gold3[0:6143];
 integer ticks=0,dticks=0,commands=0,halves=0,checks=0,overlap=0,reads=0;
 integer read_address=0,read_beat=0,read_len=0,write_address=0,write_beat=0,write_len=0;
 integer read_delay=0,bdelay=0,ddr_delay=2,layer,i,j,k,index,region,half,values=0;
 reg read_pending=0,write_pending=0,response_pending=0;
 string vectors;reg [799:0] expected;reg [399:0] expected_half;reg [31:0] saved_cycles;
 wire fifo_pop,core_cache_rd_en,prefix_fault,decoder_active;
 wire [10:0] core_cache_rd_addr;wire [127:0] core_cmd;wire [799:0] core_result;
 wire [1:0] decoder_layer,slot_owned,slot_ready;wire [3:0] decoder_y,decoder_loaded,pack_state;
 wire [4:0] decoder_co;wire [3:0] blocks_completed;wire [31:0] prefix_total_cycles,input_checksum;
 reg [799:0] gold_res[0:3455];integer residual_values=0,block;
 assign awready=!write_pending && !response_pending && !bvalid && dticks%7!=0;
 assign wready=write_pending && dticks%5!=0;
 assign arready=!read_pending && !rvalid && dticks%11!=0;
 generate if(!FULL_PREFIX) begin:g_seeded
 cyclegan_decoder_scheduler scheduler(.*,.frame_start(1'b0),.writeback_valid(wb_valid),.writeback_addr(wb_addr),.writeback_opcode(wb_opcode));
 mobilenet_unit #(.MODEL_PARAMS(1),.DECODER_PREFIX(1),.STREAM_WRITES(1),.STREAM_READS(1)) unit(
  .clk(clk),.reset(!rstn),.instruction(instruction),.instruction_valid(instruction_valid),.instruction_ready(instruction_ready),.instruction_count(queued),
  .host_cache_wr(seed_wr || cache_wr),.host_cache_waddr(seed_wr ? seed_addr : cache_waddr),
  .host_cache_wdata(seed_wr ? seed_data : cache_wdata),.host_cache_wmask(seed_wr ? 40'hffffffffff : cache_we),
  .host_cache_rd(cache_rd),.host_cache_raddr(cache_raddr),.host_cache_rdata(cache_rdata),.host_cache_rvalid(cache_rvalid),
  .host_memory_ready(memory_ready),.host_stream_ready(cache_ready),.host_read_ready(cache_read_ready),.host_param_wr(1'b0),.host_param_addr(15'd0),.host_param_data(16'd0),
  .busy(core_busy),.done(core_done),.error_code(error_code),.writeback_valid(wb_valid),.writeback_addr(wb_addr),.writeback_opcode(wb_opcode));
 assign fifo_pop=unit.fifo_pop;assign core_cache_rd_en=unit.cache_rd_en;assign core_cache_rd_addr=unit.cache_rd_addr;
 assign core_cmd=unit.cmd;assign core_result=unit.result_data;assign prefix_fault=0;assign decoder_active=1;
 assign decoder_layer=scheduler.layer;assign decoder_y=scheduler.y;assign decoder_co=scheduler.co;
 assign decoder_loaded=scheduler.loaded_rows;assign slot_owned=scheduler.owned;assign slot_ready=scheduler.ready_slots;assign pack_state=scheduler.pack_state;
 assign blocks_completed=0;assign prefix_total_cycles=cycles;assign input_checksum=0;
 end else begin:g_prefix
 cyclegan_encoder #(.RESIDUAL_ENABLE(1),.DECODER_ENABLE(1)) dut(.clk(clk),.rstn(rstn),.start(start),.frame_base(32'd0),
  .done(done),.fault(prefix_fault),.cycles(prefix_total_cycles),.command_wait_cycles(command_wait_cycles),.data_wait_cycles(data_wait_cycles),.input_checksum(input_checksum),
  .req_valid(req_valid),.req_ready(req_ready),.req_addr(req_addr),.req_beats(req_beats),.rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_data(rsp_data),
  .dbg_rd(1'b0),.dbg_addr(11'd0),.pause_each_block(pause_each_layer),.resume(resume),.paused(paused),.blocks_completed(blocks_completed),
  .layers_completed(layers_completed),.decoder_cycles(cycles),.layer_cycles(layer_cycles),
  .feature_write_valid(write_valid),.feature_write_ready(write_ready),.feature_write_addr(write_addr),.feature_write_data(write_data));
 assign fifo_pop=dut.unit.fifo_pop;assign core_cache_rd_en=dut.unit.cache_rd_en;assign core_cache_rd_addr=dut.unit.cache_rd_addr;
 assign core_cmd=dut.unit.cmd;assign core_result=dut.unit.result_data;assign core_done=dut.core_done;assign core_busy=dut.core_busy;
 assign memory_ready=dut.memory_ready;assign queued=dut.queued;assign error_code=dut.error_code;
 assign wb_valid=dut.wb_valid;assign wb_addr=dut.wb_addr;assign wb_opcode=dut.wb_opcode;
 assign cache_wr=dut.state==dut.DECODER ? dut.decoder_wr : dut.load_wr;
 assign cache_waddr=dut.state==dut.DECODER ? dut.decoder_waddr : dut.load_addr;
 assign cache_rd=dut.unit.host_cache_rd;assign decoder_active=dut.state==dut.DECODER;
 assign decoder_layer=dut.g_decoder.scheduler.layer;assign decoder_y=dut.g_decoder.scheduler.y;assign decoder_co=dut.g_decoder.scheduler.co;
 assign decoder_loaded=dut.g_decoder.scheduler.loaded_rows;assign slot_owned=dut.g_decoder.scheduler.owned;assign slot_ready=dut.g_decoder.scheduler.ready_slots;
 assign pack_state=dut.g_decoder.scheduler.pack_state;
 end endgenerate
 cyclegan_feature_writer writer(.cclk(clk),.crstn(rstn),.s_valid(write_valid),.s_ready(write_ready),.s_addr(write_addr),.s_data(write_data),.fault(writer_fault),
  .dclk(dclk),.drstn(rstn),.enable(1'b1),.awvalid(awvalid),.awready(awready),.awaddr(awaddr),.awlen(awlen),.wvalid(wvalid),.wready(wready),.wdata(wdata),.wlast(wlast),
  .bvalid(bvalid),.bready(bready),.bresp(2'b00));
 cyclegan_ddr_read_bridge bridge(.cclk(clk),.crstn(rstn),.req_valid(req_valid),.req_ready(req_ready),.req_addr(req_addr),.req_beats(req_beats),
  .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_data(rsp_data),.fault(bridge_fault),.dclk(dclk),.drstn(rstn),.enable(1'b1),
  .arvalid(arvalid),.arready(arready),.araddr(araddr),.arlen(arlen),.rvalid(rvalid),.rready(rready),.rdata(rdata),.rlast(rlast),.rresp(2'b00));
 always @(posedge dclk) if(rstn) begin
  dticks<=dticks+1;
  if(awvalid && awready) begin
   if(awaddr[5:0]!=0 || awlen!=3 || awaddr<32'h00300000 || awaddr>=32'h005c0000) $fatal(1,"Bad feature AW");
   write_address<=awaddr>>4;write_len<=awlen;write_beat<=0;write_pending<=1;
  end
  if(wvalid && wready) begin
   if(wlast!=(write_beat==write_len)) $fatal(1,"Bad WLAST");
   memory[write_address+write_beat]<=wdata;
   if(wlast) begin write_pending<=0;response_pending<=1;bdelay<=ddr_delay+(dticks%13);end
   else write_beat<=write_beat+1;
  end
  if(response_pending) begin
   if(bdelay!=0) bdelay<=bdelay-1;else begin bvalid<=1;response_pending<=0;end
  end
  if(bvalid && bready) bvalid<=0;
  if(arvalid && arready) begin
   if(araddr<32'h00300000 ? (arlen!=2 || araddr[3:0]!=0) : (arlen!=3 || araddr[5:0]!=0)) $fatal(1,"Bad feature/RGB AR");
   read_address<=araddr>>4;read_len<=arlen;read_beat<=0;read_pending<=1;read_delay<=ddr_delay+(dticks%17);
  end
  if(read_pending && !rvalid) begin
   if(read_delay!=0) read_delay<=read_delay-1;
   else begin rdata<=memory[read_address+read_beat];rlast<=read_beat==read_len;rvalid<=1;end
  end
  if(rvalid && rready) begin
   rvalid<=0;if(rlast) read_pending<=0;else begin read_beat<=read_beat+1;read_delay<=dticks%3;end
  end
 end
 always @(posedge clk) if(rstn) begin
  ticks<=ticks+1;
  if(fifo_pop) commands=commands+1;
  if(FULL_PREFIX && !decoder_active && layers_completed==0 && (slot_owned!=0 || slot_ready!=0 || pack_state!=0 || decoder_co!=0))
   $fatal(1,"Encoder/residual writeback leaked into the decoder scheduler");
  if(FULL_PREFIX && wb_valid && wb_opcode==5) begin
   index=blocks_completed*384+wb_addr-(blocks_completed[0] ? 384 : 0);
   if(core_result!==gold_res[index]) $fatal(1,"Prefix residual mismatch block=%0d tile=%0d",blocks_completed+1,index%384);
   residual_values=residual_values+100;
  end
  if(req_valid && req_ready) reads=reads+1;
  if(write_valid && write_ready) begin
   region=write_addr[23:20];index=(write_addr&32'hfffff)>>7;half=write_addr[6];
   if(region==3) expected=gold1[index];else if(region==4) expected=gold2[index];else expected=gold3[index];
   expected_half=half ? expected[799:400] : expected[399:0];
   if(write_data!==expected_half) $fatal(1,"Transpose mismatch layer=%0d tile=%0d half=%0d got=%h expected=%h",region-2,index,half,write_data,expected_half);
   halves=halves+1;checks=checks+50;if(core_busy) overlap=overlap+1;
  end
  if(cache_wr) begin
   if(core_cache_rd_en && core_cache_rd_addr==cache_waddr) $fatal(1,"Cache DMA/read collision");
   if(wb_valid && wb_addr==cache_waddr) $fatal(1,"Cache DMA/write collision");
  end
  if(cache_rd && (core_cache_rd_en || wb_valid)) $fatal(1,"Streaming read collided with unit port B");
  if(core_done && error_code!=0) $fatal(1,"Core error=%0d cmd=%h",error_code,core_cmd);
  if(writer_fault || bridge_fault || prefix_fault) $fatal(1,"AXI/core fault");
  if(ticks%100000==0) $display("DECODER_PROGRESS ticks=%0d layer=%0d y=%0d co=%0d loaded=%0d owned=%b pack=%0d halves=%0d",ticks,decoder_layer,decoder_y,decoder_co,decoder_loaded,slot_owned,pack_state,halves);
  if(ticks>8000000) $fatal(1,"Decoder timeout");
 end
 task verify_layer(input integer n);
  integer t,h,b,p,base,count;reg [511:0] actual;reg [799:0] gold;
  begin
   base=(n+2)*65536;count=n==1 ? 768 : n==2 ? 1536 : 6144;
   for(t=0;t<count;t=t+1) begin
    if(n==1) gold=gold1[t];else if(n==2) gold=gold2[t];else gold=gold3[t];
    for(h=0;h<2;h=h+1) begin
     for(b=0;b<4;b=b+1) actual[b*128+:128]=memory[base+t*8+h*4+b];
     if(actual[399:0] !== (h ? gold[799:400] : gold[399:0]) || actual[511:400]!==112'd0) $fatal(1,"DDR layer=%0d tile=%0d half=%0d",n,t,h);
    end
   end
   values=values+count*100;
  end
 endtask
 initial begin
  if(!$value$plusargs("vectors=%s",vectors)) vectors="build/stage3/vectors";
  if($value$plusargs("ddr-delay=%d",ddr_delay)) $display("DDR delay=%0d",ddr_delay);
  if($test$plusargs("continuous")) pause_each_layer=0;
  $readmemh({vectors,"/block9_q44_tiles.mem"},seed);$readmemh({vectors,"/decoder1_tiles.mem"},gold1);
  $readmemh({vectors,"/decoder2_tiles.mem"},gold2);$readmemh({vectors,"/decoder3_tiles.mem"},gold3);
  if(FULL_PREFIX) begin
   $readmemh({vectors,"/frame_rgbx.mem"},memory,0,19199);
   for(block=1;block<=9;block=block+1) $readmemh($sformatf("%s/block%0d_q44_tiles.mem",vectors,block),gold_res,(block-1)*384,block*384-1);
  end
  repeat(6) @(negedge clk);rstn=1;repeat(5) @(negedge clk);
  if(!FULL_PREFIX) for(i=0;i<384;i=i+1) begin seed_addr=i;seed_data=seed[i];seed_wr=1;@(negedge clk);end
  seed_wr=0;start=1;@(negedge clk);start=0;
  if(FULL_PREFIX && pause_each_layer) for(block=1;block<=9;block=block+1) begin
   wait(paused && blocks_completed==block);@(negedge clk);resume=1;@(negedge clk);resume=0;
  end
  if(pause_each_layer) for(layer=1;layer<=3;layer=layer+1) begin
   wait(paused && layers_completed==layer);@(negedge clk);saved_cycles=cycles;
   verify_layer(layer);repeat(20) @(negedge clk);
   if(cycles!=saved_cycles || core_busy || queued!=0 || !write_ready) $fatal(1,"Pause not quiescent");
   $display("TRANSPOSE_LAYER_PASS layer=%0d cycles=%0d cumulative=%0d values=%0d",layer,layer_cycles,cycles,values);
   resume=1;@(negedge clk);resume=0;
  end
  wait(done);@(negedge clk);
  if(!pause_each_layer) for(layer=1;layer<=3;layer=layer+1) verify_layer(layer);
  if(commands!=(FULL_PREFIX ? 152448 : 106752) || halves!=16896 || checks!=844800 || values!=844800 || reads!=(FULL_PREFIX ? 12288 : 4608) || overlap==0 || layers_completed!=3) $fatal(1,"Counts commands=%0d halves=%0d checks=%0d reads=%0d",commands,halves,checks,reads);
  if(FULL_PREFIX && (residual_values!=345600 || input_checksum!==32'h326d32e8)) $fatal(1,"Full prefix residual/CRC mismatch");
  $display("PASS stage3: full_prefix=%0d values=%0d residual_values=%0d commands=%0d cycles=%0d prefix_cycles=%0d command_wait=%0d data_wait=%0d halves=%0d reads=%0d overlap=%0d",FULL_PREFIX,values,residual_values,commands,cycles,prefix_total_cycles,command_wait_cycles,data_wait_cycles,halves,reads,overlap);
  $finish;
 end
endmodule
