`timescale 1ns/1ps
// One renderer for RGBx originals and planar tiled network results.
// Four rows in the SAME six 16-bit RAMs (512 rather than 256 words).
// Tiled mode fetches two adjacent rows per burst; RGBx accepts four pixels/beat.
module camera_hdmi #(parameter CHECK_ORIGINAL_SUM=0)(input wire dclk,drstn,pclk,prstn,
 input wire [31:0] checksum0,checksum1,output reg [15:0] checksum_errors=0,
 input wire frame_ready_toggle,frame_slot,select_style,
 output reg frame_ack_toggle=0,output reg active_slot=0,active_style=1,
 output reg [31:0] error_expected_sum=0,error_ddr_sum=0,error_video_sum=0,
 output reg [31:0] error_context=0,
 output wire arvalid,read_active,read_urgent,input wire arready,output wire [31:0] araddr,output wire [7:0] arlen,
 input wire rvalid,output wire rready,input wire [127:0] rdata,input wire rlast,input wire [1:0] rresp,
 output wire [9:0] txc,txd0,txd1,txd2,
 output reg [31:0] loaded_lines=0,output reg fault=0,
 output reg [15:0] displayed_frames=0,underflows=0,output reg [31:0] pixel_sum=0,
 output reg [23:0] video_rgb=0,output reg video_de=0,video_hs=0,video_vs=0,output wire [5:0] diagnostic);
 localparam IDLE=0,AR=1,READ=2,LEFT=3,COMPLETE=5;
 reg [2:0] state=IDLE,beat=0;reg [3:0] byte_step=0;reg req1=0,req2=0,seen=0,done_toggle=0;
 assign diagnostic={state,beat};
 reg [7:0] source_y=0;reg [4:0] tile_y=0,tile_x=0;reg [1:0] channel=0,write_bank=0;reg raw_mode=0;
 reg [2:0] pair_row=0;reg [6:0] left_start=0;
 reg [79:0] pixels0=0,pixels1=0;reg unpack_second=0;
 reg [31:0] source_base=0;reg [3:0] raw_burst=0;reg [8:0] raw_x=0;
 reg request_toggle=0,request_raw=0;reg [1:0] request_bank=0;reg [7:0] request_y=0;reg [31:0] request_base=0;
 wire [31:0] tile_index=({30'd0,channel}<<9)+({30'd0,channel}<<8)+({27'd0,tile_y}<<5)+tile_x;
 assign arvalid=state==AR;assign read_active=state!=IDLE;
 assign araddr=source_base+(raw_mode ? (({24'd0,source_y}<<10)+({24'd0,source_y}<<8)+{21'd0,raw_burst,7'd0}) :
     (tile_index<<7)+{25'd0,left_start[6:4],4'd0});
 // Rows 4/5 cross the padded half-tile boundary and need five beats.
 wire [2:0] last_beat=raw_mode ? 3'd7 : pair_row==2 ? 3'd4 : pair_row==4 ? 3'd3 : 3'd2;
 assign arlen={5'd0,last_beat};assign rready=state==READ;
 // Keep the DDR and display checks independent, so a rare bad frame can be
 // localized after it has disappeared. This accumulator includes RGB only.
 reg [31:0] raw_read_sum=0;
 reg [8:0] raw_read_lines=0;
 wire [11:0] rgb_beat_sum;
 assign rgb_beat_sum={4'd0,rdata[7:0]}+{4'd0,rdata[15:8]}+{4'd0,rdata[23:16]}+
     {4'd0,rdata[39:32]}+{4'd0,rdata[47:40]}+{4'd0,rdata[55:48]}+
     {4'd0,rdata[71:64]}+{4'd0,rdata[79:72]}+{4'd0,rdata[87:80]}+
     {4'd0,rdata[103:96]}+{4'd0,rdata[111:104]}+{4'd0,rdata[119:112]};
 integer k;
 always @(posedge dclk) begin
  req1<=request_toggle;req2<=req1;
  if(!drstn) begin state<=IDLE;req1<=0;req2<=0;seen<=0;done_toggle<=0;loaded_lines<=0;fault<=0;raw_read_sum<=0;raw_read_lines<=0;end
  else case(state)
   IDLE:if(req2!=seen) begin
    seen<=req2;source_y<=request_y;tile_y<=request_y/10;write_bank<=request_bank;
    source_base<=request_base;raw_mode<=request_raw;raw_burst<=0;raw_x<=0;
    pair_row<=(request_y%10)/2;
    left_start<=(request_y%10>=5 ? 64 : 0)+(request_y%5)*5;
    tile_x<=0;channel<=0;beat<=0;byte_step<=0;unpack_second<=0;state<=AR;
    if(request_raw && request_y==0) begin raw_read_sum<=0;raw_read_lines<=0;end
   end
   AR:if(arready) begin beat<=0;state<=READ;end
   READ:if(rvalid) begin
    if(rresp!=0 || rlast!=(beat==last_beat)) fault<=1;
    if(raw_mode) begin
     raw_read_sum<=raw_read_sum+{18'd0,rgb_beat_sum,2'd0};
     raw_x<=raw_x+4;
     if(beat<7) beat<=beat+1;
     else if(raw_burst<9) begin raw_burst<=raw_burst+1;state<=AR;end
     else state<=COMPLETE;
    end
    else begin
     // Fixed byte wiring is inserted below; no variable 128-bit byte mux.
     // Current writer pads EACH 50-byte half to 64 bytes.
     case ({pair_row,beat})
      6'd0:begin
       pixels0[0+:8]<=rdata[0+:8];
       pixels0[8+:8]<=rdata[8+:8];
       pixels0[16+:8]<=rdata[16+:8];
       pixels0[24+:8]<=rdata[24+:8];
       pixels0[32+:8]<=rdata[32+:8];
       pixels1[0+:8]<=rdata[40+:8];
       pixels1[8+:8]<=rdata[48+:8];
       pixels1[16+:8]<=rdata[56+:8];
       pixels1[24+:8]<=rdata[64+:8];
       pixels1[32+:8]<=rdata[72+:8];
      end
      6'd1:begin
       pixels0[40+:8]<=rdata[72+:8];
       pixels0[48+:8]<=rdata[80+:8];
       pixels0[56+:8]<=rdata[88+:8];
       pixels0[64+:8]<=rdata[96+:8];
       pixels0[72+:8]<=rdata[104+:8];
       pixels1[40+:8]<=rdata[112+:8];
       pixels1[48+:8]<=rdata[120+:8];
      end
      6'd2:begin
       pixels1[56+:8]<=rdata[0+:8];
       pixels1[64+:8]<=rdata[8+:8];
       pixels1[72+:8]<=rdata[16+:8];
      end
      6'd8:begin
       pixels0[0+:8]<=rdata[80+:8];
       pixels0[8+:8]<=rdata[88+:8];
       pixels0[16+:8]<=rdata[96+:8];
       pixels0[24+:8]<=rdata[104+:8];
       pixels0[32+:8]<=rdata[112+:8];
       pixels1[0+:8]<=rdata[120+:8];
      end
      6'd9:begin
       pixels1[8+:8]<=rdata[0+:8];
       pixels1[16+:8]<=rdata[8+:8];
       pixels1[24+:8]<=rdata[16+:8];
       pixels1[32+:8]<=rdata[24+:8];
      end
      6'd10:begin
       pixels0[40+:8]<=rdata[24+:8];
       pixels0[48+:8]<=rdata[32+:8];
       pixels0[56+:8]<=rdata[40+:8];
       pixels0[64+:8]<=rdata[48+:8];
       pixels0[72+:8]<=rdata[56+:8];
       pixels1[40+:8]<=rdata[64+:8];
       pixels1[48+:8]<=rdata[72+:8];
       pixels1[56+:8]<=rdata[80+:8];
       pixels1[64+:8]<=rdata[88+:8];
       pixels1[72+:8]<=rdata[96+:8];
      end
      6'd16:begin
       pixels0[0+:8]<=rdata[32+:8];
       pixels0[8+:8]<=rdata[40+:8];
       pixels0[16+:8]<=rdata[48+:8];
       pixels0[24+:8]<=rdata[56+:8];
       pixels0[32+:8]<=rdata[64+:8];
      end
      6'd17:begin
       pixels0[40+:8]<=rdata[104+:8];
       pixels0[48+:8]<=rdata[112+:8];
       pixels0[56+:8]<=rdata[120+:8];
      end
      6'd18:begin
       pixels0[64+:8]<=rdata[0+:8];
       pixels0[72+:8]<=rdata[8+:8];
      end
      6'd19:begin
       pixels1[0+:8]<=rdata[0+:8];
       pixels1[8+:8]<=rdata[8+:8];
       pixels1[16+:8]<=rdata[16+:8];
       pixels1[24+:8]<=rdata[24+:8];
       pixels1[32+:8]<=rdata[32+:8];
      end
      6'd20:begin
       pixels1[40+:8]<=rdata[72+:8];
       pixels1[48+:8]<=rdata[80+:8];
       pixels1[56+:8]<=rdata[88+:8];
       pixels1[64+:8]<=rdata[96+:8];
       pixels1[72+:8]<=rdata[104+:8];
      end
      6'd24:begin
       pixels0[0+:8]<=rdata[40+:8];
       pixels0[8+:8]<=rdata[48+:8];
       pixels0[16+:8]<=rdata[56+:8];
       pixels0[24+:8]<=rdata[64+:8];
       pixels0[32+:8]<=rdata[72+:8];
       pixels1[0+:8]<=rdata[80+:8];
       pixels1[8+:8]<=rdata[88+:8];
       pixels1[16+:8]<=rdata[96+:8];
       pixels1[24+:8]<=rdata[104+:8];
       pixels1[32+:8]<=rdata[112+:8];
      end
      6'd25:begin
       pixels0[40+:8]<=rdata[112+:8];
       pixels0[48+:8]<=rdata[120+:8];
      end
      6'd26:begin
       pixels0[56+:8]<=rdata[0+:8];
       pixels0[64+:8]<=rdata[8+:8];
       pixels0[72+:8]<=rdata[16+:8];
       pixels1[40+:8]<=rdata[24+:8];
       pixels1[48+:8]<=rdata[32+:8];
       pixels1[56+:8]<=rdata[40+:8];
       pixels1[64+:8]<=rdata[48+:8];
       pixels1[72+:8]<=rdata[56+:8];
      end
      6'd32:begin
       pixels0[0+:8]<=rdata[120+:8];
      end
      6'd33:begin
       pixels0[8+:8]<=rdata[0+:8];
       pixels0[16+:8]<=rdata[8+:8];
       pixels0[24+:8]<=rdata[16+:8];
       pixels0[32+:8]<=rdata[24+:8];
       pixels1[0+:8]<=rdata[32+:8];
       pixels1[8+:8]<=rdata[40+:8];
       pixels1[16+:8]<=rdata[48+:8];
       pixels1[24+:8]<=rdata[56+:8];
       pixels1[32+:8]<=rdata[64+:8];
      end
      6'd34:begin
       pixels0[40+:8]<=rdata[64+:8];
       pixels0[48+:8]<=rdata[72+:8];
       pixels0[56+:8]<=rdata[80+:8];
       pixels0[64+:8]<=rdata[88+:8];
       pixels0[72+:8]<=rdata[96+:8];
       pixels1[40+:8]<=rdata[104+:8];
       pixels1[48+:8]<=rdata[112+:8];
       pixels1[56+:8]<=rdata[120+:8];
      end
      6'd35:begin
       pixels1[64+:8]<=rdata[0+:8];
       pixels1[72+:8]<=rdata[8+:8];
      end
     endcase
     if(beat==last_beat) begin byte_step<=0;unpack_second<=0;state<=LEFT;end else beat<=beat+1;
    end
   end
   LEFT:begin
    // The same 160-bit payload registers shift out two pixels per cycle.
    if(unpack_second) pixels1<={16'd0,pixels1[79:16]};
    else pixels0<={16'd0,pixels0[79:16]};
    if(byte_step<4) byte_step<=byte_step+1;else begin
     byte_step<=0;
     if(!unpack_second) unpack_second<=1;
     else begin
      unpack_second<=0;
      if(tile_x<31) begin tile_x<=tile_x+1;state<=AR;end
      else if(channel<2) begin tile_x<=0;channel<=channel+1;state<=AR;end
      else state<=COMPLETE;
     end
    end
   end
   COMPLETE:begin
    done_toggle<=seen;loaded_lines<=loaded_lines+(raw_mode ? 1 : 2);state<=IDLE;
    if(raw_mode) raw_read_lines<=raw_read_lines+1;
   end
  endcase
 end
 reg [10:0] h=0;reg [9:0] v=0;reg have_frame=0,slot_p=0,style_p=1;
 reg ready1=0,ready2=0,ready_seen=0,style1=1,style2=1,swap_ack=0;
 reg [7:0] display_y=0,want_y=0,pending_y=0,tag_y[0:3];reg [8:0] pixel_x=0;
 reg [1:0] vertical_repeat=0,horizontal_repeat=0,pending_bank=0;reg pending=0,pending_pair=0;
 reg epoch=0,pending_epoch=0,ack1=0,ack2=0,ack_seen=0;
 reg hs_d=0,vs_d=0,de_d=0,viewport_d=0,line_good_d=0,viewport_out=0;
 wire viewport=h>=580 && h<1220 && v>=145 && v<625;
 wire de=h>=260 && h<1540 && v>=25 && v<745;
 reg [1:0] pixel_pair_d=0;
 always @(posedge pclk) pixel_pair_d<=pixel_x[1:0];
 wire [7:0] row_byte[0:2];genvar g,p;
 wire [8:0] style_x=({4'd0,tile_x}<<3)+({4'd0,tile_x}<<1)+({5'd0,byte_step}<<1);
 wire [1:0] store_bank=raw_mode ? write_bank : {write_bank[1],write_bank[0]^unpack_second};
 wire [8:0] write_address={store_bank,raw_mode ? raw_x[8:2] : style_x[8:2]};
 wire [15:0] style_word=unpack_second ? pixels1[15:0] : pixels0[15:0];
 generate for(g=0;g<3;g=g+1) begin:g_line
  wire [15:0] row_q[0:1];
  wire write_raw=state==READ && raw_mode && rvalid;
  wire write_style=state==LEFT && channel==g;
  for(p=0;p<2;p=p+1) begin:g_pair
   (* syn_ramstyle="block_ram" *) reg [15:0] ram[0:511];reg [15:0] q;
   always @(posedge dclk) if(write_raw || (write_style && style_x[1]==p))
    ram[write_address]<=write_raw ? {rdata[(p*2+1)*32+g*8+:8],rdata[p*64+g*8+:8]} : style_word;
   always @(posedge pclk) q<=ram[{display_y[1:0],pixel_x[8:2]}];
   assign row_q[p]=q;
  end
  assign row_byte[g]=row_q[pixel_pair_d[1]][pixel_pair_d[0]*8+:8];
 end endgenerate
 // A styled refill writes two rows, including the padded 4/5 boundary.
 // Reserve DDR with two rows left; allow fair compute grants with three ready.
 // Only this single-bit decision crosses clock domains; tags stay in pclk.
 wire [7:0] next_y=display_y+(style_p ? 8'd2 : 8'd1);
 wire urgent_p=have_frame && v<625 &&
     (tag_y[display_y[1:0]]!=display_y || tag_y[next_y[1:0]]!=next_y);
 reg urgent1=0,urgent2=0;
 always @(posedge dclk) if(!drstn) begin urgent1<=0;urgent2<=0;end
 else begin urgent1<=urgent_p;urgent2<=urgent1;end
 assign read_urgent=urgent2;
 reg [31:0] sum=0,sum_hold=0;reg [15:0] frames=0,misses=0,frames_hold=0,misses_hold=0;
 reg [31:0] expected_sum=0;reg [15:0] sum_errors=0,sum_errors_hold=0;
 reg frame_toggle=0,frame1=0,frame2=0,frame_seen=0,swap1=0,swap2=0;
 always @(posedge dclk) begin
  frame1<=frame_toggle;frame2<=frame1;swap1<=swap_ack;swap2<=swap1;
  if(!drstn) begin
   frame1<=0;frame2<=0;frame_seen<=0;displayed_frames<=0;underflows<=0;pixel_sum<=0;
   swap1<=0;swap2<=0;frame_ack_toggle<=0;active_slot<=0;active_style<=1;
   checksum_errors<=0;
  end else begin
   frame_ack_toggle<=swap2;
   if(frame2!=frame_seen) begin
    frame_seen<=frame2;displayed_frames<=frames_hold;underflows<=misses_hold;pixel_sum<=sum_hold;
    active_slot<=slot_p;active_style<=style_p;
    checksum_errors<=sum_errors_hold;
   end
  end
 end
 always @(posedge pclk) begin
  ready1<=frame_ready_toggle;ready2<=ready1;style1<=select_style;style2<=style1;
  ack1<=done_toggle;ack2<=ack1;
  hs_d<=h<40;vs_d<=v<5;de_d<=de;viewport_d<=viewport;
  line_good_d<=have_frame && tag_y[display_y[1:0]]==display_y;
  video_hs<=hs_d;video_vs<=vs_d;video_de<=de_d;viewport_out<=viewport_d;
  video_rgb<=viewport_d && line_good_d ? {row_byte[0],row_byte[1],row_byte[2]} : 24'd0;
  if(!prstn) begin
   h<=0;v<=0;have_frame<=0;slot_p<=0;style_p<=1;ready1<=0;ready2<=0;ready_seen<=0;style1<=1;style2<=1;swap_ack<=0;
   display_y<=0;want_y<=0;pending<=0;pending_pair<=0;
   tag_y[0]<=255;tag_y[1]<=255;tag_y[2]<=255;tag_y[3]<=255;request_toggle<=0;request_y<=0;request_bank<=0;
   ack1<=0;ack2<=0;ack_seen<=0;epoch<=0;pending_epoch<=0;
   vertical_repeat<=0;horizontal_repeat<=0;pixel_x<=0;
   video_de<=0;frames<=0;misses<=0;sum<=0;frame_toggle<=0;sum_hold<=0;frames_hold<=0;misses_hold<=0;
   expected_sum<=0;sum_errors<=0;sum_errors_hold<=0;
   error_expected_sum<=0;error_ddr_sum<=0;error_video_sum<=0;error_context<=0;
  end else begin
   if(h==1649) begin h<=0;if(v==749) v<=0;else v<=v+1;end else h<=h+1;
   if(ack2!=ack_seen) begin
    ack_seen<=ack2;pending<=0;
    if(pending_epoch==epoch) begin
     tag_y[pending_bank]<=pending_y;
     if(pending_pair) tag_y[{pending_bank[1],1'b1}]<=pending_y+1;
     want_y<=pending_y+(pending_pair ? 2 : 1);
    end
   end
   if(h==0 && v==0) begin
    if(ready2!=ready_seen) begin
     have_frame<=1;slot_p<=frame_slot;ready_seen<=ready2;swap_ack<=ready2;
     expected_sum<=frame_slot ? checksum1 : checksum0;
    end
    style_p<=style2;want_y<=0;display_y<=0;vertical_repeat<=0;
    tag_y[0]<=255;tag_y[1]<=255;tag_y[2]<=255;tag_y[3]<=255;
    epoch<=~epoch;sum<=0;
   end else if(!pending && have_frame && want_y<240 &&
       (v<145 ? want_y<4 : ({1'b0,want_y}+(style_p ? 9'd1 : 9'd0))<={1'b0,display_y}+9'd3)) begin
    request_y<=want_y;request_bank<=want_y[1:0];pending_y<=want_y;pending_bank<=want_y[1:0];pending_pair<=style_p;
    request_raw<=!style_p;
    request_base<=style_p ? (slot_p ? 32'h700000 : 32'h600000) : (slot_p ? 32'h900000 : 32'h800000);
    pending_epoch<=epoch;request_toggle<=~request_toggle;pending<=1;
   end
   if(h==1649 && v>=145 && v<625) begin
    if(vertical_repeat==1) begin vertical_repeat<=0;display_y<=display_y+1;end
    else vertical_repeat<=vertical_repeat+1;
   end
   if(h==579) begin pixel_x<=0;horizontal_repeat<=0;end
   else if(viewport) begin
    if(horizontal_repeat==1) begin horizontal_repeat<=0;pixel_x<=pixel_x+1;end
    else horizontal_repeat<=horizontal_repeat+1;
   end
   if(h==580 && v>=145 && v<625 && have_frame && tag_y[display_y[1:0]]!=display_y) misses<=misses+1;
   if(video_de && viewport_out && have_frame) sum<=sum+{24'd0,video_rgb[23:16]}+{24'd0,video_rgb[15:8]}+{24'd0,video_rgb[7:0]};
   if(h==1649 && v==749) begin
    frames<=frames+1;frames_hold<=frames+1;misses_hold<=misses;sum_hold<=sum;frame_toggle<=~frame_toggle;
    if(CHECK_ORIGINAL_SUM && have_frame && !style_p && sum!=expected_sum) begin
     sum_errors<=sum_errors+1;sum_errors_hold<=sum_errors+1;
     error_expected_sum<=expected_sum;error_ddr_sum<=raw_read_sum;error_video_sum<=sum;
     error_context<={frames,6'd0,slot_p,raw_read_lines};
    end else sum_errors_hold<=sum_errors;
   end
  end
 end
 assign txc=10'b1111100000;
 tmds_channel u_blue(.clk_pixel(pclk),.video_data(video_rgb[7:0]),.data_island_data(4'd0),.control_data({video_vs,video_hs}),.mode({2'd0,video_de}),.tmds(txd0));
 tmds_channel u_green(.clk_pixel(pclk),.video_data(video_rgb[15:8]),.data_island_data(4'd0),.control_data(2'd0),.mode({2'd0,video_de}),.tmds(txd1));
 tmds_channel u_red(.clk_pixel(pclk),.video_data(video_rgb[23:16]),.data_island_data(4'd0),.control_data(2'd0),.mode({2'd0,video_de}),.tmds(txd2));
endmodule
