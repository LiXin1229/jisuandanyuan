`timescale 1ns/1ps
// Single outstanding bundled-data toggle CDC. The response bank remains stable
// until its consumer accepts it; there is no duplicate 512-bit response register.
// Optional decoder tile coalescing: read both 64-byte halves in one burst and
// serve only the immediately following upper-half request from the held bank.
module cyclegan_ddr_read_bridge #(parameter TILE_PAIR_CACHE=0,RAW_TILE_PAIR_CACHE=0) (
 input wire cclk,crstn,req_valid,output wire req_ready,input wire [31:0] req_addr,
 input wire [2:0] req_beats,output reg rsp_valid,input wire rsp_ready,
 output wire [511:0] rsp_data,output reg fault,
 input wire dclk,drstn,enable,
 output wire arvalid,input wire arready,output wire [31:0] araddr,output wire [7:0] arlen,
 input wire rvalid,output wire rready,input wire [127:0] rdata,
 input wire rlast,input wire [1:0] rresp,output wire [1:0] state_debug
);
 reg request_toggle,core_pending;
 reg [31:0] addr_hold;reg [2:0] beats_hold;
 reg done_s1,done_s2,done_seen;
 reg [1:0] response_settle;
 reg req_s1,req_s2,req_seen,done_toggle;
 localparam RESPONSE_BITS=TILE_PAIR_CACHE ? 1024 : 512;
 reg [1:0] state;reg [2:0] beat;
 assign state_debug=state;
 reg [31:0] address;reg [3:0] length;
 reg [RESPONSE_BITS-1:0] response_hold;reg error_hold;
 reg requested_pair=0,pair_valid=0,select_upper=0;
 wire pair_request=TILE_PAIR_CACHE && req_beats==4 &&
  (req_addr[31:20]==12'h003 || (RAW_TILE_PAIR_CACHE && req_addr[31:20]==12'h008)) && req_addr[6:0]==0;
 wire pair_hit=TILE_PAIR_CACHE && pair_valid && req_beats==4 && req_addr==addr_hold+32'd64;
 generate if(TILE_PAIR_CACHE) begin:g_pair_data
  assign rsp_data=select_upper ? response_hold[1023:512] : response_hold[511:0];
 end else begin:g_direct_data
  assign rsp_data=response_hold;
 end endgenerate
 assign req_ready=!core_pending && !rsp_valid;
 assign arvalid=enable && state==1;assign araddr=address;assign arlen=length-1;
 assign rready=state==2;
 always @(posedge cclk) begin
  if(!crstn) begin
   request_toggle<=0;core_pending<=0;addr_hold<=0;beats_hold<=0;
   done_s1<=0;done_s2<=0;done_seen<=0;rsp_valid<=0;fault<=0;
   requested_pair<=0;pair_valid<=0;select_upper<=0;
   response_settle<=0;
  end else begin
   done_s1<=done_toggle;done_s2<=done_s1;
   if(req_valid && req_ready) begin
    pair_valid<=0;
    if(pair_hit) begin select_upper<=1;rsp_valid<=1;end
    else begin
     addr_hold<=req_addr;beats_hold<=req_beats;requested_pair<=pair_request;
     select_upper<=0;request_toggle<=~request_toggle;core_pending<=1;
    end
   end
   if(done_s2!=done_seen) begin
    // Keep the bundled data bank stable for three additional consumer clocks
    // before exposing it to the RGB scatter/mux datapath. No second data bank.
    done_seen<=done_s2;response_settle<=3;
    pair_valid<=requested_pair && !error_hold;
    if(error_hold) fault<=1;
   end
   if(response_settle!=0) begin
    response_settle<=response_settle-1;
    if(response_settle==1) begin rsp_valid<=1;core_pending<=0;end
   end
   if(rsp_valid && rsp_ready) rsp_valid<=0;
  end
 end
 always @(posedge dclk) begin
  if(!drstn) begin
   req_s1<=0;req_s2<=0;req_seen<=0;done_toggle<=0;state<=0;beat<=0;
   address<=0;length<=0;response_hold<=0;error_hold<=0;
  end else begin
   req_s1<=request_toggle;req_s2<=req_s1;
   case(state)
    0:if(req_s2!=req_seen) begin
     req_seen<=req_s2;address<=addr_hold;length<=requested_pair ? 4'd8 : {1'b0,beats_hold};
     beat<=0;response_hold<=0;error_hold<=0;state<=1;
    end
    1:if(arvalid && arready) state<=2;
    2:if(rvalid && rready) begin
     response_hold[beat*128+:128]<=rdata;
     if(rresp!=0 || rlast!=(beat==length-1)) error_hold<=1;
     if(beat==length-1) state<=3;else beat<=beat+1;
    end
    3:begin done_toggle<=~done_toggle;state<=0;end
   endcase
  end
 end
endmodule
