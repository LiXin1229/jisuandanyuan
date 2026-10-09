// Hold an owner from before AW presentation through the B handshake.
// Round robin permits next-frame RGB upload during feature writeback.
module cyclegan_write_arbiter(
 input wire clk,rstn,
 input wire a_awvalid,output wire a_awready,input wire [31:0] a_awaddr,input wire [7:0] a_awlen,
 input wire a_wvalid,output wire a_wready,input wire [127:0] a_wdata,input wire a_wlast,
 output wire a_bvalid,input wire a_bready,
 input wire b_awvalid,output wire b_awready,input wire [31:0] b_awaddr,input wire [7:0] b_awlen,
 input wire b_wvalid,output wire b_wready,input wire [127:0] b_wdata,input wire b_wlast,
 output wire b_bvalid,input wire b_bready,
 output wire awvalid,input wire awready,output wire [31:0] awaddr,output wire [7:0] awlen,
 output wire wvalid,input wire wready,output wire [127:0] wdata,output wire wlast,
 input wire bvalid,output wire bready
);
 reg active,owner,last_owner;
 assign awvalid=active && (owner ? b_awvalid : a_awvalid);
 assign awaddr=owner ? b_awaddr : a_awaddr;assign awlen=owner ? b_awlen : a_awlen;
 assign wvalid=active && (owner ? b_wvalid : a_wvalid);
 assign wdata=owner ? b_wdata : a_wdata;assign wlast=owner ? b_wlast : a_wlast;
 assign bready=active && (owner ? b_bready : a_bready);
 assign a_awready=active && !owner && awready;assign b_awready=active && owner && awready;
 assign a_wready=active && !owner && wready;assign b_wready=active && owner && wready;
 assign a_bvalid=active && !owner && bvalid;assign b_bvalid=active && owner && bvalid;
 always @(posedge clk) begin
  if(!rstn) begin active<=0;owner<=0;last_owner<=1;end
  else if(!active) begin
   if(a_awvalid || b_awvalid) begin active<=1;owner<=b_awvalid && (!a_awvalid || !last_owner);end
  end else if(bvalid && bready) begin active<=0;last_owner<=owner;end
 end
endmodule
