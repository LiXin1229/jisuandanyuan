`include "mn_isa.vh"
// Stage 1: RGB DDR -> three encoders -> 32x30x40. One existing compute unit.
// A row is published only after every queued instruction has completed.
// Input DMA writes only raw slots older than the next row's upper halo.
module cyclegan_encoder #(parameter COLUMN_PREFETCH=0, RESIDUAL_ENABLE=0, DECODER_ENABLE=0, OUTPUT_ENABLE=0, RESIDUAL_INSTANCE_NORM=0, FULL_INSTANCE_NORM=0) (
 input wire clk,rstn,start,input wire [31:0] frame_base,
 output wire busy,output reg done,fault,
 output reg [31:0] cycles,output reg [31:0] mac_cycles,first_output_cycle,
 output wire req_valid,input wire req_ready,output wire [31:0] req_addr,
 output wire [2:0] req_beats,input wire rsp_valid,output wire rsp_ready,
 input wire [511:0] rsp_data,
 input wire dbg_rd,input wire [10:0] dbg_addr,output wire [799:0] dbg_data,output wire dbg_valid,
 output reg [31:0] command_wait_cycles,data_wait_cycles,
 output wire [31:0] input_checksum,
 output wire [4:0] raw_rows,stage1_rows,stage2_rows,stage3_rows,
 input wire pause_each_block,resume,
 output wire paused,output wire [3:0] blocks_completed,output wire [10:0] residual_output_base,
 output reg [31:0] encoder_cycles,
 output wire [31:0] residual_cycles,block_cycles,
 output wire [1:0] layers_completed,output wire [31:0] decoder_cycles,layer_cycles,
 output wire output_completed,output wire [31:0] output_cycles,
 output wire feature_write_valid,input wire feature_write_ready,output wire [31:0] feature_write_addr,output wire [399:0] feature_write_data
);
 localparam IDLE=0,SELECT=1,RUN=2,FINISH=3,RESIDUAL=4,DECODER=5,ENCODER_FULL=6;
 reg [2:0] state;
 reg [1:0] stage,phase;
 reg [4:0] loaded,r0,r1,r2,x,y,ch,load_x;
 reg [31:0] base;
 reg producer_done,row_started;
 // Drain needs only FIFO + executor occupancy, bounded by five commands.
 // The separate completion index is used only to timestamp command 34 of
 // the first stage-3 row; its low six bits suffice before that timestamp.
 reg [2:0] outstanding;
 reg [5:0] completed;
 reg [4:0] executed_x,executed_step;
 reg [5:0] released_columns;
 wire [5:0] cin=stage==0 ? 3 : stage==1 ? 8 : 16;
 wire [5:0] cout=stage==0 ? 8 : stage==1 ? 16 : 32;
 wire [5:0] width=stage==0 ? 32 : stage==1 ? 16 : 8;
 wire [4:0] height=stage==0 ? 24 : stage==1 ? 12 : 6;
 wire [10:0] input_base=stage==0 ? 0 : stage==1 ? 288 : 672;
 wire [9:0] row_size=stage==0 ? 96 : 128;
 // These are only factors 3/8/16: fixed wiring avoids address-only DSPs.
 wire [9:0] xc=stage==0 ? ({5'd0,x}<<1)+x : stage==1 ? {2'd0,x,3'd0} : {1'd0,x,4'd0};
 wire [9:0] cc=stage==0 ? ({5'd0,ch}<<1)+ch : stage==1 ? {2'd0,ch,3'd0} : {1'd0,ch,4'd0};
 // Decode the three ring banks once. Explicit widths avoid 32-bit modulo
 // and variable row-pitch multipliers for the neighboring halo addresses.
 wire [1:0] row_bank=y%5'd3,pool_bank=(y>>1)%5'd3;
 wire [1:0] upper_bank=y==0 ? row_bank : row_bank==0 ? 2 : row_bank-2'd1;
 wire [1:0] lower_bank=y==height-1 ? row_bank : row_bank==2 ? 0 : row_bank+2'd1;
 function automatic [8:0] ring_offset(input [1:0] bank,input raw);
  begin ring_offset=raw ? ({7'd0,bank}<<6)+({7'd0,bank}<<5) : {bank,7'd0};end
 endfunction
 wire [10:0] column_address=input_base+xc+ch;
 wire [10:0] center=column_address+ring_offset(row_bank,stage==0);
 wire [10:0] upper=column_address+ring_offset(upper_bank,stage==0);
 wire [10:0] lower=column_address+ring_offset(lower_bank,stage==0);
 wire [10:0] pooled=stage==0 ? 288+{pool_bank,7'd0}+(x>>1)*8+ch :
                        stage==1 ? 672+{pool_bank,7'd0}+(x>>1)*16+ch :
                        1056+ch*12+(y>>1)*4+(x>>1);
 wire [14:0] dw_base=stage==0 ? 0 : stage==1 ? 67 : 315;
 wire [14:0] db_base=stage==1 ? 139 : 459;
 wire [14:0] pw_base=stage==0 ? 27 : stage==1 ? 155 : 491;
 wire [14:0] pb_base=stage==0 ? 51 : stage==1 ? 283 : 1003;
 reg [127:0] instruction;
 reg [10:0] src,dst;
 reg [14:0] param;
 always @* begin
  instruction=0;src=0;dst=0;param=0;
  instruction[61:58]=9;instruction[65:62]=9;instruction[86]=1;
  case(phase)
   0:begin
    instruction[3:0]=`MN_OP_DW;src=center;dst=1440+ch;param=dw_base+ch*9;
    instruction[43:41]=3;instruction[51:50]=stage==0 ? 2 : 1;instruction[53:52]=1;
    instruction[57:54]={y==height-1,y==0,x==width-1,x==0};
    instruction[75:66]=cin;instruction[85:76]=row_size;
    instruction[95]=1;instruction[106:96]=upper;instruction[117:107]=lower;
   end
   1:begin instruction[3:0]=`MN_OP_NORM;src=1440+ch;dst=src;param=db_base+ch*2;instruction[45:44]=1;end
   2:begin instruction[3:0]=`MN_OP_PW;src=1440;dst=1456;param=pw_base+cc;instruction[40:36]=cin-1;end
   3:begin
    instruction[3:0]=`MN_OP_NORM;src=1456;dst=pooled;param=pb_base+ch*2;
    instruction[45:44]=stage==0 ? 1 : 0;instruction[46]=1;
    instruction[49:47]=1+{y[0],x[0]};
   end
  endcase
  instruction[13:4]=src[9:0];instruction[90]=src[10];
  instruction[23:14]=dst[9:0];instruction[91]=dst[10];
  instruction[35:24]=param[11:0];instruction[94:92]=param[14:12];
 end
 wire instruction_ready,core_busy,core_done,memory_ready;
 wire [2:0] queued;wire [3:0] error_code;
 wire instruction_valid=state==RUN && !producer_done;
 wire [127:0] residual_instruction;
 wire residual_valid,residual_done;
 wire residual_paused,decoder_paused;
 assign paused=residual_paused || decoder_paused;
 wire [31:0] residual_command_wait;
 wire stream_ready,cache_read_ready,cache_rvalid;wire [799:0] cache_rdata;
 wire full_done;
 wire encoder_to_residual=RESIDUAL_ENABLE && (FULL_INSTANCE_NORM ? state==ENCODER_FULL && full_done : state==SELECT && r2==6);
 wire norm_override,norm_read,norm_fault;
 wire res_norm_override,res_norm_clear,sample_idle,coefficient_ready;
 wire [4:0] res_norm_point,res_query;wire [14:0] res_norm_base;
 wire [14:0] norm_addr;wire [15:0] norm_data;wire [799:0] wb_data;
 wire wb_valid;wire [10:0] wb_addr;wire [3:0] wb_opcode;
 wire full_valid,full_req_valid,full_rsp_ready,full_wr,full_rd,full_write_valid;
 wire [127:0] full_instruction;wire [31:0] full_req_addr,full_write_addr,full_checksum;
 wire [2:0] full_req_beats;wire [10:0] full_waddr,full_raddr;wire [799:0] full_wdata;
 wire [39:0] full_we;wire [399:0] full_write_data;
 wire enc_pass_start,enc_pass_pool,enc_pass_relu,enc_pass_final;
 wire [4:0] enc_pass_point;wire [5:0] enc_pass_channels,enc_pass_width;wire [9:0] enc_pass_tiles;
 wire dec_pass_start;wire [4:0] dec_pass_point;wire [5:0] dec_pass_channels,dec_pass_width;
 wire [9:0] dec_pass_tiles;wire [31:0] dec_pass_base;
 wire dec_write_valid;wire [31:0] dec_write_addr;wire [399:0] dec_write_data;
 wire pass_busy,pass_done,pass_valid,pass_req_valid,pass_rsp_ready,pass_wr,pass_rd,pass_write_valid,pass_clear,pass_tile_valid;
 wire [127:0] pass_instruction;wire [31:0] pass_req_addr,pass_write_addr;
 wire [2:0] pass_req_beats;wire [10:0] pass_waddr,pass_raddr;wire [799:0] pass_wdata;
 wire [39:0] pass_we;wire [399:0] pass_write_data;wire [4:0] pass_query;wire [16:0] pass_count;
 wire [4:0] pass_point=state==ENCODER_FULL ? enc_pass_point : dec_pass_point;
 wire [9:0] pass_tiles=state==ENCODER_FULL ? enc_pass_tiles : dec_pass_tiles;
 assign feature_write_valid=pass_busy ? pass_write_valid : state==ENCODER_FULL ? full_write_valid : dec_write_valid;
 assign feature_write_addr=pass_busy ? pass_write_addr : state==ENCODER_FULL ? full_write_addr : dec_write_addr;
 assign feature_write_data=pass_busy ? pass_write_data : state==ENCODER_FULL ? full_write_data : dec_write_data;
 generate if(FULL_INSTANCE_NORM) begin:g_full_instance
  cyclegan_encoder_instance_scheduler scheduler(.clk(clk),.rstn(rstn),.start(start && state==IDLE),.frame_base(base),
   .done(full_done),.input_checksum(full_checksum),.instruction(full_instruction),.instruction_valid(full_valid),.instruction_ready(instruction_ready),
   .core_busy(core_busy),.queued(queued),.writeback_valid(wb_valid),.writeback_addr(wb_addr),.writeback_opcode(wb_opcode),
   .req_valid(full_req_valid),.req_ready(req_ready && state==ENCODER_FULL && !pass_busy),.req_addr(full_req_addr),.req_beats(full_req_beats),
   .rsp_valid(rsp_valid && state==ENCODER_FULL && !pass_busy),.rsp_ready(full_rsp_ready),.rsp_data(rsp_data),
   .cache_wr(full_wr),.cache_ready(stream_ready),.cache_waddr(full_waddr),.cache_wdata(full_wdata),.cache_we(full_we),
   .cache_rd(full_rd),.cache_read_ready(cache_read_ready),.cache_raddr(full_raddr),.cache_rvalid(cache_rvalid),.cache_rdata(cache_rdata),
   .write_valid(full_write_valid),.write_ready(feature_write_ready),.write_addr(full_write_addr),.write_data(full_write_data),
   .pass_start(enc_pass_start),.pass_done(pass_done),.pass_point(enc_pass_point),.pass_channels(enc_pass_channels),.pass_width(enc_pass_width),
   .pass_tiles(enc_pass_tiles),.pass_pool(enc_pass_pool),.pass_relu(enc_pass_relu),.pass_final(enc_pass_final));
  cyclegan_instance_pass normalization_pass(.clk(clk),.rstn(rstn),.start(enc_pass_start || dec_pass_start),.point(pass_point),
   .channels(state==ENCODER_FULL ? enc_pass_channels : dec_pass_channels),.tiles(pass_tiles),.width(state==ENCODER_FULL ? enc_pass_width : dec_pass_width),
   .pool(state==ENCODER_FULL && enc_pass_pool),.relu(state==ENCODER_FULL ? enc_pass_relu : 1'b1),.final_cache(state==ENCODER_FULL && enc_pass_final),
   .source_base(state==ENCODER_FULL ? 32'h00200000 : dec_pass_base),.target_base(state==ENCODER_FULL ? 32'h00300000 : dec_pass_base),
   .busy(pass_busy),.done(pass_done),.instruction(pass_instruction),.instruction_valid(pass_valid),.instruction_ready(instruction_ready),
   .core_busy(core_busy),.queued(queued),.norm_clear(pass_clear),.query_channel(pass_query),.sample_count(pass_count),
   .tile_valid(pass_tile_valid),.sample_idle(sample_idle),.coefficient_ready(coefficient_ready),
   .req_valid(pass_req_valid),.req_ready(req_ready && pass_busy),.req_addr(pass_req_addr),.req_beats(pass_req_beats),
   .rsp_valid(rsp_valid && pass_busy),.rsp_ready(pass_rsp_ready),.rsp_data(rsp_data),
   .cache_wr(pass_wr),.cache_ready(stream_ready),.cache_waddr(pass_waddr),.cache_wdata(pass_wdata),.cache_we(pass_we),
   .cache_rd(pass_rd),.cache_read_ready(cache_read_ready),.cache_raddr(pass_raddr),.cache_rvalid(cache_rvalid),.cache_rdata(cache_rdata),
   .write_valid(pass_write_valid),.write_ready(feature_write_ready),.write_addr(pass_write_addr),.write_data(pass_write_data));
 end else begin:g_fixed_encoder
  assign full_done=0;assign full_checksum=0;assign full_valid=0;assign full_instruction=0;
  assign full_req_valid=0;assign full_req_addr=0;assign full_req_beats=0;assign full_rsp_ready=0;
  assign full_wr=0;assign full_waddr=0;assign full_wdata=0;assign full_we=0;assign full_rd=0;assign full_raddr=0;
  assign full_write_valid=0;assign full_write_addr=0;assign full_write_data=0;
  assign enc_pass_start=0;assign enc_pass_point=0;assign enc_pass_channels=0;assign enc_pass_width=0;assign enc_pass_tiles=0;
  assign enc_pass_pool=0;assign enc_pass_relu=0;assign enc_pass_final=0;
  assign pass_busy=0;assign pass_done=0;assign pass_valid=0;assign pass_instruction=0;
  assign pass_req_valid=0;assign pass_req_addr=0;assign pass_req_beats=0;assign pass_rsp_ready=0;
  assign pass_wr=0;assign pass_waddr=0;assign pass_wdata=0;assign pass_we=0;assign pass_rd=0;assign pass_raddr=0;
  assign pass_write_valid=0;assign pass_write_addr=0;assign pass_write_data=0;
  assign pass_clear=0;assign pass_tile_valid=0;assign pass_query=0;assign pass_count=1200;
 end endgenerate
 assign norm_override=pass_busy || res_norm_override;
 generate if(RESIDUAL_INSTANCE_NORM || FULL_INSTANCE_NORM) begin:g_normalization
  wire [14:0] norm_offset=norm_addr-(state==RESIDUAL ? res_norm_base : 15'd0);
  mn_instance_norm normalization(.clk(clk),.rstn(rstn),.clear(state==RESIDUAL ? res_norm_clear : pass_clear),
   .point(state==RESIDUAL ? res_norm_point+5'd5 : pass_point),.tiles_per_channel(state==RESIDUAL ? 10'd12 : pass_tiles),
   .sample_count(state==RESIDUAL ? 17'd1200 : pass_count),
   .tile_valid(state==RESIDUAL ? wb_valid && (wb_opcode==`MN_OP_DW || wb_opcode==`MN_OP_PW) : pass_tile_valid),
   .tile_data(state==RESIDUAL ? wb_data : cache_rdata),.sample_idle(sample_idle),.fault(norm_fault),
   .query_channel(state==RESIDUAL ? res_query : pass_query),.coefficient_ready(coefficient_ready),
   .rd_en(norm_read),.rd_addr(norm_offset[5:0]),.rd_data(norm_data));
 end else begin:g_no_normalization
  assign sample_idle=1;assign coefficient_ready=1;assign norm_fault=0;assign norm_data=0;
 end endgenerate
 generate if(RESIDUAL_ENABLE && (RESIDUAL_INSTANCE_NORM || FULL_INSTANCE_NORM)) begin:g_instance_residual
  cyclegan_residual_instance_scheduler scheduler(.clk(clk),.rstn(rstn),.frame_start(start && state==IDLE),
   .start(encoder_to_residual),.pause_each_block(pause_each_block),.resume(resume),
   .instruction(residual_instruction),.instruction_valid(residual_valid),.instruction_ready(instruction_ready),
   .core_done(core_done),.core_busy(core_busy),.memory_ready(memory_ready),.queued(queued),
   .sample_idle(sample_idle),.coefficient_ready(coefficient_ready),.norm_clear(res_norm_clear),.norm_point(res_norm_point),
   .query_channel(res_query),.norm_override(res_norm_override),.norm_base(res_norm_base),
   .done(residual_done),.paused(residual_paused),.blocks_completed(blocks_completed),.output_base(residual_output_base),
   .cycles(residual_cycles),.block_cycles(block_cycles),.command_wait_cycles(residual_command_wait));

 end else if(RESIDUAL_ENABLE) begin:g_residual
  assign res_norm_override=0;assign res_norm_clear=0;assign res_norm_point=0;assign res_query=0;assign res_norm_base=0;
  cyclegan_residual_scheduler scheduler(.clk(clk),.rstn(rstn),.frame_start(start && state==IDLE),
   .start(encoder_to_residual),.pause_each_block(pause_each_block),.resume(resume),
   .instruction(residual_instruction),.instruction_valid(residual_valid),.instruction_ready(instruction_ready),
   .core_done(core_done),.core_busy(core_busy),.memory_ready(memory_ready),.queued(queued),
   .done(residual_done),.paused(residual_paused),.blocks_completed(blocks_completed),.output_base(residual_output_base),
   .cycles(residual_cycles),.block_cycles(block_cycles),.command_wait_cycles(residual_command_wait));
 end else begin:g_no_residual
  assign res_norm_override=0;assign res_norm_clear=0;assign res_norm_point=0;assign res_query=0;assign res_norm_base=0;
  assign residual_instruction=0;assign residual_valid=0;assign residual_done=0;
  assign residual_paused=0;assign blocks_completed=0;assign residual_output_base=1056;
  assign residual_cycles=0;assign block_cycles=0;assign residual_command_wait=0;
 end endgenerate
 wire load_busy,load_done,load_wr,load_ready;
 wire [10:0] load_addr;wire [799:0] load_data;wire [39:0] load_mask;
 wire rgb_req_valid,rgb_rsp_ready;wire [31:0] rgb_req_addr;wire [2:0] rgb_req_beats;
 wire [127:0] decoder_instruction;wire decoder_valid,decoder_done;
 wire [31:0] decoder_command_wait,decoder_data_wait;
 wire decoder_req_valid,decoder_rsp_ready;wire [31:0] decoder_req_addr;wire [2:0] decoder_req_beats;
 wire decoder_wr,decoder_rd;wire [10:0] decoder_waddr,decoder_raddr;wire [799:0] decoder_wdata;wire [39:0] decoder_we;

 assign dbg_data=cache_rdata;assign dbg_valid=cache_rvalid;
 assign load_ready=stream_ready;
 assign req_valid=pass_busy ? pass_req_valid : state==ENCODER_FULL ? full_req_valid : state==DECODER ? decoder_req_valid : rgb_req_valid;
 assign req_addr=pass_busy ? pass_req_addr : state==ENCODER_FULL ? full_req_addr : state==DECODER ? decoder_req_addr : rgb_req_addr;
 assign req_beats=pass_busy ? pass_req_beats : state==ENCODER_FULL ? full_req_beats : state==DECODER ? decoder_req_beats : rgb_req_beats;
 assign rsp_ready=pass_busy ? pass_rsp_ready : state==ENCODER_FULL ? full_rsp_ready : state==DECODER ? decoder_rsp_ready : rgb_rsp_ready;
 generate if(DECODER_ENABLE) begin:g_decoder
  cyclegan_decoder_scheduler #(.OUTPUT_ENABLE(OUTPUT_ENABLE),.INSTANCE_NORM(FULL_INSTANCE_NORM==2)) scheduler(.clk(clk),.rstn(rstn),.frame_start(start && state==IDLE),
   .pass_start(dec_pass_start),.pass_done(pass_done),.pass_point(dec_pass_point),.pass_tiles(dec_pass_tiles),.pass_channels(dec_pass_channels),.pass_width(dec_pass_width),.pass_base(dec_pass_base),
   .start(state==RESIDUAL && residual_done),.pause_each_layer(pause_each_block),.resume(resume),
   .instruction(decoder_instruction),.instruction_valid(decoder_valid),.instruction_ready(instruction_ready),
   .core_busy(core_busy),.memory_ready(memory_ready),.queued(queued),
   .writeback_valid(wb_valid),.writeback_addr(wb_addr),.writeback_opcode(wb_opcode),
   .done(decoder_done),.paused(decoder_paused),.layers_completed(layers_completed),
   .output_completed(output_completed),.output_cycles(output_cycles),
   .cycles(decoder_cycles),.layer_cycles(layer_cycles),.command_wait_cycles(decoder_command_wait),.data_wait_cycles(decoder_data_wait),
   .req_valid(decoder_req_valid),.req_ready(req_ready && state==DECODER && !pass_busy),.req_addr(decoder_req_addr),.req_beats(decoder_req_beats),
   .rsp_valid(rsp_valid && state==DECODER && !pass_busy),.rsp_ready(decoder_rsp_ready),.rsp_data(rsp_data),
   .cache_wr(decoder_wr),.cache_ready(stream_ready),.cache_waddr(decoder_waddr),.cache_wdata(decoder_wdata),.cache_we(decoder_we),
   .cache_rd(decoder_rd),.cache_read_ready(cache_read_ready),.cache_raddr(decoder_raddr),.cache_rvalid(cache_rvalid),.cache_rdata(cache_rdata),
   .write_valid(dec_write_valid),.write_ready(feature_write_ready),.write_addr(dec_write_addr),.write_data(dec_write_data));
 end else begin:g_no_decoder
  assign decoder_instruction=0;assign decoder_valid=0;assign decoder_done=0;assign decoder_paused=0;
  assign layers_completed=0;assign decoder_cycles=0;assign layer_cycles=0;assign decoder_command_wait=0;assign decoder_data_wait=0;
  assign output_completed=0;assign output_cycles=0;
  assign decoder_req_valid=0;assign decoder_req_addr=0;assign decoder_req_beats=0;assign decoder_rsp_ready=0;
  assign decoder_wr=0;assign decoder_rd=0;assign decoder_waddr=0;assign decoder_raddr=0;assign decoder_wdata=0;assign decoder_we=0;
  assign dec_write_valid=0;assign dec_write_addr=0;assign dec_write_data=0;
  assign dec_pass_start=0;assign dec_pass_point=0;assign dec_pass_tiles=0;assign dec_pass_channels=0;assign dec_pass_width=0;assign dec_pass_base=0;
 end endgenerate
 reg [31:0] input_crc;
 function automatic [31:0] crc_row(input [31:0] seed,input [79:0] data);
  reg [31:0] c;integer i;
  begin c=seed;for(i=0;i<80;i=i+1) c=(c>>1)^((c[0]^data[i]) ? 32'hedb88320 : 0);crc_row=c;end
 endfunction
 assign input_checksum=FULL_INSTANCE_NORM ? full_checksum : ~input_crc;
 // For raw row y, row y-1's column c has its last reader in tile c+1.
 // Release columns only after that tile's last DW channel has completed.
 // Row 0 has no upper halo, so its third slot can be filled immediately.
 wire column_slot_free=COLUMN_PREFETCH && state==RUN && stage==0 && loaded==r0+2 && load_x<released_columns;
 wire load_start=!FULL_INSTANCE_NORM && busy && state!=FINISH && state!=RESIDUAL && state!=DECODER && !load_busy && !load_done && loaded<24 &&
                 (loaded<=r0+1 || column_slot_free);
 cyclegan_rgb_loader loader(.clk(clk),.rstn(rstn),.start(load_start),.frame_base(base),
  .tile_x(load_x),.tile_y(loaded),.busy(load_busy),.done(load_done),
  .req_valid(rgb_req_valid),.req_ready(req_ready && state!=DECODER),.req_addr(rgb_req_addr),.req_beats(rgb_req_beats),
  .rsp_valid(rsp_valid && state!=DECODER),.rsp_ready(rgb_rsp_ready),.rsp_data(rsp_data),
  .cache_wr(load_wr),.cache_ready(load_ready),.cache_addr(load_addr),.cache_data(load_data),.cache_we(load_mask));
 mobilenet_unit #(.MODEL_PARAMS(1),.ENCODER_ONLY(!RESIDUAL_ENABLE),.RESIDUAL_PREFIX(RESIDUAL_ENABLE && !OUTPUT_ENABLE),.DECODER_PREFIX(DECODER_ENABLE && !OUTPUT_ENABLE),.GENERATOR_ROM(OUTPUT_ENABLE),.STREAM_WRITES(1),.STREAM_READS(DECODER_ENABLE),.LIVE_NORM(RESIDUAL_INSTANCE_NORM || FULL_INSTANCE_NORM)) unit(
  .clk(clk),.reset(!rstn),.instruction(pass_busy ? pass_instruction : state==ENCODER_FULL ? full_instruction : state==DECODER ? decoder_instruction : state==RESIDUAL ? residual_instruction : instruction),
  .instruction_valid(pass_busy ? pass_valid : state==ENCODER_FULL ? full_valid : state==DECODER ? decoder_valid : state==RESIDUAL ? residual_valid : instruction_valid),
  .instruction_ready(instruction_ready),.instruction_count(queued),
  .host_cache_wr(pass_busy ? pass_wr : state==ENCODER_FULL ? full_wr : state==DECODER ? decoder_wr : load_wr),.host_cache_waddr(pass_busy ? pass_waddr : state==ENCODER_FULL ? full_waddr : state==DECODER ? decoder_waddr : load_addr),
  .host_cache_wdata(pass_busy ? pass_wdata : state==ENCODER_FULL ? full_wdata : state==DECODER ? decoder_wdata : load_data),.host_cache_wmask(pass_busy ? pass_we : state==ENCODER_FULL ? full_we : state==DECODER ? decoder_we : load_mask),
  .host_cache_rd(pass_busy ? pass_rd : state==ENCODER_FULL ? full_rd : state==DECODER && !paused ? decoder_rd : dbg_rd && (state==IDLE || paused)),
  .host_cache_raddr(pass_busy ? pass_raddr : state==ENCODER_FULL ? full_raddr : state==DECODER && !paused ? decoder_raddr : dbg_addr),
  .host_cache_rdata(cache_rdata),.host_cache_rvalid(cache_rvalid),.host_memory_ready(memory_ready),.host_stream_ready(stream_ready),.host_read_ready(cache_read_ready),
  .host_param_wr(1'b0),.host_param_addr(15'd0),.host_param_data(16'd0),
  .busy(core_busy),.done(core_done),.error_code(error_code),.writeback_valid(wb_valid),.writeback_addr(wb_addr),.writeback_opcode(wb_opcode),
  .norm_override(norm_override),.norm_data(norm_data),.norm_read(norm_read),.norm_addr(norm_addr),.writeback_data(wb_data));
 assign busy=state!=IDLE;
 assign raw_rows=loaded;assign stage1_rows=r0;assign stage2_rows=r1;assign stage3_rows=r2;
 always @(posedge clk) begin
  done<=0;
  if(!rstn) begin
   state<=IDLE;stage<=0;phase<=0;loaded<=0;r0<=0;r1<=0;r2<=0;x<=0;y<=0;ch<=0;load_x<=0;base<=0;
   producer_done<=0;row_started<=0;outstanding<=0;completed<=0;fault<=0;
   executed_x<=0;executed_step<=0;released_columns<=0;
   cycles<=0;mac_cycles<=0;first_output_cycle<=0;command_wait_cycles<=0;data_wait_cycles<=0;encoder_cycles<=0;
   input_crc<=32'hffffffff;
  end else begin
   if(load_wr) input_crc<=crc_row(input_crc,{load_data[239:200],load_data[39:0]});
   if(busy && !paused) cycles<=cycles+1;
   if(core_busy) mac_cycles<=mac_cycles+1;
   if(core_done && error_code!=0) fault<=1;
   if(norm_fault) fault<=1;
   if(load_done) begin
    if(load_x==31) begin load_x<=0;loaded<=loaded+1;end else load_x<=load_x+1;
   end
   case(state)
    IDLE:if(start) begin
     state<=FULL_INSTANCE_NORM ? ENCODER_FULL : SELECT;base<=frame_base;loaded<=0;r0<=0;r1<=0;r2<=0;load_x<=0;
     fault<=0;cycles<=0;mac_cycles<=0;first_output_cycle<=0;command_wait_cycles<=0;data_wait_cycles<=0;encoder_cycles<=0;
     input_crc<=32'hffffffff;
    end
    SELECT:begin
     x<=0;ch<=0;phase<=0;producer_done<=0;row_started<=0;outstanding<=0;completed<=0;
     executed_x<=0;executed_step<=0;
     released_columns<=r0==0 ? 32 : 0;
     if(r2==6) begin encoder_cycles<=cycles;state<=RESIDUAL_ENABLE ? RESIDUAL : FINISH;end
     else if((r1>>1)>(r2==5 ? 5 : r2+1)) begin stage<=2;y<=r2;state<=RUN;end
     else if(r1<12 && (r0>>1)>(r1==11 ? 11 : r1+1) && (r1>>1)<=r2+1)
      begin stage<=1;y<=r1;state<=RUN;end
     else if(r0<24 && loaded>(r0==23 ? 23 : r0+1) && (r0>>1)<=r1+1)
      begin stage<=0;y<=r0;state<=RUN;end
     else data_wait_cycles<=data_wait_cycles+1;
    end
    RUN:begin
     case ({instruction_valid && instruction_ready,core_done})
      2'b10:outstanding<=outstanding+1'b1;
      2'b01:outstanding<=outstanding-1'b1;
      default:;
     endcase
     if(memory_ready && queued!=0) row_started<=1;
     if(row_started && !producer_done && memory_ready && queued==0) command_wait_cycles<=command_wait_cycles+1;
     if(core_done) begin
      completed<=completed+1;
      if(stage==0) begin
       if(executed_step==2) released_columns<=executed_x==31 ? 32 : {1'b0,executed_x};
       if(executed_step==18) begin executed_step<=0;executed_x<=executed_x+1;end
       else executed_step<=executed_step+1;
      end
      if(stage==2 && first_output_cycle==0 && completed==33) first_output_cycle<=cycles;
     end
     if(instruction_valid && instruction_ready) begin
      case(phase)
       0:if(stage!=0) phase<=1;else if(ch==cin-1) begin ch<=0;phase<=2;end else ch<=ch+1;
       1:if(ch==cin-1) begin ch<=0;phase<=2;end else begin ch<=ch+1;phase<=0;end
       2:phase<=3;
       3:begin
        if(ch!=cout-1) begin ch<=ch+1;phase<=2;end
        else begin
         ch<=0;phase<=0;
         if(x==width-1) producer_done<=1;else x<=x+1;
        end
       end
      endcase
     end
     if(producer_done && outstanding==0 && !core_busy && queued==0) begin
      if(stage==0) r0<=r0+1;else if(stage==1) r1<=r1+1;else r2<=r2+1;
      state<=SELECT;
     end
    end
    ENCODER_FULL:if(full_done) begin encoder_cycles<=cycles;state<=RESIDUAL_ENABLE ? RESIDUAL : FINISH;end
    RESIDUAL:if(residual_done) begin command_wait_cycles<=command_wait_cycles+residual_command_wait;state<=DECODER_ENABLE ? DECODER : FINISH;end
    DECODER:if(decoder_done) begin command_wait_cycles<=command_wait_cycles+decoder_command_wait;data_wait_cycles<=data_wait_cycles+decoder_data_wait;state<=FINISH;end
    FINISH:begin done<=1;state<=IDLE;end
   endcase
  end
 end
endmodule
