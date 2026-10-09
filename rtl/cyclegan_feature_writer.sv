// One 50-byte half tile, padded to 64 bytes. Payload stays in the source
// clock domain until the DDR B response crosses back. No duplicate CDC bank.
module cyclegan_feature_writer(
 input wire cclk,crstn,s_valid,output wire s_ready,
 input wire [31:0] s_addr,input wire [399:0] s_data,output reg fault,
 input wire dclk,drstn,enable,output wire awvalid,input wire awready,
 output wire [31:0] awaddr,output wire [7:0] awlen,
 output wire wvalid,input wire wready,output wire [127:0] wdata,output wire wlast,
 input wire bvalid,input wire [1:0] bresp,output wire bready
);
 reg request_toggle,ack_toggle,ack1,ack2,req1,req2,seen;
 reg [31:0] address_hold;reg [399:0] data_hold;reg error_hold;
 reg [1:0] state,beat;
 wire [511:0] padded={112'd0,data_hold};
 assign s_ready=request_toggle==ack2;
 assign awvalid=enable && state==1;assign awaddr=address_hold;assign awlen=3;
 assign wvalid=enable && state==2;assign wdata=padded[beat*128+:128];assign wlast=beat==3;
 assign bready=state==3;
 always @(posedge cclk) begin
  if(!crstn) begin request_toggle<=0;ack1<=0;ack2<=0;fault<=0;address_hold<=0;data_hold<=0;end
  else begin
   ack1<=ack_toggle;ack2<=ack1;
   if(s_valid && s_ready) begin address_hold<=s_addr;data_hold<=s_data;request_toggle<=~request_toggle;end
   if(error_hold) fault<=1;
  end
 end
 always @(posedge dclk) begin
  if(!drstn) begin req1<=0;req2<=0;seen<=0;ack_toggle<=0;state<=0;beat<=0;error_hold<=0;end
  else begin
   req1<=request_toggle;req2<=req1;
   case(state)
    0:if(req2!=seen) begin seen<=req2;state<=1;beat<=0;end
    1:if(awvalid && awready) state<=2;
    2:if(wvalid && wready) begin if(beat==3) state<=3;else beat<=beat+1'b1;end
    3:if(bvalid && bready) begin if(bresp!=0) error_hold<=1;ack_toggle<=seen;state<=0;end
   endcase
  end
 end
endmodule
