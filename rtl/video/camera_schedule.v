`timescale 1ns/1ps
// Start the next encoder while HDMI still owns its old output bank. Only the
// original copy and final styled writes need that bank; intermediate DDR
// features and the input slot have independent ownership.
module camera_schedule(input wire clk,rstn,enable,
 input wire [3:0] input_slots,input wire acquired,input wire [31:0] read_base,
 output reg acquire=0,release_frame=0,
 output reg copy_start=0,input wire copy_done,output wire [31:0] copy_destination,
 output reg core_start=0,input wire core_done,
 output reg running=0,output reg [15:0] processed_frames=0,
 output reg ready_toggle=0,ready_slot=0,input wire frame_ack_toggle,
 output wire [31:0] styled_write_base,output reg output_bank_ready=0,
 output reg [31:0] total_cycles=0,output wire [2:0] state_debug);
 localparam IDLE=0,ACQUIRE=1,COPY=2,RUN=3,WAIT_BANK=4;
 reg [2:0] state=IDLE;reg write_slot=1;
 assign state_debug=state;
 assign copy_destination=write_slot ? 32'h900000 : 32'h800000;
 assign styled_write_base=write_slot ? 32'h700000 : 32'h600000;
 always @(posedge clk) begin
  acquire<=0;release_frame<=0;copy_start<=0;core_start<=0;
  if(!rstn) begin
   state<=IDLE;write_slot<=1;running<=0;processed_frames<=0;
   ready_toggle<=0;ready_slot<=0;output_bank_ready<=0;total_cycles<=0;
  end else begin
   if(running) total_cycles<=total_cycles+1;
   case(state)
    IDLE:if(enable && input_slots[1:0]!=3 && input_slots[3:2]!=3 && (input_slots[1:0]==2 || input_slots[3:2]==2)) begin
     write_slot<=~write_slot;acquire<=1;state<=ACQUIRE;total_cycles<=0;running<=1;output_bank_ready<=0;
    end
    ACQUIRE:if(acquired) begin core_start<=1;state<=WAIT_BANK;end
    // The previous published slot remains stable until VSYNC acknowledgement.
    // At that point its predecessor (our new write_slot) is safe to overwrite.
    WAIT_BANK:if(frame_ack_toggle==ready_toggle) begin copy_start<=1;state<=COPY;end
    COPY:if(copy_done) begin output_bank_ready<=1;state<=RUN;end
    RUN:if(core_done) begin
     release_frame<=1;running<=0;processed_frames<=processed_frames+1;
     ready_slot<=write_slot;ready_toggle<=~ready_toggle;state<=IDLE;
    end
   endcase
  end
 end
endmodule
