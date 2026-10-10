`include "mn_isa.vh"
// Same-frame instance normalization, without feature DDR or prefix replay.
// A=input/skip at1056, B=DW at0, C=PW at384. Final block publishes at0.
module cyclegan_residual_instance_scheduler(
 input wire clk,rstn,frame_start,start,pause_each_block,resume,
 output reg [127:0] instruction,output wire instruction_valid,input wire instruction_ready,
 input wire core_done,core_busy,memory_ready,input wire [2:0] queued,
 input wire sample_idle,coefficient_ready,
 output reg norm_clear,output wire [4:0] norm_point,query_channel,
 output wire norm_override,output wire [14:0] norm_base,
 output reg done,output wire paused,output reg [3:0] blocks_completed,
 output reg [10:0] output_base,output wire [31:0] cycles,block_cycles,command_wait_cycles
);
 localparam IDLE=0,RUN=1,DRAIN=2,PAUSE=3,FINISH=4,PREPARE=5;
 reg [2:0] state,phase;
 reg [4:0] ch;
 reg [1:0] x,y;
 wire [10:0] input_base=1056;
 wire [10:0] dest_base=blocks_completed==8 ? 0 : 1056;
 reg [14:0] parameter_base;
 reg [2:0] outstanding;
 reg [19:0] cycle_count,wait_count;
 reg [16:0] active_block_cycles,last_block_cycles;
 assign cycles={12'd0,cycle_count};assign block_cycles={15'd0,last_block_cycles};
 assign command_wait_cycles={12'd0,wait_count};
 assign paused=state==PAUSE;
 assign query_channel=ch;
 assign norm_point={blocks_completed,1'b0}+(phase>=2);
 assign norm_override=(phase==1 || phase==3 || phase==4) && state!=IDLE;
 assign norm_base=parameter_base+(phase==1 ? 15'd288 : 15'd1376);
 // Only a channel whose complete current-frame statistics produced a,b can run.
 assign instruction_valid=state==RUN && (!(phase==1 || phase==3) || coefficient_ready);
 wire [10:0] channel_offset=({6'd0,ch}<<3)+({6'd0,ch}<<2);
 wire [10:0] spatial_offset={7'd0,y,x};
 wire [10:0] skip=input_base+channel_offset+spatial_offset;
 wire [10:0] dw_tile={2'd0,y,x,5'd0}+ch;
 wire [10:0] pw_tile=384+channel_offset+spatial_offset;
 reg [10:0] src,dst;reg [14:0] param;
 always @* begin
  instruction=0;src=0;dst=0;param=0;
  instruction[61:58]=9;instruction[65:62]=9;instruction[86]=1;
  case(phase)
   0:begin
    instruction[3:0]=`MN_OP_DW;src=skip;dst=dw_tile;
    param=parameter_base+({10'd0,ch}<<3)+ch;
    instruction[43:41]=3;instruction[51:50]=1;instruction[53:52]=1;
    instruction[57:54]={y==2,y==0,x==3,x==0};instruction[75:66]=1;instruction[85:76]=4;
   end
   1:begin
    instruction[3:0]=`MN_OP_NORM;src=dw_tile;dst=src;
    param=parameter_base+288+{9'd0,ch,1'b0};instruction[45:44]=1;
   end
   2:begin
    instruction[3:0]=`MN_OP_PW;src={2'd0,y,x,5'd0};dst=pw_tile;
    param=parameter_base+352+{5'd0,ch,5'd0};instruction[40:36]=31;
   end
   3:begin
    instruction[3:0]=`MN_OP_NORM;src=pw_tile;dst=src;param=parameter_base+1376+{9'd0,ch,1'b0};
   end
   4:begin
    instruction[3:0]=`MN_OP_ADD;src=pw_tile;dst=dest_base+channel_offset+spatial_offset;
    param={4'd0,skip};instruction[86]=0;
   end
  endcase
  instruction[13:4]=src[9:0];instruction[90]=src[10];instruction[23:14]=dst[9:0];instruction[91]=dst[10];
  instruction[35:24]=param[11:0];instruction[94:92]=param[14:12];
 end
 always @(posedge clk) begin
  done<=0;norm_clear<=0;
  if(!rstn || frame_start) begin
   state<=IDLE;phase<=0;ch<=0;x<=0;y<=0;parameter_base<=1067;outstanding<=0;
   blocks_completed<=0;output_base<=1056;cycle_count<=0;wait_count<=0;
   active_block_cycles<=0;last_block_cycles<=0;norm_clear<=1;
  end else begin
   if(state==RUN || state==DRAIN || state==PREPARE) begin
    cycle_count<=cycle_count+1'b1;active_block_cycles<=active_block_cycles+1'b1;
    case({instruction_valid && instruction_ready,core_done})
     2'b10:outstanding<=outstanding+1'b1;
     2'b01:outstanding<=outstanding-1'b1;
     default:;
    endcase
    // Exclude required statistics/phase barriers from instruction starvation.
    if(state==RUN && instruction_valid && memory_ready && queued==0 && outstanding!=0)
     wait_count<=wait_count+1'b1;
   end
   case(state)
    IDLE:if(start) begin norm_clear<=1;state<=PREPARE;end
    PREPARE:state<=RUN;
    RUN:if(instruction_valid && instruction_ready) begin
     if(phase==3) phase<=4;
     else begin
      if(phase==4) phase<=3;
      if(x!=3) x<=x+1'b1;
      else begin
       x<=0;
       if(y!=2) y<=y+1'b1;
       else begin y<=0;if(ch!=31) ch<=ch+1'b1;else begin ch<=0;state<=DRAIN;end end
      end
     end
    end
    DRAIN:if(outstanding==0 && !core_busy && queued==0 && sample_idle) begin
     if(phase==4 || phase==3) begin
      blocks_completed<=blocks_completed+1'b1;output_base<=dest_base;
      last_block_cycles<=active_block_cycles+1'b1;state<=pause_each_block ? PAUSE : FINISH;
     end else begin
      phase<=phase+1'b1;
      if(phase==1) begin norm_clear<=1;state<=PREPARE;end else state<=RUN;
     end
    end
    PAUSE:if(resume) state<=FINISH;
    FINISH:if(blocks_completed==9) begin done<=1;state<=IDLE;end
     else begin
      parameter_base<=parameter_base+1440;phase<=0;ch<=0;x<=0;y<=0;outstanding<=0;
      active_block_cycles<=0;norm_clear<=1;state<=PREPARE;
     end
    default:;
   endcase
  end
 end
endmodule
