`timescale 1ns/1ps
// Retain ownership from accepted AW through B; input-frame and output writes.
module axi_write_arbiter2 #(parameter FAIR=1,PRIORITY_WINDOW=0)(input wire clk,rstn,input wire p_hold,
 input wire p_awvalid,output wire p_awready,input wire [31:0] p_awaddr,input wire [7:0] p_awlen,
 input wire p_wvalid,output wire p_wready,input wire [127:0] p_wdata,input wire p_wlast,
 output wire p_bvalid,input wire p_bready,
 input wire t_awvalid,output wire t_awready,input wire [31:0] t_awaddr,input wire [7:0] t_awlen,
 input wire t_wvalid,output wire t_wready,input wire [127:0] t_wdata,input wire t_wlast,
 output wire t_bvalid,input wire t_bready,
 output wire awvalid,input wire awready,output wire [31:0] awaddr,output wire [7:0] awlen,
 output wire wvalid,input wire wready,output wire [127:0] wdata,output wire wlast,
 input wire bvalid,output wire bready,output wire [2:0] diagnostic);
 localparam IDLE=0,ADDRESS=1,TRANSFER=2;
 reg [1:0] state=IDLE;reg owner=0,last_owner=1;
 assign diagnostic={state,owner};
 wire occupied=state==TRANSFER;
 wire t_eligible=t_awvalid && (!PRIORITY_WINDOW || !p_hold);
 wire pick=t_eligible && (!p_awvalid || (FAIR && !last_owner));
 assign awvalid=state==ADDRESS;
 assign awaddr=owner ? t_awaddr : p_awaddr;assign awlen=owner ? t_awlen : p_awlen;
 assign p_awready=state==ADDRESS && !owner && awready;assign t_awready=state==ADDRESS && owner && awready;
 assign wvalid=occupied && (owner ? t_wvalid : p_wvalid);
 assign wdata=owner ? t_wdata : p_wdata;assign wlast=owner ? t_wlast : p_wlast;
 assign p_wready=occupied && !owner && wready;assign t_wready=occupied && owner && wready;
 assign p_bvalid=occupied && !owner && bvalid;assign t_bvalid=occupied && owner && bvalid;
 assign bready=occupied && (owner ? t_bready : p_bready);
 always @(posedge clk) begin
  if(!rstn) begin state<=IDLE;owner<=0;last_owner<=1;end
  else case(state)
   IDLE:if(p_awvalid || t_eligible) begin owner<=pick;state<=ADDRESS;end
   ADDRESS:if(awready) begin state<=TRANSFER;last_owner<=owner;end
   TRANSFER:if(bvalid && bready) state<=IDLE;
  endcase
 end
endmodule
