// Simulation-only network protocol source; never a synthesis input.
module cyclegan_encoder #(parameter COLUMN_PREFETCH=0, RESIDUAL_ENABLE=0, DECODER_ENABLE=0, OUTPUT_ENABLE=0,
 RESIDUAL_INSTANCE_NORM=0,FULL_INSTANCE_NORM=0,CORE_DELAY=8000000) (
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
 // Simulation only. Deliberately contains no arithmetic compute implementation.
 localparam IDLE=0,REQUEST=1,RESPONSE=2,DELAY=3,WRITE=4,DRAIN=5;
 reg [2:0] state=IDLE;reg variant=0,half=0;integer word_index=0,tile=0;
 reg [31:0] base=0;reg [127:0] image0[0:19199],image1[0:19199];
 reg [799:0] gold0[0:2303],gold1[0:2303];integer i;
 initial begin
  $readmemh("build/stage4/vectors/frame_rgbx.mem",image0);$readmemh("build/stage4/vectors_inverted/frame_rgbx.mem",image1);
  $readmemh("build/stage4/vectors/output_u8_tiles.mem",gold0);$readmemh("build/stage4/vectors_inverted/output_u8_tiles.mem",gold1);
 end
 assign busy=state!=IDLE;assign req_valid=state==REQUEST;assign req_addr=base+word_index*16;
 assign req_beats=4;assign rsp_ready=state==RESPONSE;
 assign feature_write_valid=state==WRITE;assign feature_write_addr=32'h600000+tile*128+(half ? 64 : 0);
 wire [799:0] expected=variant ? gold1[tile] : gold0[tile];
 assign feature_write_data=half ? expected[799:400] : expected[399:0];
 assign input_checksum=0;assign dbg_data=0;assign dbg_valid=0;
 assign raw_rows=0;assign stage1_rows=0;assign stage2_rows=0;assign stage3_rows=0;
 assign paused=0;assign blocks_completed=output_completed ? 9 : 0;assign residual_output_base=0;
 assign residual_cycles=0;assign block_cycles=0;assign decoder_cycles=0;assign layer_cycles=0;
 assign layers_completed=output_completed ? 3 : 0;assign output_completed=state==IDLE && cycles!=0;
 assign output_cycles=0;
 always @(posedge clk) begin
  done<=0;
  if(!rstn) begin state<=IDLE;fault<=0;cycles<=0;mac_cycles<=0;first_output_cycle<=0;
   command_wait_cycles<=0;data_wait_cycles<=0;encoder_cycles<=0;base<=0;word_index<=0;tile<=0;half<=0;variant<=0;
  end else begin
   if(busy) cycles<=cycles+1;
   case(state)
    IDLE:if(start) begin state<=REQUEST;base<=frame_base;variant<=frame_base[20];word_index<=0;tile<=0;half<=0;cycles<=0;end
    REQUEST:if(req_ready) state<=RESPONSE;
    RESPONSE:if(rsp_valid) begin
     for(i=0;i<4;i=i+1) if(rsp_data[i*128+:128] !== (variant ? image1[word_index+i] : image0[word_index+i]))
      $fatal(1,"Network protocol source read mismatched frame=%0d word=%0d",variant,word_index+i);
     if(word_index==19196) state<=DELAY;else begin word_index<=word_index+4;state<=REQUEST;end
    end
    DELAY:if(cycles>=CORE_DELAY) state<=WRITE;
    WRITE:if(feature_write_ready) begin
     if(!half) half<=1;
     else if(tile==2303) state<=DRAIN;
     else begin tile<=tile+1;half<=0;end
    end
    DRAIN:if(feature_write_ready) begin state<=IDLE;done<=1;end
   endcase
  end
 end
endmodule
