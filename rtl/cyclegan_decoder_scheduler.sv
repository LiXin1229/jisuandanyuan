`include "mn_isa.vh"
// Three stride-2 transposed convolutions. Four CONV phases use the existing
// accumulator, then the original NORM/ReLU quantization. Two phase slots let
// cache interleaving and DDR writes overlap the next output channel.
module cyclegan_decoder_scheduler(
 input wire clk,rstn,frame_start,start,pause_each_layer,resume,
 output reg [127:0] instruction,output wire instruction_valid,input wire instruction_ready,
 input wire core_busy,memory_ready,input wire [2:0] queued,
 input wire writeback_valid,input wire [10:0] writeback_addr,input wire [3:0] writeback_opcode,
 output reg done,output wire paused,output reg [1:0] layers_completed,
 output reg [31:0] cycles,layer_cycles,command_wait_cycles,data_wait_cycles,
 output wire req_valid,input wire req_ready,output wire [31:0] req_addr,output wire [2:0] req_beats,
 input wire rsp_valid,output wire rsp_ready,input wire [511:0] rsp_data,
 output wire cache_wr,input wire cache_ready,output wire [10:0] cache_waddr,
 output wire [799:0] cache_wdata,output wire [39:0] cache_we,
 output wire cache_rd,input wire cache_read_ready,output wire [10:0] cache_raddr,input wire cache_rvalid,input wire [799:0] cache_rdata,
 output wire write_valid,input wire write_ready,output wire [31:0] write_addr,output wire [399:0] write_data
);
 localparam IDLE=0,RUN=1,DRAIN=2,PAUSE=3,NEXT=4;
 reg [2:0] state;reg [1:0] layer,phase;
 reg [4:0] ch,co,x;reg [3:0] y;
 reg norm;
 reg [1:0] owned,ready_slots;
 reg [3:0] consumed_rows;
 wire [5:0] cin=layer==0 ? 32 : layer==1 ? 16 : 8;
 wire [4:0] cout=layer==0 ? 16 : 8;
 wire [4:0] width=layer==0 ? 4 : layer==1 ? 8 : 16;
 wire [3:0] height=layer==0 ? 3 : layer==1 ? 6 : 12;
 wire [14:0] weights=layer==0 ? 14027 : layer==1 ? 18667 : 19835;
 wire [14:0] bn=layer==0 ? 18635 : layer==1 ? 19819 : 20411;
 wire [1:0] bank=y%4'd3;
 wire [1:0] bottom_bank=y==height-1 ? bank : bank==2 ? 0 : bank+2'd1;
 wire [10:0] col_ch=layer==1 ? {2'd0,x,4'd0}+ch : {3'd0,x,3'd0}+ch;
 wire [10:0] src=layer==0 ? ({6'd0,ch}<<3)+({6'd0,ch}<<2)+{5'd0,y[1:0],x[1:0]} :
                                  11'd512+{2'd0,bank,7'd0}+col_ch;
 wire [10:0] dst=11'd1424+{8'd0,co[0],phase};
 wire [14:0] co_weights=layer==0 ? ({10'd0,co}<<8)+({10'd0,co}<<5) :
                                  layer==1 ? ({10'd0,co}<<7)+({10'd0,co}<<4) : ({10'd0,co}<<6)+({10'd0,co}<<3);
 wire [14:0] phase_offset=phase==0 ? 0 : phase==1 ? cin : phase==2 ? (cin<<1)+cin : (cin<<2)+cin;
 wire [14:0] channel_offset=phase==0 ? ch : phase==3 ? {8'd0,ch,2'd0} : {9'd0,ch,1'b0};
 wire [14:0] parameter_addr=norm ? bn+{9'd0,co,1'b0} : weights+co_weights+phase_offset+channel_offset;
 wire starting_slot=phase==0 && ch==0 && !norm;
 reg [3:0] loaded_rows,load_y;
 reg [4:0] load_x,load_ch;reg half;
 localparam L_IDLE=0,L_REQ=1,L_RSP=2;
 reg [1:0] load_state;
 wire rows_ready=layer==0 || loaded_rows>=(y==height-1 ? height : y+2);
 assign instruction_valid=state==RUN && rows_ready && (!starting_slot || !owned[co[0]]);
 assign paused=state==PAUSE;
 always @* begin
  instruction=0;
  instruction[3:0]=norm ? `MN_OP_NORM : `MN_OP_CONV;
  instruction[13:4]=norm ? dst[9:0] : src[9:0];instruction[90]=norm ? dst[10] : src[10];
  instruction[23:14]=dst[9:0];instruction[91]=dst[10];
  instruction[35:24]=parameter_addr[11:0];instruction[94:92]=parameter_addr[14:12];
  instruction[43:41]=phase==0 ? 5 : phase==1 ? 0 : phase==2 ? 1 : 2;
  instruction[45:44]=norm ? 1 : 0;
  instruction[51:50]=1;instruction[53:52]=1;
  // All four phase kernels have a forward anchor (1x1,1x2,2x1,2x2).
  // Top/left window cells never enter a MAC. Zero these unused halos so
  // the previous ring row can be replaced while the current row computes.
  instruction[57:54]={y==height-1,1'b1,x==width-1,1'b1};
  instruction[61:58]=9;instruction[65:62]=9;
  instruction[75:66]=layer==0 ? 1 : cin;
  instruction[85:76]=layer==0 ? 4 : 128;
  instruction[86]=1;instruction[87]=!norm && ch!=0;instruction[88]=!norm && ch!=cin-1;
  instruction[95]=layer!=0;
  instruction[106:96]=src;
  instruction[117:107]=11'd512+{2'd0,bottom_bank,7'd0}+col_ch;
 end
 // Input rows are interleaved by channel in a three-row ring. A reused row
 // is released at its last output, with no reader of the unused top halo.
 wire [12:0] input_index=layer==1 ? ({8'd0,load_ch}<<5)+({8'd0,load_ch}<<4)+{6'd0,load_y,3'd0}+load_x :
                                    ({8'd0,load_ch}<<7)+({8'd0,load_ch}<<6)+{5'd0,load_y,4'd0}+load_x;
 assign req_valid=load_state==L_REQ;
 assign req_addr=(layer==1 ? 32'h00300000 : 32'h00400000)+{12'd0,input_index,7'd0}+(half ? 32'd64 : 0);
 assign req_beats=4;
 assign rsp_ready=load_state==L_RSP && cache_ready;
 wire input_write=load_state==L_RSP && rsp_valid;
 wire [10:0] input_address=11'd512+((load_y%4'd3)<<7)+(layer==1 ? ({6'd0,load_x}<<4) : ({6'd0,load_x}<<3))+load_ch;
 // Packing uses only two five-pixel registers. The four source phases and
 // the complete destination tile live in the existing feature cache.
 localparam P_IDLE=0,P_EVEN=1,P_EWAIT=2,P_ODD=3,P_OWAIT=4,P_ROW=5,P_READ=6,P_SEND=7,P_ACK=8;
 reg [3:0] pack_state;reg pack_slot;reg [1:0] quad;reg [3:0] row;reg send_half;
 reg [39:0] even_pixels,odd_pixels;
 reg [4:0] slot_co[0:1],slot_x[0:1];reg [3:0] slot_y[0:1];
 reg [4:0] exec_co,exec_x;reg [3:0] exec_y;
 // Encoder pooled outputs also occupy 1424..1431. Shared-unit writeback
 // events belong to this scheduler only while its stage is active.
 wire phase_complete=(state==RUN || state==DRAIN) && writeback_valid && writeback_opcode==`MN_OP_NORM && writeback_addr>=1424 && writeback_addr<1432 && writeback_addr[1:0]==3;
 wire [3:0] source_row=(quad[1] ? 4'd5 : 4'd0)+(row>>1);
 wire [6:0] source_pixel=(source_row>=5 ? 7'd50 : 0)+(quad[0] ? 7'd25 : 0)+(source_row>=5 ? source_row-5 : source_row)*7'd5;
 wire [39:0] selected_pixels=cache_rdata[source_pixel*8+:40];
 wire [79:0] woven;
 genvar g;generate for(g=0;g<5;g=g+1) begin:g_weave
  assign woven[g*16+:8]=even_pixels[g*8+:8];assign woven[g*16+8+:8]=odd_pixels[g*8+:8];
 end endgenerate
 wire pack_row_write=pack_state==P_ROW && !input_write;
 wire [10:0] output_address=11'd1432+{8'd0,pack_slot,quad};
 assign cache_wr=(input_write || pack_row_write) && cache_ready;
 assign cache_waddr=input_write ? input_address : output_address;
 wire [799:0] row_data;wire [39:0] row_mask;
 generate for(g=0;g<100;g=g+1) begin:g_row_data
  localparam Q=g/25,C=g%5;
  assign row_data[g*8+:8]=woven[((Q%2)*5+C)*8+:8];
 end
 for(g=0;g<40;g=g+1) begin:g_row_mask
  localparam Q=g/10,R=(g%10)/2;
  assign row_mask[g]=(Q/2==(row>=5)) && R==(row>=5 ? row-5 : row);
 end endgenerate
 assign cache_wdata=input_write ? {2{rsp_data[399:0]}} : row_data;
 assign cache_we=input_write ? (half ? 40'hfffff00000 : 40'h00000fffff) : row_mask;
 // Streaming host reads share port B only when the unit has no cache
 // read/write that cycle. Input DMA owns port A first.
 assign cache_rd=cache_read_ready && ((pack_state==P_EVEN || pack_state==P_ODD) || (pack_state==P_READ && write_ready));
 assign cache_raddr=pack_state==P_READ ? output_address : 11'd1424+{8'd0,pack_slot,row[0],pack_state==P_ODD};
 wire [12:0] out_channel_offset=layer==0 ? ({8'd0,slot_co[pack_slot]}<<5)+({8'd0,slot_co[pack_slot]}<<4) :
                                    layer==1 ? ({8'd0,slot_co[pack_slot]}<<7)+({8'd0,slot_co[pack_slot]}<<6) :
                                               ({8'd0,slot_co[pack_slot]}<<9)+({8'd0,slot_co[pack_slot]}<<8);
 wire [9:0] out_spatial=layer==0 ? ({6'd0,slot_y[pack_slot]}<<4)+({9'd0,quad[1]}<<3)+({5'd0,slot_x[pack_slot]}<<1)+quad[0] :
                                 layer==1 ? ({5'd0,slot_y[pack_slot]}<<5)+({8'd0,quad[1]}<<4)+({4'd0,slot_x[pack_slot]}<<1)+quad[0] :
                                            ({5'd0,slot_y[pack_slot]}<<6)+({8'd0,quad[1]}<<5)+({4'd0,slot_x[pack_slot]}<<1)+quad[0];
 wire [12:0] out_index=out_channel_offset+out_spatial;
 assign write_addr=(layer==0 ? 32'h00300000 : layer==1 ? 32'h00400000 : 32'h00500000)+{12'd0,out_index,7'd0}+(send_half ? 32'd64 : 0);
 assign write_data=send_half ? cache_rdata[799:400] : cache_rdata[399:0];
 assign write_valid=(state==RUN || state==DRAIN) && pack_state==P_SEND && cache_rvalid;
 reg [31:0] active_layer_cycles;
 reg eligible_previous;
 wire eligible=state==RUN && rows_ready && (!starting_slot || !owned[co[0]]);
 always @(posedge clk) begin
  done<=0;
  if(!rstn || frame_start) begin
   state<=IDLE;layer<=0;phase<=0;ch<=0;co<=0;x<=0;y<=0;norm<=0;
   owned<=0;ready_slots<=0;consumed_rows<=0;loaded_rows<=0;load_y<=0;load_x<=0;load_ch<=0;half<=0;load_state<=L_IDLE;
   pack_state<=P_IDLE;pack_slot<=0;quad<=0;row<=0;send_half<=0;even_pixels<=0;odd_pixels<=0;
   slot_co[0]<=0;slot_co[1]<=0;slot_x[0]<=0;slot_x[1]<=0;slot_y[0]<=0;slot_y[1]<=0;
   exec_co<=0;exec_x<=0;exec_y<=0;layers_completed<=0;cycles<=0;layer_cycles<=0;active_layer_cycles<=0;command_wait_cycles<=0;data_wait_cycles<=0;eligible_previous<=0;
  end else begin
   if(state==RUN || state==DRAIN) begin cycles<=cycles+1;active_layer_cycles<=active_layer_cycles+1;end
   // Count empty instruction supply only while useful work is eligible.
   // The first FIFO refill after a data/ownership stall belongs to that
   // dependency. Count instruction starvation only after eligibility persists.
   eligible_previous<=eligible;
   if(eligible && eligible_previous && memory_ready && queued==0) command_wait_cycles<=command_wait_cycles+1;
   if(state==RUN && !rows_ready) data_wait_cycles<=data_wait_cycles+1;
   if(state==RUN && layer!=0 && load_state==L_IDLE && load_y<height && load_y<=consumed_rows+2) load_state<=L_REQ;
   if(load_state==L_REQ && req_ready) load_state<=L_RSP;
   if(load_state==L_RSP && rsp_valid && rsp_ready) begin
    if(!half) begin half<=1;load_state<=L_REQ;end
    else begin
     half<=0;load_state<=L_IDLE;
     if(load_ch==cin-1) begin
      load_ch<=0;
      if(load_x==width-1) begin load_x<=0;load_y<=load_y+1;loaded_rows<=loaded_rows+1;end
      else load_x<=load_x+1;
     end else load_ch<=load_ch+1;
    end
   end
   if(phase_complete) begin
    ready_slots[writeback_addr[2]]<=1;
    slot_co[writeback_addr[2]]<=exec_co;slot_x[writeback_addr[2]]<=exec_x;slot_y[writeback_addr[2]]<=exec_y;
    if(exec_co==cout-1) begin
     exec_co<=0;
     if(exec_x==width-1) begin exec_x<=0;exec_y<=exec_y+1;consumed_rows<=consumed_rows+1;end
     else exec_x<=exec_x+1;
    end else exec_co<=exec_co+1;
   end
   case(pack_state)
    P_IDLE:if(ready_slots!=0) begin pack_slot<=ready_slots[0] ? 0 : 1;quad<=0;row<=0;send_half<=0;pack_state<=P_EVEN;end
    P_EVEN:if(cache_rd) pack_state<=P_EWAIT;
    P_EWAIT:if(cache_rvalid) begin even_pixels<=selected_pixels;pack_state<=P_ODD;end
    P_ODD:if(cache_rd) pack_state<=P_OWAIT;
    P_OWAIT:if(cache_rvalid) begin odd_pixels<=selected_pixels;pack_state<=P_ROW;end
    P_ROW:if(pack_row_write && cache_ready) begin
     if(row==9) begin send_half<=0;pack_state<=P_READ;end else begin row<=row+1;pack_state<=P_EVEN;end
    end
    P_READ:if(cache_rd) pack_state<=P_SEND;
    P_SEND:if(write_valid && write_ready) pack_state<=P_ACK;
    P_ACK:if(write_ready) begin
     if(!send_half) begin send_half<=1;pack_state<=P_READ;end
     else if(quad!=3) begin quad<=quad+1;row<=0;pack_state<=P_EVEN;end
     else begin owned[pack_slot]<=0;ready_slots[pack_slot]<=0;pack_state<=P_IDLE;end
    end
   endcase
   case(state)
    IDLE:if(start) state<=RUN;
    RUN:if(instruction_valid && instruction_ready) begin
     if(starting_slot) owned[co[0]]<=1;
     if(!norm) begin if(ch==cin-1) norm<=1;else ch<=ch+1;end
     else begin
      norm<=0;ch<=0;
      if(phase!=3) phase<=phase+1;
      else begin
       phase<=0;
       if(co!=cout-1) co<=co+1;
       else begin co<=0;if(x!=width-1) x<=x+1;else begin x<=0;if(y!=height-1) y<=y+1;else state<=DRAIN;end end
      end
     end
    end
    DRAIN:if(!core_busy && queued==0 && owned==0 && pack_state==P_IDLE && write_ready) begin
     layers_completed<=layers_completed+1;layer_cycles<=active_layer_cycles+1;state<=pause_each_layer ? PAUSE : NEXT;
    end
    PAUSE:if(resume) state<=NEXT;
    NEXT:if(layer==2) begin state<=IDLE;done<=1;end
     else begin
      layer<=layer+1;state<=RUN;phase<=0;co<=0;ch<=0;x<=0;y<=0;norm<=0;
      loaded_rows<=0;load_y<=0;load_x<=0;load_ch<=0;half<=0;load_state<=L_IDLE;
      consumed_rows<=0;exec_co<=0;exec_x<=0;exec_y<=0;active_layer_cycles<=0;
     end
   endcase
  end
 end
endmodule
