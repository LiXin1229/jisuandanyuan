`include "mn_isa.vh"
// One shared DDR normalization pass. A channel fits in the existing cache
// even at 320x240 (768 tiles). Statistics overlap DMA, without a tile copy.
module cyclegan_instance_pass(
 input wire clk,rstn,start,input wire [4:0] point,input wire [5:0] channels,
 input wire [9:0] tiles,input wire [5:0] width,input wire pool,relu,final_cache,
 input wire [31:0] source_base,target_base,
 output wire busy,output reg done,
 output reg [127:0] instruction,output wire instruction_valid,input wire instruction_ready,
 input wire core_busy,input wire [2:0] queued,
 output reg norm_clear,output wire [4:0] query_channel,
 output wire [16:0] sample_count,output wire tile_valid,input wire sample_idle,coefficient_ready,
 output wire req_valid,input wire req_ready,output wire [31:0] req_addr,output wire [2:0] req_beats,
 input wire rsp_valid,output wire rsp_ready,input wire [511:0] rsp_data,
 output wire cache_wr,input wire cache_ready,output wire [10:0] cache_waddr,
 output wire [799:0] cache_wdata,output wire [39:0] cache_we,
 output wire cache_rd,input wire cache_read_ready,output wire [10:0] cache_raddr,
 input wire cache_rvalid,input wire [799:0] cache_rdata,
 output wire write_valid,input wire write_ready,output wire [31:0] write_addr,output wire [399:0] write_data
);
 localparam IDLE=0,LOAD=1,COEFF=2,ISSUE=3,DRAIN=4,READ=5,SEND=6,ACK=7,NEXT=8;
 reg [3:0] state;
 reg [4:0] channel;
 reg [9:0] loaded,scanned,issued,stored;
 reg [12:0] input_offset,output_offset;
 reg [1:0] dma;
 reg load_half,send_half,read_pending;
 reg [4:0] x,y;
 wire [9:0] output_tiles=pool ? tiles>>2 : tiles;
 wire [9:0] pooled_index=width==32 ? {y[4:1],x[4:1]} : width==16 ? {1'b0,y[4:1],x[3:1]} : {2'b0,y[4:1],x[2:1]};
 wire [10:0] destination=pool ? (final_cache ? 11'd1056+output_offset : 11'd768)+pooled_index : {1'b0,issued};
 assign busy=state!=IDLE;
 assign query_channel=channel;
 assign sample_count=({7'd0,tiles}<<6)+({7'd0,tiles}<<5)+({7'd0,tiles}<<2);
 assign instruction_valid=state==ISSUE;
 always @* begin
  instruction=0;instruction[3:0]=`MN_OP_NORM;
  instruction[13:4]=issued;instruction[23:14]=destination[9:0];instruction[91]=destination[10];
  instruction[35:24]={6'd0,channel,1'b0};instruction[45:44]=relu ? 1 : 0;
  instruction[46]=pool;instruction[49:47]=pool ? 1+{y[0],x[0]} : 0;
  instruction[61:58]=9;instruction[65:62]=9;instruction[86]=1;
 end
 assign req_valid=state==LOAD && dma==1;
 assign req_addr=source_base+({19'd0,input_offset}+loaded)*128+(load_half ? 64 : 0);
 assign req_beats=4;
 assign rsp_ready=state==LOAD && dma==2 && cache_ready;
 assign cache_wr=rsp_valid && rsp_ready;
 assign cache_waddr={1'b0,loaded};
 assign cache_wdata={2{rsp_data[399:0]}};
 assign cache_we=load_half ? 40'hfffff00000 : 40'h00000fffff;
 wire stats_read=state==LOAD && scanned<loaded && sample_idle && !read_pending;
 assign cache_rd=cache_read_ready && (stats_read || (state==READ && write_ready));
 assign cache_raddr=state==LOAD ? {1'b0,scanned} : (pool ? 11'd768 : 11'd0)+stored;
 assign tile_valid=state==LOAD && cache_rvalid;
 assign write_valid=state==SEND && cache_rvalid;
 assign write_addr=target_base+({19'd0,output_offset}+stored)*128+(send_half ? 64 : 0);
 assign write_data=send_half ? cache_rdata[799:400] : cache_rdata[399:0];
 always @(posedge clk) begin
  done<=0;norm_clear<=0;
  if(!rstn) begin
   state<=IDLE;channel<=0;loaded<=0;scanned<=0;issued<=0;stored<=0;input_offset<=0;output_offset<=0;
   dma<=0;load_half<=0;send_half<=0;read_pending<=0;x<=0;y<=0;
  end else begin
   if(state==LOAD) begin
    if(dma==0 && loaded<tiles) dma<=1;
    if(req_valid && req_ready) dma<=2;
    if(cache_wr) begin
     dma<=0;load_half<=!load_half;if(load_half) loaded<=loaded+1'b1;
    end
    if(cache_rd) begin scanned<=scanned+1'b1;read_pending<=1;end
    if(cache_rvalid) read_pending<=0;
   end
   case(state)
    IDLE:if(start) begin
     state<=LOAD;channel<=0;loaded<=0;scanned<=0;issued<=0;stored<=0;input_offset<=0;output_offset<=0;
     dma<=0;load_half<=0;send_half<=0;read_pending<=0;x<=0;y<=0;norm_clear<=1;
    end
    LOAD:if(loaded==tiles && scanned==tiles && !read_pending && sample_idle) state<=COEFF;
    COEFF:if(coefficient_ready) state<=ISSUE;
    ISSUE:if(instruction_valid && instruction_ready) begin
     issued<=issued+1'b1;
     if(x==width-1) begin x<=0;y<=y+1'b1;end else x<=x+1'b1;
     if(issued==tiles-1'b1) state<=DRAIN;
    end
    DRAIN:if(!core_busy && queued==0) begin stored<=0;send_half<=0;state<=final_cache ? NEXT : READ;end
    READ:if(cache_rd) state<=SEND;
    SEND:if(write_valid && write_ready) state<=ACK;
    ACK:if(write_ready) begin
     send_half<=!send_half;
     if(!send_half) state<=READ;
     else if(stored==output_tiles-1'b1) state<=NEXT;
     else begin stored<=stored+1'b1;state<=READ;end
    end
    NEXT:if(channel==channels-1'b1) begin state<=IDLE;done<=1;end
     else begin
      channel<=channel+1'b1;input_offset<=input_offset+tiles;output_offset<=output_offset+output_tiles;
      loaded<=0;scanned<=0;issued<=0;stored<=0;dma<=0;load_half<=0;send_half<=0;read_pending<=0;x<=0;y<=0;state<=LOAD;
     end
   endcase
  end
 end
endmodule
