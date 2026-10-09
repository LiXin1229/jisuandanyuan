`timescale 1ns/1ps
// Preserve the supplied SC2210 register table, lane polarity, bit order and PHY.
module camera_sc2210(input wire clk,rstn,
 output wire csi_scl_o,csi_scl_oe,csi_sda_o,csi_sda_oe,input wire csi_sda_i,
 input wire csi_rxc_i,csi_rxc_lp_p_i,csi_rxc_lp_n_i,
 input wire csi_rxd0_lp_p_i,csi_rxd0_lp_n_i,
 input wire [7:0] csi_rxd0_hs_i,csi_rxd1_hs_i,csi_rxd2_hs_i,csi_rxd3_hs_i,
 output wire csi_rxc_hs_en_o,csi_rxc_hs_term_en_o,
 output wire [3:0] data_hs_enable,data_hs_term,
 output wire configured,rgb_valid,rgb_sof,rgb_eof,frame_abort,
 output wire [23:0] rgb,output wire [15:0] source_frames,overruns,
 output wire [10:0] last_line_pixels,output wire [29:0] white_balance_gains);
 wire [8:0] index,size;wire [23:0] configuration;
 I2C_SC2210_19201080_4Lanes_Config u_table(.LUT_INDEX(index),.LUT_DATA(configuration),.LUT_SIZE(size));
 i2c_timing_ctrl_reg16_dat8_wronly #(.CLK_FREQ(96000000),.I2C_FREQ(50000)) u_i2c(
  .clk(clk),.rst_n(rstn),.i2c_sclk(csi_scl_o),.i2c_sdat_IN(csi_sda_i),
  .i2c_sdat_OUT(csi_sda_o),.i2c_sdat_OE(csi_sda_oe),.i2c_config_index(index),
  .i2c_config_data({8'h60,configuration}),.i2c_config_size(size),.i2c_config_done(configured));
 assign csi_scl_oe=1;
 wire [7:0] lane[0:3],incoming[0:3];
 assign incoming[0]=csi_rxd0_hs_i;assign incoming[1]=csi_rxd1_hs_i;
 assign incoming[2]=csi_rxd2_hs_i;assign incoming[3]=csi_rxd3_hs_i;
 // Sample PHY bytes on the opposite edge before positive-edge packet decoding.
 // This separates the PHY byte transition from the fabric sampling edge.
 (* syn_preserve=1 *) reg [7:0] sampled[0:3];
 integer lane_index;
 always @(negedge csi_rxc_i)
  for(lane_index=0;lane_index<4;lane_index=lane_index+1) sampled[lane_index]<=incoming[lane_index];
 genvar g,b;generate for(g=0;g<4;g=g+1) begin:g_lane
  for(b=0;b<8;b=b+1) begin:g_bit assign lane[g][b]=~sampled[g][7-b];end
 end endgenerate
 wire rxclk,de;wire [3:0] fv,lv;wire [47:0] data;
 wire hs_enable,hs_term;
 MIPIRx4LaneFre u_rx(.sclk_i(clk),.srst_i(!rstn),.mipi_rx_byteclk_i(csi_rxc_i),
  .mipi_rx_d0_i(lane[0]),.mipi_rx_d1_i(lane[1]),.mipi_rx_d2_i(lane[2]),.mipi_rx_d3_i(lane[3]),
  .mipi_rx_clk_lp_p_i(csi_rxc_lp_p_i),.mipi_rx_clk_lp_n_i(csi_rxc_lp_n_i),
  .mipi_rx_d0_lp_p_i(csi_rxd0_lp_n_i),.mipi_rx_d0_lp_n_i(csi_rxd0_lp_p_i),
  .mipi_rx_clk_hs_en_o(csi_rxc_hs_en_o),.mipi_rx_dat_hs_en_o(hs_enable),
  .mipi_rx_clk_term_en_o(csi_rxc_hs_term_en_o),.mipi_rx_dat_term_en_o(hs_term),
  .CLK(rxclk),.VSYNC(fv),.HSYNC(lv),.DE(de),.DAT(data));
 assign data_hs_enable={4{hs_enable}};assign data_hs_term={4{hs_term}};
 reg conf1=0,conf2=0,crop_armed=0;reg [15:0] reset_pipe=0;
 always @(posedge rxclk) begin
  conf1<=configured;conf2<=conf1;
  if(!rstn) begin conf1<=0;conf2<=0;crop_armed<=0;reset_pipe<=0;end
  else begin
   reset_pipe<={reset_pipe[14:0],1'b1};
   if(conf2 && !fv[0]) crop_armed<=1;
  end
 end
 wire raw_valid,raw_sof,raw_eof;wire [23:0] raw_rgb;
 camera_crop_bayer u_crop(.cclk(rxclk),.crstn(reset_pipe[15] && crop_armed),
  .frame_valid(fv[0]),.line_valid(lv[0]),.pixels_valid(de),
  .pixels({data[47:40],data[35:28],data[23:16],data[11:4]}),.dclk(clk),.drstn(rstn),
  .rgb_valid(raw_valid),.rgb_sof(raw_sof),.rgb_eof(raw_eof),.frame_abort(frame_abort),.rgb(raw_rgb),
  .source_frames(source_frames),.overruns(overruns),.last_line_pixels(last_line_pixels));
 wire isp_valid,isp_sof,isp_eof;wire [23:0] isp_rgb;
 camera_isp u_isp(.clk(clk),.rstn(rstn),.s_valid(raw_valid),.s_sof(raw_sof),.s_eof(raw_eof),.s_rgb(raw_rgb),
  .m_valid(isp_valid),.m_sof(isp_sof),.m_eof(isp_eof),.m_rgb(isp_rgb),
  .gain_r(white_balance_gains[29:20]),.gain_g(white_balance_gains[19:10]),.gain_b(white_balance_gains[9:0]));
 camera_pool2x2 u_pool(.clk(clk),.rstn(rstn),.abort(frame_abort),
  .s_valid(isp_valid),.s_sof(isp_sof),.s_eof(isp_eof),.s_rgb(isp_rgb),
  .m_valid(rgb_valid),.m_sof(rgb_sof),.m_eof(rgb_eof),.m_rgb(rgb));
endmodule
