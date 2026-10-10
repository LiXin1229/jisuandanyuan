`include "mn_isa.vh"
// Encoder with five complete-frame IN barriers. Scratch DDR 2 MiB is raw,
// 3 MiB is normalized/pooled. The residual input remains at cache 1056.
module cyclegan_encoder_instance_scheduler(
 input wire clk,rstn,start,input wire [31:0] frame_base,
 output reg done,output reg [31:0] input_checksum,
 output reg [127:0] instruction,output wire instruction_valid,input wire instruction_ready,
 input wire core_busy,input wire [2:0] queued,
 input wire writeback_valid,input wire [10:0] writeback_addr,input wire [3:0] writeback_opcode,
 output wire req_valid,input wire req_ready,output wire [31:0] req_addr,output wire [2:0] req_beats,
 input wire rsp_valid,output wire rsp_ready,input wire [511:0] rsp_data,
 output wire cache_wr,input wire cache_ready,output wire [10:0] cache_waddr,
 output wire [799:0] cache_wdata,output wire [39:0] cache_we,
 output wire cache_rd,input wire cache_read_ready,output wire [10:0] cache_raddr,
 input wire cache_rvalid,input wire [799:0] cache_rdata,
 output wire write_valid,input wire write_ready,output wire [31:0] write_addr,output wire [399:0] write_data,
 output wire pass_start,input wire pass_done,output wire [4:0] pass_point,
 output wire [5:0] pass_channels,pass_width,output wire [9:0] pass_tiles,
 output wire pass_pool,pass_relu,pass_final
);
 localparam IDLE=0,RUN=1,DRAIN=2,PSTART=3,PWAIT=4;
 reg [2:0] state;
 reg [1:0] layer;
 reg pw_mode,pw_phase;
 reg [4:0] x,y,ch,co,loaded_rows,load_y,load_x,load_ch,rgb_rows,rgb_x;
 reg [1:0] dma;
 reg load_half,pw_loaded;
 wire [5:0] cin=layer==0 ? 3 : layer==1 ? 8 : 16;
 wire [5:0] cout=layer==0 ? 8 : layer==1 ? 16 : 32;
 wire [5:0] width=layer==0 ? 32 : layer==1 ? 16 : 8;
 wire [4:0] height=layer==0 ? 24 : layer==1 ? 12 : 6;
 wire [9:0] tiles=layer==0 ? 768 : layer==1 ? 192 : 48;
 wire doing_pw=layer==0 ? pw_phase : pw_mode;
 wire rows_ready=layer==0 ? rgb_rows>=(y==height-1 ? height : y+2) : pw_mode ? pw_loaded : loaded_rows>=(y==height-1 ? height : y+2);
 reg [1:0] owned,ready_slots;
 wire slot=doing_pw ? co[0] : ch[0];
 assign instruction_valid=state==RUN && rows_ready && ((layer==0 && !doing_pw) || !owned[slot]);
 wire [1:0] bank=y%5'd3,upper=y==0 ? bank : bank==0 ? 2 : bank-2'd1,lower=y==height-1 ? bank : bank==2 ? 0 : bank+2'd1;
 function automatic [10:0] bank_offset(input [1:0] b,input raw);
  begin bank_offset=raw ? ({9'd0,b}<<6)+({9'd0,b}<<5) : {2'd0,b,7'd0};end
 endfunction
 wire [10:0] col=layer==0 ? ({6'd0,x}<<1)+x+ch : layer==1 ? {3'd0,x,3'd0}+ch : {2'd0,x,4'd0}+ch;
 wire [10:0] src=doing_pw ? 1440 : bank_offset(bank,layer==0)+col;
 wire [10:0] dst=layer==0 && !doing_pw ? 1440+ch : 1456+slot;
 wire [14:0] dw_base=layer==0 ? 0 : layer==1 ? 67 : 315;
 wire [14:0] pw_base=layer==0 ? 27 : layer==1 ? 155 : 491;
 wire [14:0] co_offset=layer==0 ? ({10'd0,co}<<1)+co : layer==1 ? {7'd0,co,3'd0} : {6'd0,co,4'd0};
 wire [14:0] param=doing_pw ? pw_base+co_offset : dw_base+({10'd0,ch}<<3)+ch;
 always @* begin
  instruction=0;instruction[3:0]=doing_pw ? `MN_OP_PW : `MN_OP_DW;
  instruction[13:4]=src[9:0];instruction[90]=src[10];instruction[23:14]=dst[9:0];instruction[91]=dst[10];
  instruction[35:24]=param[11:0];instruction[94:92]=param[14:12];
  instruction[61:58]=9;instruction[65:62]=9;instruction[86]=1;
  if(doing_pw) instruction[40:36]=cin-1;
  else begin
   instruction[43:41]=3;instruction[51:50]=layer==0 ? 2 : 1;instruction[53:52]=1;
   instruction[57:54]={y==height-1,y==0,x==width-1,x==0};
   instruction[75:66]=cin;instruction[85:76]=layer==0 ? 96 : 128;
   instruction[95]=1;instruction[106:96]=bank_offset(upper,layer==0)+col;
   instruction[117:107]=bank_offset(lower,layer==0)+col;
  end
 end
 wire rgb_busy,rgb_done,rgb_wr,rgb_req,rgb_rsp;
 wire [10:0] rgb_waddr;wire [799:0] rgb_wdata;wire [39:0] rgb_we;wire [31:0] rgb_addr;wire [2:0] rgb_beats;
 wire rgb_start=layer==0 && state==RUN && !rgb_busy && !rgb_done && rgb_rows<height && rgb_rows<=y+1;
 cyclegan_rgb_loader loader(.clk(clk),.rstn(rstn),.start(rgb_start),.frame_base(frame_base),.tile_x(rgb_x),.tile_y(rgb_rows),
  .busy(rgb_busy),.done(rgb_done),.req_valid(rgb_req),.req_ready(req_ready && layer==0),.req_addr(rgb_addr),.req_beats(rgb_beats),
  .rsp_valid(rsp_valid && layer==0),.rsp_ready(rgb_rsp),.rsp_data(rsp_data),
  .cache_wr(rgb_wr),.cache_ready(cache_ready),.cache_addr(rgb_waddr),.cache_data(rgb_wdata),.cache_we(rgb_we));
 wire [12:0] load_channel_offset=layer==1 ? ({8'd0,load_ch}<<7)+({8'd0,load_ch}<<6) : ({8'd0,load_ch}<<5)+({8'd0,load_ch}<<4);
 wire [12:0] load_spatial=layer==1 ? {4'd0,load_y,4'd0}+load_x : {5'd0,load_y,3'd0}+load_x;
 wire feature_input=layer!=0 && state==RUN && dma==2 && rsp_valid;
 assign req_valid=layer==0 ? rgb_req : state==RUN && dma==1;
 assign req_addr=layer==0 ? rgb_addr : 32'h00300000+({19'd0,load_channel_offset}+load_spatial)*128+(load_half ? 64 : 0);
 assign req_beats=layer==0 ? rgb_beats : 4;
 assign rsp_ready=layer==0 ? rgb_rsp : state==RUN && dma==2 && cache_ready;
 assign cache_wr=layer==0 ? rgb_wr : feature_input && cache_ready;
 assign cache_waddr=layer==0 ? rgb_waddr : pw_mode ? 1440+load_ch : bank_offset(load_y%5'd3,1'b0)+(layer==1 ? {3'd0,load_x,3'd0} : {2'd0,load_x,4'd0})+load_ch;
 assign cache_wdata=layer==0 ? rgb_wdata : {2{rsp_data[399:0]}};
 assign cache_we=layer==0 ? rgb_we : load_half ? 40'hfffff00000 : 40'h00000fffff;
 // Two output slots retain raw data until the DDR writer acknowledges it.
 localparam W_IDLE=0,W_READ=1,W_SEND=2,W_ACK=3;
 reg [1:0] writer;
 reg writer_slot,send_half;
 reg [12:0] slot_index[0:1];
 reg [4:0] exec_ch,exec_x,exec_y;
 wire [5:0] raw_channels=pw_mode || layer==0 ? cout : cin;
 wire [12:0] raw_channel_offset=layer==0 ? ({8'd0,exec_ch}<<9)+({8'd0,exec_ch}<<8) :
  layer==1 ? ({8'd0,exec_ch}<<7)+({8'd0,exec_ch}<<6) : ({8'd0,exec_ch}<<5)+({8'd0,exec_ch}<<4);
 wire [12:0] raw_spatial=layer==0 ? {3'd0,exec_y,5'd0}+exec_x : layer==1 ? {4'd0,exec_y,4'd0}+exec_x : {5'd0,exec_y,3'd0}+exec_x;
 wire completed=(state==RUN || state==DRAIN) && writeback_valid && writeback_addr>=1456 && writeback_addr<1458 &&
  writeback_opcode==(pw_mode || layer==0 ? `MN_OP_PW : `MN_OP_DW);
 assign cache_rd=writer==W_READ && write_ready && cache_read_ready;
 assign cache_raddr=1456+writer_slot;
 assign write_valid=writer==W_SEND && cache_rvalid;
 assign write_addr=32'h00200000+{12'd0,slot_index[writer_slot],7'd0}+(send_half ? 64 : 0);
 assign write_data=send_half ? cache_rdata[799:400] : cache_rdata[399:0];
 assign pass_start=state==PSTART;
 assign pass_point=layer==0 ? 0 : layer==1 ? (pw_mode ? 2 : 1) : (pw_mode ? 4 : 3);
 assign pass_channels=layer==0 || pw_mode ? cout : cin;
 assign pass_width=width;assign pass_tiles=tiles;
 assign pass_pool=layer==0 || pw_mode;
 assign pass_relu=layer==0 || !pw_mode;
 assign pass_final=layer==2 && pw_mode;
 reg [31:0] crc;
 function automatic [31:0] crc_row(input [31:0] seed,input [79:0] data);
  reg [31:0] c;integer i;begin c=seed;for(i=0;i<80;i=i+1)c=(c>>1)^((c[0]^data[i]) ? 32'hedb88320 : 0);crc_row=c;end
 endfunction
 always @(posedge clk) begin
  done<=0;
  if(!rstn) begin
   state<=IDLE;layer<=0;pw_mode<=0;pw_phase<=0;x<=0;y<=0;ch<=0;co<=0;
   loaded_rows<=0;load_y<=0;load_x<=0;load_ch<=0;rgb_rows<=0;rgb_x<=0;dma<=0;load_half<=0;pw_loaded<=0;
   owned<=0;ready_slots<=0;writer<=W_IDLE;writer_slot<=0;send_half<=0;slot_index[0]<=0;slot_index[1]<=0;
   exec_ch<=0;exec_x<=0;exec_y<=0;crc<=32'hffffffff;input_checksum<=0;
  end else begin
   if(rgb_wr) crc<=crc_row(crc,{rgb_wdata[239:200],rgb_wdata[39:0]});
   if(rgb_done) begin if(rgb_x==31) begin rgb_x<=0;rgb_rows<=rgb_rows+1'b1;end else rgb_x<=rgb_x+1'b1;end
   if(layer!=0 && state==RUN) begin
    if(dma==0 && (pw_mode ? !pw_loaded : load_y<height && load_y<=y+1)) dma<=1;
    if(req_valid && req_ready) dma<=2;
    if(feature_input && cache_ready) begin
     dma<=0;load_half<=!load_half;
     if(load_half) begin
      if(load_ch==cin-1) begin
       load_ch<=0;
       if(pw_mode) pw_loaded<=1;
       else if(load_x==width-1) begin load_x<=0;load_y<=load_y+1'b1;loaded_rows<=loaded_rows+1'b1;end
       else load_x<=load_x+1'b1;
      end else load_ch<=load_ch+1'b1;
     end
    end
   end
   if(completed) begin
    ready_slots[writeback_addr[0]]<=1;slot_index[writeback_addr[0]]<=raw_channel_offset+raw_spatial;
    if(exec_ch==raw_channels-1) begin exec_ch<=0;if(exec_x==width-1) begin exec_x<=0;exec_y<=exec_y+1'b1;end else exec_x<=exec_x+1'b1;end
    else exec_ch<=exec_ch+1'b1;
   end
   case(writer)
    W_IDLE:if(ready_slots!=0) begin writer_slot<=ready_slots[0] ? 0 : 1;send_half<=0;writer<=W_READ;end
    W_READ:if(cache_rd) writer<=W_SEND;
    W_SEND:if(write_valid && write_ready) writer<=W_ACK;
    W_ACK:if(write_ready) begin
     send_half<=!send_half;
     if(!send_half) writer<=W_READ;
     else begin owned[writer_slot]<=0;ready_slots[writer_slot]<=0;writer<=W_IDLE;end
    end
   endcase
   case(state)
    IDLE:if(start) begin
     state<=RUN;layer<=0;pw_mode<=0;pw_phase<=0;x<=0;y<=0;ch<=0;co<=0;
     loaded_rows<=0;load_y<=0;load_x<=0;load_ch<=0;rgb_rows<=0;rgb_x<=0;dma<=0;load_half<=0;pw_loaded<=0;
     exec_ch<=0;exec_x<=0;exec_y<=0;crc<=32'hffffffff;
    end
    RUN:if(instruction_valid && instruction_ready) begin
     if(layer!=0 || doing_pw) owned[slot]<=1;
     if(!doing_pw) begin
      if(ch!=cin-1) ch<=ch+1'b1;
      else begin ch<=0;if(layer==0) pw_phase<=1;else if(x==width-1) state<=DRAIN;else x<=x+1'b1;end
     end else if(co!=cout-1) co<=co+1'b1;
     else begin
      co<=0;pw_phase<=0;
      if(layer!=0 || x==width-1) state<=DRAIN;else x<=x+1'b1;
     end
    end
    DRAIN:if(!core_busy && queued==0 && owned==0 && writer==W_IDLE && write_ready) begin
     if(layer!=0 && pw_mode && x!=width-1) begin x<=x+1'b1;load_x<=x+1'b1;pw_loaded<=0;state<=RUN;end
     else if(y!=height-1) begin y<=y+1'b1;x<=0;load_x<=0;if(pw_mode) begin load_y<=y+1'b1;pw_loaded<=0;end state<=RUN;end
     else begin state<=PSTART;input_checksum<=~crc;end
    end
    PSTART:state<=PWAIT;
    PWAIT:if(pass_done) begin
     if(layer==2 && pw_mode) begin state<=IDLE;done<=1;end
     else begin
      if(layer==0 || pw_mode) begin layer<=layer+1'b1;pw_mode<=0;end else pw_mode<=1;
      pw_phase<=0;x<=0;y<=0;ch<=0;co<=0;loaded_rows<=0;load_y<=0;load_x<=0;load_ch<=0;dma<=0;load_half<=0;pw_loaded<=0;
      exec_ch<=0;exec_x<=0;exec_y<=0;state<=RUN;
     end
    end
   endcase
  end
 end
endmodule
