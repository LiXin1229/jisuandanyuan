`timescale 1ns/1ps
// Ti60 DDR + shared CycleGAN compute core + official Efinity JTAG VIO.
// command[31]=toggle, [30:28]=1 frame begin,2 data64,3 run,4 cache read,5 clear,6 DDR read64.
module cyclegan_camera_board #(parameter SIM_CAMERA=0) (
 input wire clk_video,clk_video_5x,clk_video_fb,video_pll_lock,
 output wire video_pll_rstn_o,
 output wire hdmi_txc_oe,hdmi_txd0_oe,hdmi_txd1_oe,hdmi_txd2_oe,
 output wire hdmi_txc_rst_o,hdmi_txd0_rst_o,hdmi_txd1_rst_o,hdmi_txd2_rst_o,
 output wire [9:0] hdmi_txc_o,hdmi_txd0_o,hdmi_txd1_o,hdmi_txd2_o,
 input wire camera_pll_lock,clk_camera_fb,clk_27m,input wire [1:0] key_data,
 output wire camera_pll_rstn_o,
 output wire csi_ctl0_o,csi_ctl0_oe,csi_ctl1_o,csi_ctl1_oe,
 input wire csi_ctl0_i,csi_ctl1_i,csi_scl_i,csi_sda_i,
 output wire csi_scl_o,csi_scl_oe,csi_sda_o,csi_sda_oe,
 input wire csi_rxc_i,csi_rxc_lp_p_i,csi_rxc_lp_n_i,
 output wire csi_rxc_hs_en_o,csi_rxc_hs_term_en_o,
 input wire [7:0] csi_rxd0_hs_i,csi_rxd1_hs_i,csi_rxd2_hs_i,csi_rxd3_hs_i,
 input wire csi_rxd0_lp_p_i,csi_rxd0_lp_n_i,csi_rxd1_lp_p_i,csi_rxd1_lp_n_i,
 input wire csi_rxd2_lp_p_i,csi_rxd2_lp_n_i,csi_rxd3_lp_p_i,csi_rxd3_lp_n_i,
 output wire csi_rxd0_rst_o,csi_rxd1_rst_o,csi_rxd2_rst_o,csi_rxd3_rst_o,
 output wire csi_rxd0_hs_en_o,csi_rxd1_hs_en_o,csi_rxd2_hs_en_o,csi_rxd3_hs_en_o,
 output wire csi_rxd0_hs_term_en_o,csi_rxd1_hs_term_en_o,csi_rxd2_hs_term_en_o,csi_rxd3_hs_term_en_o,
 input wire clk_sys,clk_compute,sys_pll_lock,output wire sys_pll_rstn_o,
 input wire core_clk,tdqss_clk,tac_clk,twd_clk,ddr_pll_lock,output wire ddr_pll_rstn_o,
 output wire [2:0] shift,output wire [4:0] shift_sel,output wire shift_ena,
 output wire [15:0] addr,output wire [2:0] ba,
 output wire we,reset,ras,cas,odt,cke,cs,
 input wire [15:0] i_dq_hi,i_dq_lo,output wire [15:0] o_dq_hi,o_dq_lo,o_dq_oe,
 output wire [1:0] o_dm_hi,o_dm_lo,input wire [1:0] i_dqs_hi,i_dqs_lo,
 output wire [1:0] o_dqs_hi,o_dqs_lo,o_dqs_oe,o_dqs_n_oe,
 output wire clk_p_hi,clk_p_lo,clk_n_hi,clk_n_lo,
 input wire bscan_CAPTURE,bscan_DRCK,bscan_RESET,bscan_RUNTEST,bscan_SEL,
 input wire bscan_SHIFT,bscan_TCK,bscan_TDI,bscan_TMS,bscan_UPDATE,output wire bscan_TDO
);
 wire br_arvalid,br_arready,br_rvalid,br_rready,br_rlast;
 wire [31:0] br_araddr;wire [7:0] br_arlen;wire [127:0] br_rdata;
 wire [15:0] video_frames,video_underflows;wire [31:0] video_lines,video_sum;wire video_fault;
 assign sys_pll_rstn_o=1;assign ddr_pll_rstn_o=sys_pll_lock;
 assign shift_sel=5'b00100;assign o_dqs_n_oe=o_dqs_oe;
 // DDR command/data timing in the supplied board PHY requires CK at 180deg.
 assign clk_p_hi=0;assign clk_p_lo=1;assign clk_n_hi=1;assign clk_n_lo=0;
 reg [15:0] dp=0,cp=0;
 always @(posedge clk_sys) if(!sys_pll_lock || !ddr_pll_lock) dp<=0;else dp<={dp[14:0],1'b1};
 always @(posedge clk_compute) if(!sys_pll_lock || !ddr_pll_lock) cp<=0;else cp<={cp[14:0],1'b1};
 wire drstn=dp[15],crstn=cp[15];
 wire cal_done,cal_pass;wire [6:0] cal_log;wire [2:0] cal_shift;
 wire [2:0] auto_shift;wire auto_shift_ena;reg phase_applied=0;
 assign shift=cal_done ? 3'd6 : auto_shift;
 assign shift_ena=auto_shift_ena || (cal_done && !phase_applied);
 always @(posedge clk_sys) if(!drstn) phase_applied<=0;else phase_applied<=cal_done;
 wire enable=cal_done && cal_pass && phase_applied;
 wire awvalid,awready,wvalid,wready,wlast,bvalid,bready;
 wire [31:0] awaddr;wire [7:0] awlen;wire [127:0] wdata;wire [1:0] bresp;
 wire arvalid,arready,rvalid,rready,rlast;
 wire [31:0] araddr;wire [7:0] arlen;wire [127:0] rdata;wire [1:0] rresp;
 wire [3:0] aid;wire [31:0] aaddr;wire [7:0] alen;wire atype,avalid,aready;
 wire [2:0] mux_diag;
 camera_axi_mux #(.AID_LEN(4),.AADDR_LEN(32)) u_mux(.aclk_i(clk_sys),.arst_i(!drstn),
  .awid_i(4'd0),.awaddr_i(awaddr),.awlen_i(awlen),.awvalid_i(awvalid),.awready_o(awready),
  .arid_i(4'd1),.araddr_i(araddr),.arlen_i(arlen),.arvalid_i(arvalid),.arready_o(arready),
  .aid_o(aid),.aaddr_o(aaddr),.alen_o(alen),.atype_o(atype),.avalid_o(avalid),.aready_i(aready),.diagnostic(mux_diag));
 DdrCtrl u_ddr(.clk(clk_sys),.core_clk(core_clk),.twd_clk(twd_clk),.tdqss_clk(tdqss_clk),
  .tac_clk(tac_clk),.reset_n(drstn),.reset(reset),.cs(cs),.ras(ras),.cas(cas),.we(we),.cke(cke),
  .addr(addr),.ba(ba),.odt(odt),.shift(auto_shift),.shift_sel(),.shift_ena(auto_shift_ena),
  .cal_ena(1'b1),.cal_done(cal_done),.cal_pass(cal_pass),.cal_fail_log(cal_log),.cal_shift_val(cal_shift),
  .o_dm_hi(o_dm_hi),.o_dm_lo(o_dm_lo),.i_dqs_hi(i_dqs_hi),.i_dqs_lo(i_dqs_lo),
  .i_dqs_n_hi(2'd0),.i_dqs_n_lo(2'd0),.o_dqs_hi(o_dqs_hi),.o_dqs_lo(o_dqs_lo),
  .o_dqs_n_hi(),.o_dqs_n_lo(),.o_dqs_oe(o_dqs_oe),.o_dqs_n_oe(),
  .i_dq_hi(i_dq_hi),.i_dq_lo(i_dq_lo),.o_dq_hi(o_dq_hi),.o_dq_lo(o_dq_lo),.o_dq_oe(o_dq_oe),
  .axi_aid({4'd0,aid}),.axi_aaddr(aaddr),.axi_alen(alen),.axi_asize(3'd4),.axi_aburst(2'd1),
  .axi_alock(2'd0),.axi_avalid(avalid),.axi_aready(aready),.axi_atype(atype),
  .axi_wid(8'd0),.axi_wdata(wdata),.axi_wstrb(16'hffff),.axi_wlast(wlast),
  .axi_wvalid(wvalid),.axi_wready(wready),.axi_rid(),.axi_rdata(rdata),.axi_rlast(rlast),
  .axi_rvalid(rvalid),.axi_rready(rready),.axi_rresp(rresp),
  .axi_bid(),.axi_bresp(bresp),.axi_bvalid(bvalid),.axi_bready(bready));
 wire capture_write_active;wire [2:0] outer_write_diag;
 wire p_awvalid,p_awready,p_wvalid,p_wready,p_wlast,p_bvalid,p_bready;
 wire t_awvalid,t_awready,t_wvalid,t_wready,t_wlast,t_bvalid,t_bready;
 wire [31:0] p_awaddr,t_awaddr;wire [7:0] p_awlen,t_awlen;wire [127:0] p_wdata,t_wdata;
 axi_write_arbiter2 #(.PRIORITY_WINDOW(1)) u_write_mux(.clk(clk_sys),.rstn(drstn),.p_hold(capture_write_active),.diagnostic(outer_write_diag),
  .p_awvalid(p_awvalid),.p_awready(p_awready),.p_awaddr(p_awaddr),.p_awlen(p_awlen),
  .p_wvalid(p_wvalid),.p_wready(p_wready),.p_wdata(p_wdata),.p_wlast(p_wlast),.p_bvalid(p_bvalid),.p_bready(p_bready),
  .t_awvalid(t_awvalid),.t_awready(t_awready),.t_awaddr(t_awaddr),.t_awlen(t_awlen),
  .t_wvalid(t_wvalid),.t_wready(t_wready),.t_wdata(t_wdata),.t_wlast(t_wlast),.t_bvalid(t_bvalid),.t_bready(t_bready),
  .awvalid(awvalid),.awready(awready),.awaddr(awaddr),.awlen(awlen),
  .wvalid(wvalid),.wready(wready),.wdata(wdata),.wlast(wlast),.bvalid(bvalid),.bready(bready));
 wire [31:0] command;reg ack=0,protocol_error=0,pending=0;
 wire running;wire [15:0] frames;wire [31:0] read_base,read_id;wire [3:0] slots;wire pp_fault;
 wire acquire,release_frame,acquired,committed;
 wire [2:0] core_state,schedule_diag,capture_write_diag,core_read_diag,display_read_diag;
 wire [5:0] copy_diag,video_diag;wire [4:0] writer_diag;wire [1:0] bridge_diag;
 wire rgb_valid,rgb_sof,rgb_eof,frame_abort;wire [23:0] camera_rgb;
 wire configured;wire [15:0] source_frames,captured_frames,dropped_frames,overflow_frames,crop_overruns;
 wire [10:0] last_line_pixels;
 wire video_read_active,video_read_urgent;
 wire [29:0] white_balance_gains;
 wire [31:0] read_checksum;reg [31:0] checksum0=0,checksum1=0;wire [15:0] video_checksum_errors;
 wire [31:0] video_error_expected,video_error_ddr,video_error_sum,video_error_context;
 assign camera_pll_rstn_o=sys_pll_lock;
 assign csi_ctl0_o=0;assign csi_ctl0_oe=0;assign csi_ctl1_o=0;assign csi_ctl1_oe=0;
 assign {csi_rxd3_rst_o,csi_rxd2_rst_o,csi_rxd1_rst_o,csi_rxd0_rst_o}={4{!drstn}};
 generate if(!SIM_CAMERA) begin:g_camera
  camera_sc2210 u_sensor(.clk(clk_sys),.rstn(drstn && camera_pll_lock),
   .csi_scl_o(csi_scl_o),.csi_scl_oe(csi_scl_oe),.csi_sda_o(csi_sda_o),.csi_sda_oe(csi_sda_oe),.csi_sda_i(csi_sda_i),
   .csi_rxc_i(csi_rxc_i),.csi_rxc_lp_p_i(csi_rxc_lp_p_i),.csi_rxc_lp_n_i(csi_rxc_lp_n_i),
   .csi_rxd0_lp_p_i(csi_rxd0_lp_p_i),.csi_rxd0_lp_n_i(csi_rxd0_lp_n_i),
   .csi_rxd0_hs_i(csi_rxd0_hs_i),.csi_rxd1_hs_i(csi_rxd1_hs_i),.csi_rxd2_hs_i(csi_rxd2_hs_i),.csi_rxd3_hs_i(csi_rxd3_hs_i),
   .csi_rxc_hs_en_o(csi_rxc_hs_en_o),.csi_rxc_hs_term_en_o(csi_rxc_hs_term_en_o),
   .data_hs_enable({csi_rxd3_hs_en_o,csi_rxd2_hs_en_o,csi_rxd1_hs_en_o,csi_rxd0_hs_en_o}),
   .data_hs_term({csi_rxd3_hs_term_en_o,csi_rxd2_hs_term_en_o,csi_rxd1_hs_term_en_o,csi_rxd0_hs_term_en_o}),
   .configured(configured),.rgb_valid(rgb_valid),.rgb_sof(rgb_sof),.rgb_eof(rgb_eof),.frame_abort(frame_abort),.rgb(camera_rgb),
   .source_frames(source_frames),.overruns(crop_overruns),.last_line_pixels(last_line_pixels),.white_balance_gains(white_balance_gains));
 end else begin:g_sim
  reg inject_valid=0,inject_sof=0,inject_eof=0,inject_abort=0;reg [23:0] inject_rgb=0;
  assign rgb_valid=inject_valid;assign rgb_sof=inject_sof;assign rgb_eof=inject_eof;assign frame_abort=inject_abort;assign camera_rgb=inject_rgb;
  assign configured=1;assign source_frames=0;assign crop_overruns=0;assign last_line_pixels=1920;
  assign white_balance_gains={10'd256,10'd256,10'd256};
  assign {csi_scl_o,csi_scl_oe,csi_sda_o,csi_sda_oe}=4'b0100;
  assign {csi_rxc_hs_en_o,csi_rxc_hs_term_en_o}=0;
  assign {csi_rxd3_hs_en_o,csi_rxd2_hs_en_o,csi_rxd1_hs_en_o,csi_rxd0_hs_en_o}=0;
  assign {csi_rxd3_hs_term_en_o,csi_rxd2_hs_term_en_o,csi_rxd1_hs_term_en_o,csi_rxd0_hs_term_en_o}=0;
 end endgenerate
 wire i_awvalid,i_awready,i_wvalid,i_wready,i_wlast,i_bvalid,i_bready;
 wire [31:0] i_awaddr;wire [7:0] i_awlen;wire [127:0] i_wdata;
 camera_frame_pingpong #(.HOLD_CAPTURE(0)) u_pp(.clk(clk_sys),.rstn(drstn),.enable(enable && configured),
  .s_valid(rgb_valid),.s_sof(rgb_sof),.s_eof(rgb_eof),.s_abort(frame_abort),.s_rgb(camera_rgb),
  .acquire(acquire),.release_frame(release_frame),.acquired(acquired),.committed(committed),
  .read_base(read_base),.read_id(read_id),.read_checksum(read_checksum),.slots(slots),.write_active(capture_write_active),.fault(pp_fault),
  .captured_frames(captured_frames),.dropped_frames(dropped_frames),.overflow_frames(overflow_frames),
  .awvalid(i_awvalid),.awready(i_awready),.awaddr(i_awaddr),.awlen(i_awlen),
  .wvalid(i_wvalid),.wready(i_wready),.wdata(i_wdata),.wlast(i_wlast),.bvalid(i_bvalid),.bresp(bresp),.bready(i_bready));
 wire cp_awvalid,cp_awready,cp_wvalid,cp_wready,cp_wlast,cp_bvalid,cp_bready;
 wire cp_arvalid,cp_arready,cp_rvalid,cp_rready,cp_rlast;
 wire [31:0] cp_awaddr,cp_araddr;wire [7:0] cp_awlen,cp_arlen;wire [127:0] cp_wdata,cp_rdata;
 wire copy_start,copy_done,copy_busy,copy_fault,output_bank_ready;wire [31:0] copy_destination,styled_write_base,total_cycles;
 reg [31:0] copy_cycles=0;
 always @(posedge clk_sys) if(!drstn || copy_start) copy_cycles<=0;else if(copy_busy) copy_cycles<=copy_cycles+1;
 camera_frame_copy u_copy(.clk(clk_sys),.rstn(drstn),.start(copy_start),.source_base(read_base),.destination_base(copy_destination),
  .busy(copy_busy),.done(copy_done),.fault(copy_fault),.diagnostic(copy_diag),.arvalid(cp_arvalid),.arready(cp_arready),.araddr(cp_araddr),.arlen(cp_arlen),
  .rvalid(cp_rvalid),.rready(cp_rready),.rdata(cp_rdata),.rlast(cp_rlast),.rresp(rresp),
  .awvalid(cp_awvalid),.awready(cp_awready),.awaddr(cp_awaddr),.awlen(cp_awlen),
  .wvalid(cp_wvalid),.wready(cp_wready),.wdata(cp_wdata),.wlast(cp_wlast),.bvalid(cp_bvalid),.bresp(bresp),.bready(cp_bready));
 axi_write_arbiter2 #(.PRIORITY_WINDOW(1)) u_capture_copy_mux(.clk(clk_sys),.rstn(drstn),.p_hold(capture_write_active),.diagnostic(capture_write_diag),
  .p_awvalid(i_awvalid),.p_awready(i_awready),.p_awaddr(i_awaddr),.p_awlen(i_awlen),
  .p_wvalid(i_wvalid),.p_wready(i_wready),.p_wdata(i_wdata),.p_wlast(i_wlast),.p_bvalid(i_bvalid),.p_bready(i_bready),
  .t_awvalid(cp_awvalid),.t_awready(cp_awready),.t_awaddr(cp_awaddr),.t_awlen(cp_awlen),
  .t_wvalid(cp_wvalid),.t_wready(cp_wready),.t_wdata(cp_wdata),.t_wlast(cp_wlast),.t_bvalid(cp_bvalid),.t_bready(cp_bready),
  .awvalid(p_awvalid),.awready(p_awready),.awaddr(p_awaddr),.awlen(p_awlen),
  .wvalid(p_wvalid),.wready(p_wready),.wdata(p_wdata),.wlast(p_wlast),.bvalid(p_bvalid),.bready(p_bready));
 reg [2:0] control=0;wire key_style,key_pressed;
 camera_key u_key(.clk(clk_sys),.rstn(drstn),.key_n(key_data[0]),.style(key_style),.pressed(key_pressed));
 wire requested_style=control[0] ? control[1] : key_style;
 wire ready_toggle,ready_slot,frame_ack_toggle,active_slot,active_style,schedule_start;
 reg run_toggle=0,run_s1=0,run_s2=0,run_seen=0,core_start=0,complete_toggle=0,done_s1=0,done_s2=0,done_seen=0;
 wire completed_event=done_s2!=done_seen;
 always @(posedge clk_sys) begin
  if(!drstn) begin checksum0<=0;checksum1<=0;end
  else if(copy_start) begin
   if(copy_destination==32'h900000) checksum1<=read_checksum<<2;
   else checksum0<=read_checksum<<2;
  end
 end
 always @(posedge clk_sys) begin
  if(!drstn) begin run_toggle<=0;done_s1<=0;done_s2<=0;done_seen<=0;end
  else begin
   if(schedule_start) run_toggle<=~run_toggle;
   done_s1<=complete_toggle;done_s2<=done_s1;done_seen<=done_s2;
  end
 end
 camera_schedule u_schedule(.clk(clk_sys),.rstn(drstn),.state_debug(schedule_diag),.enable(enable && !control[2]),.input_slots(slots),
  .acquired(acquired),.read_base(read_base),.acquire(acquire),.release_frame(release_frame),
  .copy_start(copy_start),.copy_done(copy_done),.copy_destination(copy_destination),
  .core_start(schedule_start),.core_done(completed_event),.running(running),.processed_frames(frames),
  .ready_toggle(ready_toggle),.ready_slot(ready_slot),.frame_ack_toggle(frame_ack_toggle),
  .styled_write_base(styled_write_base),.output_bank_ready(output_bank_ready),.total_cycles(total_cycles));
 wire [3:0] blocks_completed;wire [10:0] residual_output_base;
 wire [31:0] encoder_cycles,residual_cycles,block_cycles,decode_cycles,layer_cycles,output_cycles;
 wire [31:0] command_wait_cycles,data_wait_cycles,input_checksum;
 wire [1:0] layers_completed;wire output_completed;
 wire [31:0] progress={12'd0,residual_output_base,blocks_completed,4'd0,1'b0};
 wire core_busy,core_done,core_fault,network_fault,writer_fault;
 assign core_state={1'b0,output_completed,core_busy};assign writer_diag=0;assign bridge_diag=0;
 wire feature_write_valid,feature_write_ready,writer_ready;wire [31:0] feature_write_addr;wire [399:0] feature_write_data;
 // Backpressure only final outputs until the paired original copy is complete.
 // Encoder/residual work and intermediate feature writes can overlap VSYNC.
 reg bank_ready_c1=0,bank_ready_c2=0;
 always @(posedge clk_compute) if(!crstn) begin bank_ready_c1<=0;bank_ready_c2<=0;end
 else begin bank_ready_c1<=output_bank_ready;bank_ready_c2<=bank_ready_c1;end
 wire output_write_allowed=feature_write_addr[31:20]!=12'h006 || bank_ready_c2;
 assign feature_write_ready=writer_ready && output_write_allowed;
 // Workspaces 3/4/5 MiB are fixed; only final output maps to the free display bank.
 wire [31:0] output_address=feature_write_addr[31:20]==12'h006 ?
    {styled_write_base[31:20],feature_write_addr[19:0]} : feature_write_addr;
 assign core_fault=network_fault || writer_fault || copy_fault;
 cyclegan_feature_writer u_output(.cclk(clk_compute),.crstn(crstn),.s_valid(feature_write_valid && output_write_allowed),.s_ready(writer_ready),
  .s_addr(output_address),.s_data(feature_write_data),.fault(writer_fault),.dclk(clk_sys),.drstn(drstn),.enable(enable),
  .awvalid(t_awvalid),.awready(t_awready),.awaddr(t_awaddr),.awlen(t_awlen),
  .wvalid(t_wvalid),.wready(t_wready),.wdata(t_wdata),.wlast(t_wlast),.bvalid(t_bvalid),.bresp(bresp),.bready(t_bready));
 wire [31:0] cycles,mac_cycles,first_cycle;
 reg [31:0] debug_address=0;reg [511:0] read_hold=0;reg [4:0] metric_index=0;
 // The bundled payload is held until another debug read completes. The
 // synchronized completion toggle gates its JTAG acknowledgement, so a
 // second 512-bit system-clock copy is unnecessary.
 wire [511:0] read_data=read_hold;
 reg quality_active=0;reg [3:0] quality_index=0;
 wire [31:0] block_metric=quality_active ? (quality_index==0 ? {2'd0,white_balance_gains} :
  quality_index==1 ? checksum0 : quality_index==2 ? checksum1 : quality_index==3 ? video_error_expected :
  quality_index==4 ? video_error_ddr : quality_index==5 ? video_error_sum : video_error_context) :
  metric_index==0 ? command_wait_cycles : metric_index==1 ? data_wait_cycles :
  metric_index==2 ? input_checksum : metric_index==3 ? block_cycles : metric_index==4 ? layer_cycles :
  metric_index==5 ? {29'd0,output_completed,layers_completed} : metric_index<12 ? 32'd0 : metric_index==12 ? decode_cycles :
  metric_index==13 ? 32'd0 : metric_index==14 ? output_cycles : metric_index==15 ? 32'd0 :
  metric_index==16 ? {16'd0,video_frames} : metric_index==17 ? {16'd0,video_underflows} :
  metric_index==18 ? video_lines : metric_index==19 ? {26'd0,active_slot,active_style,video_pll_lock,frames!=0,!running,video_fault} :
  metric_index==20 ? video_sum : metric_index==21 ? {16'd0,source_frames} :
  metric_index==22 ? {16'd0,captured_frames} : metric_index==23 ? {16'd0,dropped_frames} :
  metric_index==24 ? {overflow_frames,crop_overruns} : metric_index==25 ? {16'd0,frames} :
  metric_index==26 ? {19'd0,control,configured,key_style,requested_style,ready_slot,ready_toggle,frame_ack_toggle,slots} :
  metric_index==27 ? total_cycles : metric_index==28 ? copy_cycles : metric_index==29 ? {5'd0,video_checksum_errors,last_line_pixels} :
  metric_index==30 ? {5'd0,core_state,schedule_diag,copy_diag[5:3],writer_diag[4:3],bridge_diag,video_diag[5:3],
   outer_write_diag[2:1],capture_write_diag[2:1],core_read_diag[2:1],display_read_diag[2:1],mux_diag} :
  {6'd0,copy_diag[2:0],writer_diag[2:0],video_diag[2:0],core_read_diag[0],display_read_diag[0],capture_write_diag[0],outer_write_diag[0],
   video_read_active,capture_write_active,arvalid,arready,rvalid,rready,rlast,awvalid,awready,wvalid,wready,bvalid,bready};
 wire req_valid,req_ready,rsp_valid,rsp_ready;wire [31:0] req_addr;wire [2:0] req_beats;
 wire [511:0] rsp_data;wire bridge_fault;reg [2:0] debug_state=0;
 wire bridge_req_valid=debug_state==3 ? 1'b1 : req_valid;wire bridge_req_ready;
 wire bridge_rsp_ready=debug_state==4 ? 1'b1 : rsp_ready;
 assign req_ready=debug_state==0 && bridge_req_ready;
 cyclegan_ddr_read_bridge u_bridge(.cclk(clk_compute),.crstn(crstn),.req_valid(bridge_req_valid),.req_ready(bridge_req_ready),
  .req_addr(debug_state==3 ? debug_address : req_addr),.req_beats(debug_state==3 ? 3'd4 : req_beats),
  .rsp_valid(rsp_valid),.rsp_ready(bridge_rsp_ready),.rsp_data(rsp_data),.fault(bridge_fault),
  .dclk(clk_sys),.drstn(drstn),.enable(enable),.arvalid(br_arvalid),.arready(br_arready),
  .araddr(br_araddr),.arlen(br_arlen),.rvalid(br_rvalid),.rready(br_rready),.rdata(br_rdata),.rlast(br_rlast),.rresp(rresp));
 wire x_arvalid,x_arready,x_rvalid,x_rready,x_rlast;
 wire [31:0] x_araddr;wire [7:0] x_arlen;wire [127:0] x_rdata;
 axi_read_arbiter2 u_core_copy_read(.clk(clk_sys),.rstn(drstn),.diagnostic(core_read_diag),
  .p_valid(br_arvalid),.p_ready(br_arready),.p_addr(br_araddr),.p_len(br_arlen),.p_rvalid(br_rvalid),.p_rready(br_rready),.p_data(br_rdata),.p_last(br_rlast),
  .v_valid(cp_arvalid),.v_ready(cp_arready),.v_addr(cp_araddr),.v_len(cp_arlen),.v_rvalid(cp_rvalid),.v_rready(cp_rready),.v_data(cp_rdata),.v_last(cp_rlast),
  .arvalid(x_arvalid),.arready(x_arready),.araddr(x_araddr),.arlen(x_arlen),.rvalid(x_rvalid),.rready(x_rready),.rdata(x_rdata),.rlast(x_rlast));
 assign video_pll_rstn_o=sys_pll_lock;reg [15:0] video_reset=0;
 always @(posedge clk_video) if(!video_pll_lock) video_reset<=0;else video_reset<={video_reset[14:0],1'b1};
 assign {hdmi_txc_oe,hdmi_txd0_oe,hdmi_txd1_oe,hdmi_txd2_oe}=4'b1111;
 assign {hdmi_txc_rst_o,hdmi_txd0_rst_o,hdmi_txd1_rst_o,hdmi_txd2_rst_o}={4{!video_reset[15]}};
 wire va,vr,vv,vready,vlast;wire [31:0] vaddr;wire [7:0] vlen;wire [127:0] vdata;
 axi_read_arbiter2 #(.VIDEO_WINDOW(1)) u_display_read(.clk(clk_sys),.rstn(drstn),.v_hold(video_read_urgent),.diagnostic(display_read_diag),
  .p_valid(x_arvalid),.p_ready(x_arready),.p_addr(x_araddr),.p_len(x_arlen),.p_rvalid(x_rvalid),.p_rready(x_rready),.p_data(x_rdata),.p_last(x_rlast),
  .v_valid(va),.v_ready(vr),.v_addr(vaddr),.v_len(vlen),.v_rvalid(vv),.v_rready(vready),.v_data(vdata),.v_last(vlast),
  .arvalid(arvalid),.arready(arready),.araddr(araddr),.arlen(arlen),.rvalid(rvalid),.rready(rready),.rdata(rdata),.rlast(rlast));
 camera_hdmi #(.CHECK_ORIGINAL_SUM(1)) u_display(.dclk(clk_sys),.drstn(drstn),.pclk(clk_video),.prstn(video_reset[15]),.diagnostic(video_diag),
  .checksum0(checksum0),.checksum1(checksum1),.checksum_errors(video_checksum_errors),
  .error_expected_sum(video_error_expected),.error_ddr_sum(video_error_ddr),
  .error_video_sum(video_error_sum),.error_context(video_error_context),
  .frame_ready_toggle(ready_toggle),.frame_slot(ready_slot),.select_style(requested_style),.frame_ack_toggle(frame_ack_toggle),
  .active_slot(active_slot),.active_style(active_style),.arvalid(va),.read_active(video_read_active),.read_urgent(video_read_urgent),.arready(vr),.araddr(vaddr),.arlen(vlen),
  .rvalid(vv),.rready(vready),.rdata(vdata),.rlast(vlast),.rresp(rresp),
  .txc(hdmi_txc_o),.txd0(hdmi_txd0_o),.txd1(hdmi_txd1_o),.txd2(hdmi_txd2_o),
  .loaded_lines(video_lines),.fault(video_fault),.displayed_frames(video_frames),.underflows(video_underflows),.pixel_sum(video_sum));
 cyclegan_encoder #(.RESIDUAL_ENABLE(1),.DECODER_ENABLE(1),.OUTPUT_ENABLE(1)) u_core(
  .clk(clk_compute),.rstn(crstn),.start(core_start),.frame_base(read_base),
  .busy(core_busy),.done(core_done),.fault(network_fault),.cycles(cycles),.mac_cycles(mac_cycles),
  .first_output_cycle(first_cycle),.req_valid(req_valid),.req_ready(req_ready),.req_addr(req_addr),
  .req_beats(req_beats),.rsp_valid(rsp_valid && debug_state==0),.rsp_ready(rsp_ready),.rsp_data(rsp_data),
  .command_wait_cycles(command_wait_cycles),.data_wait_cycles(data_wait_cycles),.input_checksum(input_checksum),
  .dbg_rd(1'b0),.dbg_addr(11'd0),.dbg_data(),.dbg_valid(),
  .pause_each_block(1'b0),.resume(1'b0),.paused(),.blocks_completed(blocks_completed),
  .residual_output_base(residual_output_base),.encoder_cycles(encoder_cycles),.residual_cycles(residual_cycles),.block_cycles(block_cycles),
  .decoder_cycles(decode_cycles),.layer_cycles(layer_cycles),.layers_completed(layers_completed),
  .output_completed(output_completed),.output_cycles(output_cycles),
  .feature_write_valid(feature_write_valid),.feature_write_ready(feature_write_ready),.feature_write_addr(feature_write_addr),.feature_write_data(feature_write_data),
  .raw_rows(),.stage1_rows(),.stage2_rows(),.stage3_rows());

 reg debug_toggle=0,debug_s1=0,debug_s2=0,debug_seen=0,debug_complete=0,dbg_done1=0,dbg_done2=0,dbg_seen=0;
 always @(posedge clk_compute) begin
  core_start<=0;
  if(!crstn) begin
   run_s1<=0;run_s2<=0;run_seen<=0;complete_toggle<=0;debug_s1<=0;debug_s2<=0;debug_seen<=0;debug_complete<=0;debug_state<=0;read_hold<=0;
  end else begin
   run_s1<=run_toggle;run_s2<=run_s1;debug_s1<=debug_toggle;debug_s2<=debug_s1;
   if(run_s2!=run_seen) begin run_seen<=run_s2;core_start<=1;end
   if(core_done) complete_toggle<=~complete_toggle;
   case(debug_state)
    0:if(debug_s2!=debug_seen) begin debug_seen<=debug_s2;debug_state<=3;end
    3:if(bridge_req_ready) debug_state<=4;
    4:if(rsp_valid) begin read_hold<=rsp_data;debug_complete<=~debug_complete;debug_state<=0;end
   endcase
  end
 end
 always @(posedge clk_sys) begin
  if(!drstn) begin ack<=0;protocol_error<=0;pending<=0;control<=0;debug_toggle<=0;debug_address<=0;metric_index<=0;quality_active<=0;quality_index<=0;dbg_done1<=0;dbg_done2<=0;dbg_seen<=0;end
  else begin
   dbg_done1<=debug_complete;dbg_done2<=dbg_done1;
   if(!pending && command[31]!=ack) begin
    case(command[30:28])
     3:begin control<=command[2:0];protocol_error<=0;ack<=command[31];end
     4:begin quality_active<=1;quality_index<=command[3:0];protocol_error<=0;ack<=command[31];end
     5:begin quality_active<=0;metric_index<=command[4:0];protocol_error<=0;ack<=command[31];end
     6:if(control[2] && !running) begin debug_address<={4'd0,command[23:0],4'd0};debug_toggle<=~debug_toggle;pending<=1;end
       else begin protocol_error<=1;ack<=command[31];end
     default:begin protocol_error<=1;ack<=command[31];end
    endcase
   end
   if(pending && dbg_done2!=dbg_seen) begin dbg_seen<=dbg_done2;ack<=command[31];pending<=0;end
  end
 end
 wire [15:0] chunks=0;
 wire [31:0] status={16'he316,cal_done,cal_pass,protocol_error,pp_fault,bridge_fault,core_fault,running,ack,slots,configured,1'b0,requested_style,video_fault};
 edb_top u_debug(.bscan_CAPTURE(bscan_CAPTURE),.bscan_DRCK(bscan_DRCK),.bscan_RESET(bscan_RESET),
  .bscan_RUNTEST(bscan_RUNTEST),.bscan_SEL(bscan_SEL),.bscan_SHIFT(bscan_SHIFT),.bscan_TCK(bscan_TCK),
  .bscan_TDI(bscan_TDI),.bscan_TMS(bscan_TMS),.bscan_UPDATE(bscan_UPDATE),.bscan_TDO(bscan_TDO),.vio0_clk(clk_sys),
  .vio0_status(status),.vio0_cycles(cycles),.vio0_mac_cycles(mac_cycles),.vio0_first_cycle(first_cycle),
  .vio0_encoder_cycles(encoder_cycles),.vio0_residual_cycles(residual_cycles),.vio0_progress(progress),
  
  .vio0_counts({frames,chunks}),.vio0_frame_id(read_id),.vio0_calibration({18'd0,phase_applied,3'd6,cal_shift,cal_log}),
  .vio0_read_data0(read_data[255:0]),.vio0_read_data1(read_data[511:256]),.vio0_block_metric(block_metric),
  .vio0_command(command));
endmodule
