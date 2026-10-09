`timescale 1ns/1ps
// Two DDR RGBx slots; write ownership starts at SOF, publication waits for final B.
// A small BRAM FIFO absorbs the cropped camera's burst, not a full image.
module camera_frame_pingpong #(parameter PIXELS=76800,FIFO_DEPTH=512,HOLD_CAPTURE=1)(
 input wire clk,rstn,enable,s_valid,s_sof,s_eof,s_abort,input wire [23:0] s_rgb,
 input wire acquire,release_frame,
 output reg acquired=0,committed=0,output reg [31:0] read_base=0,read_id=0,
 output reg [31:0] read_checksum=0,
 output wire [3:0] slots,output wire write_active,output reg fault=0,
 output reg [15:0] captured_frames=0,dropped_frames=0,overflow_frames=0,
 output wire awvalid,input wire awready,output wire [31:0] awaddr,output wire [7:0] awlen,
 output wire wvalid,input wire wready,output wire [127:0] wdata,output wire wlast,
 input wire bvalid,input wire [1:0] bresp,output wire bready);
 localparam FREE=0,WRITING=1,READY=2,READING=3;
 localparam IDLE=0,AW=1,FETCH=2,LOAD=3,W=4,B=5;
 localparam PW=$clog2(PIXELS+1),FW=$clog2(FIFO_DEPTH);
 reg [1:0] slot0=FREE,slot1=FREE;reg [2:0] state=IDLE;
 reg writing=0,capture=0,aborted=0,reading=0,write_slot=0,read_slot=0;
 reg [31:0] frame_sequence=0,write_id=0,id0=0,id1=0;
 reg [PW-1:0] received=0;reg [12:0] chunk=0;reg [1:0] beat=0,part=0;
 reg [FW-1:0] wptr=0,rptr=0;reg [FW:0] fill=0;
 (* syn_ramstyle="block_ram" *) reg [31:0] fifo[0:FIFO_DEPTH-1];reg [31:0] q;
 reg [127:0] word=0;
 reg [31:0] frame_sum=0,sum0=0,sum1=0;
 wire [31:0] rgb_sum={24'd0,s_rgb[23:16]}+{24'd0,s_rgb[15:8]}+{24'd0,s_rgb[7:0]};
 wire free_slot=slot0==FREE || slot1==FREE;
 wire start_accept=s_sof && s_valid && enable && !writing && free_slot;
 wire push=s_valid && (start_accept || capture) && !aborted && fill<FIFO_DEPTH;
 wire pop=state==LOAD;
 // The arbiter retains AW ownership through B. Between bursts, reserve DDR
 // only when a complete 16-pixel chunk is pending; otherwise the FIFO has
 // headroom and the computation/copy writer can use the camera's idle gaps.
 assign write_active=HOLD_CAPTURE ? writing :
                     (state!=IDLE || (writing && fill>=16));
 assign slots={slot1,slot0};assign awvalid=enable && state==AW;assign awlen=3;
 assign awaddr=(write_slot ? 32'h100000 : 32'd0)+{13'd0,chunk,6'd0};
 assign wvalid=enable && state==W;assign wdata=word;assign wlast=beat==3;assign bready=state==B;
 always @(posedge clk) begin
  if(push) fifo[wptr]<={8'd0,s_rgb[7:0],s_rgb[15:8],s_rgb[23:16]};
  q<=fifo[rptr];
 end
 always @(posedge clk) begin
  acquired<=0;committed<=0;
  if(!rstn) begin
   slot0<=FREE;slot1<=FREE;state<=IDLE;writing<=0;capture<=0;aborted<=0;reading<=0;write_slot<=0;read_slot<=0;
   frame_sequence<=0;write_id<=0;id0<=0;id1<=0;received<=0;chunk<=0;beat<=0;part<=0;
   wptr<=0;rptr<=0;fill<=0;word<=0;read_base<=0;read_id<=0;fault<=0;
   captured_frames<=0;dropped_frames<=0;overflow_frames<=0;
   frame_sum<=0;sum0<=0;sum1<=0;read_checksum<=0;
  end else begin
   case({push,pop})
    2'b10:fill<=fill+1;2'b01:fill<=fill-1;default:begin end
   endcase
   if(push) wptr<=wptr+1;
   if(push) frame_sum<=(start_accept ? 32'd0 : frame_sum)+rgb_sum;
   if(pop) rptr<=rptr+1;
   if(s_sof && s_valid) begin
    frame_sequence<=frame_sequence+1;
    if(start_accept) begin
     writing<=1;capture<=1;aborted<=0;write_slot<=slot0!=FREE;write_id<=frame_sequence;
     if(slot0==FREE) slot0<=WRITING;else slot1<=WRITING;
     received<=1;chunk<=0;
    end else begin dropped_frames<=dropped_frames+1;capture<=0;if(capture) aborted<=1;end
   end else if(capture && s_valid) received<=received+1;
   if(capture && s_valid && fill==FIFO_DEPTH) begin
    aborted<=1;capture<=0;overflow_frames<=overflow_frames+1;
   end
   if(capture && s_abort) begin aborted<=1;capture<=0;end
   if(capture && s_valid && s_eof) begin
    capture<=0;if(received!=PIXELS-1) aborted<=1;
   end
   if(acquire) begin
    if(!reading && (slot0==READY || slot1==READY)) begin
     read_slot<=slot0!=READY || (slot1==READY && $signed(id1-id0)<0);
     read_base<=slot0!=READY || (slot1==READY && $signed(id1-id0)<0) ? 32'h100000 : 32'd0;
     read_id<=slot0!=READY || (slot1==READY && $signed(id1-id0)<0) ? id1 : id0;
     read_checksum<=slot0!=READY || (slot1==READY && $signed(id1-id0)<0) ? sum1 : sum0;
     if(slot0!=READY || (slot1==READY && $signed(id1-id0)<0)) slot1<=READING;else slot0<=READING;
     reading<=1;acquired<=1;
    end else fault<=1;
   end
   if(release_frame) begin
    if(reading) begin if(read_slot) slot1<=FREE;else slot0<=FREE;reading<=0;end
    else fault<=1;
   end
   case(state)
    IDLE:if(writing) begin
     if(aborted) begin
      writing<=0;capture<=0;aborted<=0;fill<=0;wptr<=0;rptr<=0;
      if(write_slot) slot1<=FREE;else slot0<=FREE;
     end else if(fill>=16) begin beat<=0;part<=0;state<=AW;end
    end
    AW:if(awready) state<=FETCH;
    FETCH:state<=LOAD;
    LOAD:begin
     word[part*32+:32]<=q;
     if(part==3) begin part<=0;state<=W;end else begin part<=part+1;state<=FETCH;end
    end
    W:if(wready) begin if(beat==3) state<=B;else begin beat<=beat+1;state<=FETCH;end end
    B:if(bvalid) begin
     state<=IDLE;
     if(bresp!=0) begin fault<=1;aborted<=1;capture<=0;end
     else if(chunk==PIXELS/16-1) begin
      if(!aborted && !(capture && s_abort) && !capture && received==PIXELS) begin
       writing<=0;committed<=1;captured_frames<=captured_frames+1;
       if(write_slot) begin slot1<=READY;id1<=write_id;sum1<=frame_sum;end
       else begin slot0<=READY;id0<=write_id;sum0<=frame_sum;end
      end else begin aborted<=1;capture<=0;end
     end else chunk<=chunk+1;
    end
   endcase
  end
 end
endmodule
