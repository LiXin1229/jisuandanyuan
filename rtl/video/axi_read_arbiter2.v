`timescale 1ns/1ps
// Lock selection BEFORE presenting AR, including the registered board AW/AR mux.
// Sources retain address/data until ready. Fair grants bound video starvation.
module axi_read_arbiter2 #(parameter FAIR=1,VIDEO_WINDOW=0)(input wire clk,rstn,input wire v_hold,
 input wire p_valid,output wire p_ready,input wire [31:0] p_addr,input wire [7:0] p_len,
 output wire p_rvalid,input wire p_rready,output wire [127:0] p_data,output wire p_last,
 input wire v_valid,output wire v_ready,input wire [31:0] v_addr,input wire [7:0] v_len,
 output wire v_rvalid,input wire v_rready,output wire [127:0] v_data,output wire v_last,
 output wire arvalid,input wire arready,output wire [31:0] araddr,output wire [7:0] arlen,
 input wire rvalid,output wire rready,input wire [127:0] rdata,input wire rlast,output wire [2:0] diagnostic);
 localparam IDLE=0,ADDRESS=1,RESPONSE=2;
 reg [1:0] state=IDLE;reg owner=0,last_owner=1;
 assign diagnostic={state,owner};
 wire p_eligible=p_valid && (!VIDEO_WINDOW || !v_hold);
 wire select_video=v_valid && (!p_eligible || (FAIR && !last_owner));
 assign arvalid=state==ADDRESS;assign araddr=owner ? v_addr : p_addr;
 assign arlen=owner ? v_len : p_len;assign p_ready=state==ADDRESS && !owner && arready;
 assign v_ready=state==ADDRESS && owner && arready;
 assign p_rvalid=state==RESPONSE && !owner && rvalid;assign v_rvalid=state==RESPONSE && owner && rvalid;
 assign p_data=rdata;assign v_data=rdata;assign p_last=rlast;assign v_last=rlast;
 assign rready=state==RESPONSE && (owner ? v_rready : p_rready);
 always @(posedge clk) if(!rstn) begin state<=IDLE;owner<=0;last_owner<=1;end
 else case(state)
  IDLE:if(p_eligible || v_valid) begin owner<=select_video;state<=ADDRESS;end
  ADDRESS:if(arready) begin state<=RESPONSE;last_owner<=owner;end
  RESPONSE:if(rvalid && rready && rlast) state<=IDLE;
 endcase
endmodule
