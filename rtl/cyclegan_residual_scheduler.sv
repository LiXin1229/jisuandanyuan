`include "mn_isa.vh"
// Nine resident 32x30x40 residual blocks, issuing into the shared unit FIFO.
// Input/skip ownership lasts until every ADD has completed. No external DMA.
module cyclegan_residual_scheduler(
 input wire clk,rstn,frame_start,start,pause_each_block,resume,
 output reg [127:0] instruction,output wire instruction_valid,input wire instruction_ready,
 input wire core_done,core_busy,memory_ready,input wire [2:0] queued,
 output reg done,output wire paused,output reg [3:0] blocks_completed,
 output reg [10:0] output_base,output wire [31:0] cycles,block_cycles,command_wait_cycles
);
 localparam IDLE=0,RUN=1,DRAIN=2,PAUSE=3,FINISH=4;
 reg [2:0] state,phase;
 reg [4:0] ch;
 reg [1:0] x,y;
 reg [10:0] input_base,dest_base;
 reg [14:0] parameter_base;
 // At most four queued commands and one executing command. Keep their
 // difference instead of two cumulative 12-bit counters; simultaneous
 // acceptance/completion leaves the count unchanged.
 reg [2:0] outstanding;
 reg started;
 // The fixed 1920-command block has no external stalls or DMA: 49155
 // clocks/block, 442395 for nine blocks. Keep counters wide enough for
 // these bounds; zero extension preserves the public 32-bit interface.
 reg [18:0] cycle_count,wait_count;
 reg [15:0] active_block_cycles,last_block_cycles;
 assign cycles={13'd0,cycle_count};
 assign command_wait_cycles={13'd0,wait_count};
 assign block_cycles={16'd0,last_block_cycles};
 wire [10:0] channel_offset=({6'd0,ch}<<3)+({6'd0,ch}<<2);
 wire [10:0] spatial_offset={7'd0,y,x};
 wire [10:0] skip=input_base+channel_offset+spatial_offset;
 reg [10:0] src,dst;
 reg [14:0] param;
 assign instruction_valid=state==RUN;
 assign paused=state==PAUSE;
 always @* begin
  instruction=0;src=0;dst=0;param=0;
  instruction[61:58]=9;instruction[65:62]=9;instruction[86]=1;
  case(phase)
   0:begin
    instruction[3:0]=`MN_OP_DW;src=skip;dst=1440+ch;
    param=parameter_base+({10'd0,ch}<<3)+ch;
    instruction[43:41]=3;instruction[51:50]=1;instruction[53:52]=1;
    instruction[57:54]={y==2,y==0,x==3,x==0};
    instruction[75:66]=1;instruction[85:76]=4;
   end
   1:begin
    instruction[3:0]=`MN_OP_NORM;src=1440+ch;dst=src;
    param=parameter_base+288+{9'd0,ch,1'b0};instruction[45:44]=1;
   end
   2:begin
    instruction[3:0]=`MN_OP_PW;src=1440;dst=1472;
    param=parameter_base+352+{5'd0,ch,5'd0};instruction[40:36]=31;
   end
   3:begin
    instruction[3:0]=`MN_OP_NORM;src=1472;dst=src;
    param=parameter_base+1376+{9'd0,ch,1'b0};
   end
   4:begin
    instruction[3:0]=`MN_OP_ADD;src=1472;
    dst=dest_base+channel_offset+spatial_offset;param={4'd0,skip};instruction[86]=0;
   end
  endcase
  instruction[13:4]=src[9:0];instruction[90]=src[10];
  instruction[23:14]=dst[9:0];instruction[91]=dst[10];
  instruction[35:24]=param[11:0];instruction[94:92]=param[14:12];
 end
 always @(posedge clk) begin
  done<=0;
  if(!rstn || frame_start) begin
   state<=IDLE;phase<=0;ch<=0;x<=0;y<=0;input_base<=1056;dest_base<=0;parameter_base<=1067;
   outstanding<=0;started<=0;blocks_completed<=0;output_base<=1056;
   cycle_count<=0;last_block_cycles<=0;active_block_cycles<=0;wait_count<=0;
  end else begin
   if(state==RUN || state==DRAIN) begin
    cycle_count<=cycle_count+1'b1;active_block_cycles<=active_block_cycles+1'b1;
    case ({instruction_valid && instruction_ready,core_done})
     2'b10:outstanding<=outstanding+1'b1;
     2'b01:outstanding<=outstanding-1'b1;
     default:;
    endcase
   end
   case(state)
    IDLE:if(start) state<=RUN;
    RUN:begin
     if(memory_ready && queued!=0) started<=1;
     if(started && memory_ready && queued==0) wait_count<=wait_count+1'b1;
     if(instruction_ready) begin
      case(phase)
       0:phase<=1;
       1:if(ch==31) begin ch<=0;phase<=2;end else begin ch<=ch+1;phase<=0;end
       2:phase<=3;
       3:phase<=4;
       4:if(ch!=31) begin ch<=ch+1;phase<=2;end
         else begin
          ch<=0;phase<=0;
          if(x!=3) x<=x+1;
          else begin x<=0;if(y!=2) y<=y+1;else state<=DRAIN;end
         end
      endcase
     end
    end
    DRAIN:if(outstanding==0 && !core_busy && queued==0) begin
     blocks_completed<=blocks_completed+1;output_base<=dest_base;
     last_block_cycles<=active_block_cycles+1'b1;
     state<=pause_each_block ? PAUSE : FINISH;
    end
    PAUSE:if(resume) state<=FINISH;
    FINISH:if(blocks_completed==9) begin done<=1;state<=IDLE;end
     else begin
      input_base<=dest_base;dest_base<=dest_base==0 ? 384 : 0;parameter_base<=parameter_base+1440;
      phase<=0;ch<=0;x<=0;y<=0;outstanding<=0;started<=0;active_block_cycles<=0;state<=RUN;
     end
   endcase
  end
 end
endmodule
