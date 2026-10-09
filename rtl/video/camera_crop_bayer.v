`timescale 1ns/1ps
// Four RAW8 samples/CSI clock. Three rows retain the centered ROI and RAW halo.
// A serial system-clock bilinear pipeline completes a line without DDR stalls.
module camera_crop_bayer #(parameter RED_X=1,RED_Y=1,WIDTH=640,HEIGHT=480)(
 input wire cclk,crstn,frame_valid,line_valid,pixels_valid,input wire [31:0] pixels,
 input wire dclk,drstn,
 output reg rgb_valid=0,rgb_sof=0,rgb_eof=0,frame_abort=0,output reg [23:0] rgb=0,
 output reg [15:0] source_frames=0,overruns=0,output reg [10:0] last_line_pixels=0);
 localparam X0=(1920-WIDTH)/2,Y0=(1080-HEIGHT)/2;
 localparam FIRST_WORD=X0/4-1,LAST_WORD=(X0+WIDTH)/4;
 localparam DEPTH=WIDTH>504 ? 256 : 128,AW=$clog2(DEPTH),PW=$clog2(WIDTH+8);
 reg line_old=0,frame_old=0;reg [8:0] group_x=0;reg [10:0] y=0;
 reg [1:0] bank=0,done_bank=0;reg [10:0] done_y=0;reg row_toggle=0,source_toggle=0;
 wire crop_word=frame_valid && line_valid && pixels_valid && y>=Y0-1 && y<=Y0+HEIGHT && group_x>=FIRST_WORD && group_x<=LAST_WORD;
 wire [AW-1:0] write_word=group_x-FIRST_WORD;
 reg [PW-1:0] walk_x=0,walk_d=0;reg walking=0,valid_d=0;
 reg [1:0] bottom=0;reg [10:0] row_y=0;reg sync1=0,sync2=0,seen=0,fs1=0,fs2=0,fs_seen=0;
 wire [31:0] row_q[0:2];genvar g;
 generate for(g=0;g<3;g=g+1) begin:g_raw_line
  (* syn_ramstyle="block_ram" *) reg [31:0] ram[0:DEPTH-1];reg [31:0] q;
  always @(posedge cclk) if(crop_word && bank==g) ram[write_word]<=pixels;
  always @(posedge dclk) q<=ram[walk_x[PW-1:2]];
  assign row_q[g]=q;
 end endgenerate
 reg [10:0] line_pixels_hold=0;
 always @(posedge cclk) begin
  line_old<=line_valid;frame_old<=frame_valid;
  if(!crstn) begin
   line_old<=0;frame_old<=0;group_x<=0;y<=0;bank<=0;done_bank<=0;done_y<=0;
   row_toggle<=0;source_toggle<=0;line_pixels_hold<=0;
  end else begin
   if(frame_valid && !frame_old) source_toggle<=~source_toggle;
   if(!frame_valid) begin group_x<=0;y<=0;bank<=0;end
   else begin
    if(line_valid && pixels_valid) group_x<=group_x+1;
    if(line_old && !line_valid) begin line_pixels_hold<={group_x,2'd0};group_x<=0;y<=y+1;end
    if(crop_word && group_x==LAST_WORD) begin
     done_bank<=bank;done_y<=y;row_toggle<=~row_toggle;
     if(bank==2) bank<=0;else bank<=bank+1;
    end
   end
  end
 end
 wire [1:0] middle=bottom==0 ? 2 : bottom-1;
 wire [1:0] top=bottom==2 ? 0 : bottom+1;
 wire [7:0] a=row_q[top][walk_d[1:0]*8+:8];
 wire [7:0] b=row_q[middle][walk_d[1:0]*8+:8];
 wire [7:0] c=row_q[bottom][walk_d[1:0]*8+:8];
 reg [7:0] a_l2=0,a_l1=0,b_l2=0,b_l1=0,c_l2=0,c_l1=0;
 wire [9:0] cross_sum={2'd0,a_l1}+{2'd0,b_l2}+{2'd0,b}+{2'd0,c_l1};
 wire [9:0] corner_sum={2'd0,a_l2}+{2'd0,a}+{2'd0,c_l2}+{2'd0,c};
 wire [8:0] horizontal={1'b0,b_l2}+{1'b0,b};
 wire [8:0] vertical={1'b0,a_l1}+{1'b0,c_l1};
 wire center_x_odd=walk_d[0] ^ ((X0-5)&1),center_y_odd=!row_y[0];
 reg [7:0] red_value,green_value,blue_value;
 always @* begin
  if(center_x_odd==RED_X && center_y_odd==RED_Y) begin
   red_value=b_l1;green_value=cross_sum[9:2];blue_value=corner_sum[9:2];
  end else if(center_x_odd!=RED_X && center_y_odd!=RED_Y) begin
   red_value=corner_sum[9:2];green_value=cross_sum[9:2];blue_value=b_l1;
  end else begin
   green_value=b_l1;
   red_value=center_y_odd==RED_Y ? horizontal[8:1] : vertical[8:1];
   blue_value=center_y_odd==RED_Y ? vertical[8:1] : horizontal[8:1];
  end
 end
 always @(posedge dclk) begin
  sync1<=row_toggle;sync2<=sync1;fs1<=source_toggle;fs2<=fs1;
  walk_d<=walk_x;valid_d<=walking;rgb_valid<=0;rgb_sof<=0;rgb_eof<=0;frame_abort<=0;
  if(!drstn) begin
   sync1<=0;sync2<=0;seen<=0;fs1<=0;fs2<=0;fs_seen<=0;walking<=0;valid_d<=0;
   walk_x<=0;walk_d<=0;bottom<=0;row_y<=0;rgb<=0;source_frames<=0;overruns<=0;last_line_pixels<=0;
   a_l2<=0;a_l1<=0;b_l2<=0;b_l1<=0;c_l2<=0;c_l1<=0;
  end else begin
   if(fs2!=fs_seen) begin fs_seen<=fs2;source_frames<=source_frames+1;last_line_pixels<=line_pixels_hold;end
   if(sync2!=seen) begin
    seen<=sync2;
    if(done_y>=Y0+1 && done_y<=Y0+HEIGHT) begin
     if(walking || valid_d) begin overruns<=overruns+1;frame_abort<=1;end
     else begin bottom<=done_bank;row_y<=done_y;walk_x<=0;walking<=1;end
    end
   end
   if(walking) begin if(walk_x==WIDTH+7) walking<=0;else walk_x<=walk_x+1;end
   if(valid_d) begin
    a_l2<=a_l1;a_l1<=a;b_l2<=b_l1;b_l1<=b;c_l2<=c_l1;c_l1<=c;
    if(walk_d>=5 && walk_d<=WIDTH+4) begin
     rgb_valid<=1;rgb<={red_value,green_value,blue_value};
     rgb_sof<=walk_d==5 && row_y==Y0+1;rgb_eof<=walk_d==WIDTH+4 && row_y==Y0+HEIGHT;
    end
   end
  end
 end
endmodule
