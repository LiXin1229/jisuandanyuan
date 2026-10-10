// Residual-channel statistics sidecar. Four pixels/clock, no tile copy:
// postprocess holds its Q4.4 tile until the next convolution completes.
// Each channel is twelve 10x10 tiles; coefficient work overlaps later channels.
module mn_instance_norm(
 input wire clk,rstn,clear,input wire [4:0] point,
 input wire [9:0] tiles_per_channel,input wire [16:0] sample_count,
 input wire tile_valid,input wire [799:0] tile_data,
 output wire sample_idle,output reg fault,
 input wire [4:0] query_channel,output wire coefficient_ready,
 input wire rd_en,input wire [5:0] rd_addr,output wire [15:0] rd_data
);
 reg scanning;
 reg [4:0] group_index,channel;
 reg [9:0] tile_index;
 reg signed [24:0] total;
 reg [30:0] squares;
 wire signed [7:0] pixel[0:3];
 reg [15:0] square[0:3];
 genvar lane;
 generate for(lane=0;lane<4;lane=lane+1) begin:g_lane
  assign pixel[lane]=$signed(tile_data[(group_index*4+lane)*8+:8]);
  // Registered 8x8 square maps to one DSP per lane; the main 100 PEs are untouched.
  always @(posedge clk) if(scanning) square[lane]<=pixel[lane]*pixel[lane];
 end endgenerate
 wire signed [10:0] group_sum=$signed({{3{pixel[0][7]}},pixel[0]})+
  $signed({{3{pixel[1][7]}},pixel[1]})+$signed({{3{pixel[2][7]}},pixel[2]})+
  $signed({{3{pixel[3][7]}},pixel[3]});
 wire [17:0] group_squares={2'd0,square[0]}+{2'd0,square[1]}+
  {2'd0,square[2]}+{2'd0,square[3]};
 reg square_valid,square_last;
 wire signed [24:0] next_total=total+group_sum;
 wire [30:0] next_squares=squares+group_squares;
 reg [31:0] ready_channels;
 assign coefficient_ready=ready_channels[query_channel];
 assign sample_idle=!scanning && !square_valid;
 reg [2:0] request_state;
 localparam FREE=0,GAMMA=1,BETA=2,START=3,WAIT=4,WRITE_B=5,LATCH=6;
 reg [4:0] request_channel;
 reg signed [24:0] request_total;
 reg [30:0] request_squares;
 reg signed [15:0] gamma,beta;
 wire [15:0] gamma_data;
 wire [10:0] gamma_base=point==0 ? 0 : point==1 ? 16 : point==2 ? 32 : point==3 ? 64 : point==4 ? 96 :
  point<23 ? 160+((point-5)<<6) : point==23 ? 1312 : point==24 ? 1344 : 1360;
 wire [10:0] gamma_addr=gamma_base+{5'd0,request_channel,1'b0}+(request_state==BETA);
 mn_instance_norm_gamma gamma_rom(.clk(clk),.rd_en(request_state==GAMMA || request_state==BETA),.addr(gamma_addr),.data(gamma_data));
 wire coeff_busy,coeff_done,coeff_fault;
 wire signed [15:0] a,b;
 generator_norm_coeff coefficient(.clk(clk),.rstn(rstn && !clear),.start(request_state==LATCH),
  .count(sample_count),.total(request_total),.squares(request_squares),.gamma(gamma),.beta(beta),
  .busy(coeff_busy),.done(coeff_done),.fault(coeff_fault),.a(a),.b(b));
 wire write_a=request_state==WAIT && coeff_done && !coeff_fault;
 wire write_b=request_state==WRITE_B;
 wire [8:0] write_addr={3'd0,request_channel,write_b};
 EFX_RAM10 #(.READ_WIDTH(16),.WRITE_WIDTH(16),.OUTPUT_REG(0)) coefficients(
  .RCLK(clk),.RE(rd_en),.RST(1'b0),.RADDREN(1'b1),.RADDR({3'd0,rd_addr}),.RDATA(rd_data),
  .WCLK(clk),.WCLKE(1'b1),.WADDREN(1'b1),.WE({2{write_a || write_b}}),.WADDR(write_addr),.WDATA(write_b ? b : a));
 always @(posedge clk) begin
  if(!rstn || clear) begin
   scanning<=0;group_index<=0;tile_index<=0;channel<=0;total<=0;squares<=0;
   square_valid<=0;square_last<=0;ready_channels<=0;fault<=0;request_state<=FREE;
   request_channel<=0;request_total<=0;request_squares<=0;gamma<=0;beta<=0;
  end else begin
   square_valid<=scanning;square_last<=scanning && group_index==24;
   if(tile_valid) begin
    if(!sample_idle) fault<=1;
    scanning<=1;group_index<=0;
   end
   if(scanning) begin
    total<=next_total;
    if(group_index==24) scanning<=0;else group_index<=group_index+1'b1;
   end
   if(square_valid) begin
    squares<=next_squares;
    if(square_last) begin
     if(tile_index==tiles_per_channel-1'b1) begin
      if(request_state!=FREE) fault<=1;
      request_channel<=channel;request_total<=total;request_squares<=next_squares;
      request_state<=GAMMA;channel<=channel+1'b1;tile_index<=0;total<=0;squares<=0;
     end else tile_index<=tile_index+1'b1;
    end
   end
   case(request_state)
    GAMMA:request_state<=BETA;
    BETA:begin gamma<=gamma_data;request_state<=START;end
    START:begin beta<=gamma_data;request_state<=LATCH;end
    LATCH:request_state<=WAIT;
    WAIT:if(coeff_done) begin
     if(coeff_fault) begin fault<=1;request_state<=FREE;end
     else request_state<=WRITE_B;
    end
    WRITE_B:begin ready_channels[request_channel]<=1;request_state<=FREE;end
    default:;
   endcase
  end
 end
endmodule
