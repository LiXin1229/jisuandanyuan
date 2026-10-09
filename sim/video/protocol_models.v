`timescale 1ns/1ps
module DdrCtrl (
input clk,
input core_clk,
input twd_clk,
input tdqss_clk,
input tac_clk,
input reset_n,
output reset,
output cs,
output ras,
output cas,
output we,
output cke,
output [15:0] addr,
output [2:0] ba,
output odt,
output [2:0] shift,
output [4:0] shift_sel,
output shift_ena,
input cal_ena,
output cal_done,
output cal_pass,
output [6:0] cal_fail_log,
output [2:0] cal_shift_val,
output [1:0] o_dm_hi,
output [1:0] o_dm_lo,
input [1:0] i_dqs_hi,
input [1:0] i_dqs_lo,
input [1:0] i_dqs_n_hi,
input [1:0] i_dqs_n_lo,
output [1:0] o_dqs_hi,
output [1:0] o_dqs_lo,
output [1:0] o_dqs_n_hi,
output [1:0] o_dqs_n_lo,
output [1:0] o_dqs_oe,
output [1:0] o_dqs_n_oe,
input [15:0] i_dq_hi,
input [15:0] i_dq_lo,
output [15:0] o_dq_hi,
output [15:0] o_dq_lo,
output [15:0] o_dq_oe,
input [7:0] axi_aid,
input [31:0] axi_aaddr,
input [7:0] axi_alen,
input [2:0] axi_asize,
input [1:0] axi_aburst,
input [1:0] axi_alock,
input axi_avalid,
output axi_aready,
input axi_atype,
input [7:0] axi_wid,
input [127:0] axi_wdata,
input [15:0] axi_wstrb,
input axi_wlast,
input axi_wvalid,
output axi_wready,
output [7:0] axi_rid,
output reg [127:0] axi_rdata,
output reg axi_rlast,
output reg axi_rvalid,
input axi_rready,
output [1:0] axi_rresp,
output [7:0] axi_bid,
output [1:0] axi_bresp,
output reg axi_bvalid,
input axi_bready
);
 reg [127:0] memory [0:524287];
 reg writing=0,reading=0;integer ticks=0,waddr=0,wbeat=0,raddr=0,rbeat=0,rlen=0,wlen=0,bdelay=0;
 assign cal_done=reset_n;assign cal_pass=reset_n;assign cal_fail_log=0;assign cal_shift_val=0;
 assign axi_aready=reset_n && ticks%7!=0 && !(axi_atype ? writing || axi_bvalid || bdelay!=0 : reading || axi_rvalid);
 assign axi_wready=writing && ticks%5!=0;
 assign axi_rresp=0;assign axi_bresp=0;assign axi_rid=1;assign axi_bid=0;
 always @(posedge clk) begin
  if(!reset_n) begin axi_bvalid<=0;axi_rvalid<=0;axi_rlast<=0;axi_rdata<=0;end
  else begin
   ticks<=ticks+1;
   if(axi_avalid && axi_aready) begin
    if(axi_atype) begin waddr=axi_aaddr>>4;wbeat=0;wlen=axi_alen;writing<=1;end
    else begin raddr=axi_aaddr>>4;rbeat=0;rlen=axi_alen;reading<=1;end
   end
   if(axi_wvalid && axi_wready) begin
    memory[waddr+wbeat]<=axi_wdata;
    if(axi_wlast!=(wbeat==wlen)) $fatal(1,"W last");
    if(axi_wlast) begin writing<=0;bdelay<=4;end else wbeat=wbeat+1;
   end
   if(bdelay>0) begin bdelay<=bdelay-1;if(bdelay==1) axi_bvalid<=1;end
   if(axi_bvalid && axi_bready) axi_bvalid<=0;
   if(reading && !axi_rvalid && ticks%3!=0) begin
    axi_rdata<=memory[raddr+rbeat];axi_rlast<=rbeat==rlen;axi_rvalid<=1;
   end
   if(axi_rvalid && axi_rready) begin
    axi_rvalid<=0;if(axi_rlast) reading<=0;else rbeat=rbeat+1;
   end
  end
 end
endmodule
module edb_top (
    // debug core ports
    input  bscan_CAPTURE,
    input  bscan_DRCK,
    input  bscan_RESET,
    input  bscan_RUNTEST,
    input  bscan_SEL,
    input  bscan_SHIFT,
    input  bscan_TCK,
    input  bscan_TDI,
    input  bscan_TMS,
    input  bscan_UPDATE,
    output bscan_TDO,
    input  vio0_clk,
    input  [31:0] vio0_status,
    input  [31:0] vio0_cycles,
    input  [31:0] vio0_mac_cycles,
    input  [31:0] vio0_first_cycle,
    input  [31:0] vio0_counts,
    input  [31:0] vio0_frame_id,
    input  [31:0] vio0_calibration,
    input  [31:0] vio0_encoder_cycles,
    input  [31:0] vio0_residual_cycles,
    input  [31:0] vio0_progress,
    input  [255:0] vio0_read_data0,
    input  [255:0] vio0_read_data1,
    input  [31:0] vio0_block_metric,
    output reg [31:0] vio0_command,
    output reg [255:0] vio0_payload0,
    output reg [255:0] vio0_payload1
);
 initial begin vio0_command=0;vio0_payload0=0;vio0_payload1=0;end
 assign bscan_TDO=0;
endmodule

