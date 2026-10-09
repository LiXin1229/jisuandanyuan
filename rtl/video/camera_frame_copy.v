`timescale 1ns/1ps
// Read a complete burst into a tiny BRAM before presenting its write address.
// The real DDR controller can stall reads behind an unfilled write command.
// Releasing read ownership before waiting for AW also preserves HDMI service.
module camera_frame_copy #(parameter BURSTS=2400)(
 input wire clk,rstn,start,input wire [31:0] source_base,destination_base,
 output wire busy,output reg done=0,fault=0,
 output wire arvalid,input wire arready,output wire [31:0] araddr,output wire [7:0] arlen,
 input wire rvalid,output wire rready,input wire [127:0] rdata,input wire rlast,input wire [1:0] rresp,
 output wire awvalid,input wire awready,output wire [31:0] awaddr,output wire [7:0] awlen,
 output wire wvalid,input wire wready,output wire [127:0] wdata,output wire wlast,
 input wire bvalid,input wire [1:0] bresp,output wire bready,output wire [5:0] diagnostic);
 localparam IDLE=0,AW=1,AR=2,DATA=3,B=4,READ=5,FETCH=6;
 reg [2:0] state=IDLE,beat=0;reg [11:0] burst=0;reg [31:0] source=0,destination=0;
 assign diagnostic={state,beat};
 (* syn_ramstyle="block_ram" *) reg [127:0] buffer[0:7];reg [127:0] q;
 always @(posedge clk) begin
  if(state==READ && rvalid && rready) buffer[beat]<=rdata;
  q<=buffer[beat];
 end
 assign busy=state!=IDLE;assign awvalid=state==AW;assign awlen=7;assign awaddr=destination+{13'd0,burst,7'd0};
 assign arvalid=state==AR;assign arlen=7;assign araddr=source+{13'd0,burst,7'd0};
 assign wvalid=state==DATA;assign wdata=q;assign wlast=beat==7;
 assign rready=state==READ;assign bready=state==B;
 always @(posedge clk) begin
  done<=0;
  if(!rstn) begin state<=IDLE;beat<=0;burst<=0;done<=0;fault<=0;source<=0;destination<=0;end
  else case(state)
   IDLE:if(start) begin source<=source_base;destination<=destination_base;burst<=0;beat<=0;state<=AR;end
   AR:if(arready) begin beat<=0;state<=READ;end
   READ:if(rvalid && rready) begin
    if(rresp!=0 || rlast!=(beat==7)) fault<=1;
    if(beat==7) begin beat<=0;state<=AW;end else beat<=beat+1;
   end
   AW:if(awready) state<=FETCH;
   FETCH:state<=DATA;
   DATA:if(wready) begin
    if(beat==7) begin beat<=0;state<=B;end else begin beat<=beat+1;state<=FETCH;end
   end
   B:if(bvalid) begin
    if(bresp!=0) fault<=1;
    if(burst==BURSTS-1) begin done<=1;state<=IDLE;end
    else begin burst<=burst+1;state<=AR;end
   end
  endcase
 end
endmodule
