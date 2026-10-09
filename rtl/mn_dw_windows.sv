// Ten narrow immutable copies allow one 10-pixel row read per clock.
// Prebuilt 800-bit windows replace the 2048-bit bidirectional shift network.
module mn_dw_windows (
    input wire clk,reset,
    input wire load_en,
    input wire [7:0] load_addr,load_data,
    input wire start,
    input wire [2:0] kh,kw,ay,ax,
    input wire [1:0] pad_kind,pad_width,
    input wire [3:0] edges,valid_w,valid_h,
    output wire build_done,
    input wire rd_en,
    input wire [5:0] rd_tap,
    output wire [799:0] rd_data
);
    localparam B_IDLE=0,B_PRIME=1,B_STREAM=2,B_STORE=3,B_DONE=4;
    reg [2:0] state;
    reg [2:0] tap_r,tap_c;
    reg [5:0] tap_number;
    reg [3:0] captured;
    reg [799:0] window_buffer;
    wire read_shadow=state==B_PRIME || state==B_STREAM && captured<9;
    wire [3:0] issue_row=state==B_PRIME ? 4'd0 : captured+1'b1;
    wire signed [6:0] y=$signed({3'b0,issue_row})+$signed({4'b0,tap_r})-$signed({4'b0,ay});
    function automatic signed [6:0] reflect_coordinate;
        input signed [6:0] v;
        input [3:0] extent;
        input lower_edge,upper_edge;
        reg signed [6:0] t,n;
        begin
            t=v;n=$signed({3'b0,extent});
            // For radius<=3, dimensions>=4 need only one reflection.
            // Small complete images use their exact periodic triangle wave.
            if(lower_edge && upper_edge && extent==1) t=0;
            else if(lower_edge && upper_edge && extent==2) t=$signed({6'b0,v[0]});
            else if(lower_edge && upper_edge && extent==3) begin
                case(v[1:0])
                    0:t=0;
                    2:t=2;
                    default:t=1;
                endcase
            end else begin
                if(lower_edge && t<0) t=-t;
                if(upper_edge && t>=n) t=(n<<<1)-7'sd2-t;
            end
            reflect_coordinate=t;
        end
    endfunction
    wire y_out=(edges[2] && y<0) || (edges[3] && y>=$signed({3'b0,valid_h}));
    wire y_in_pad=(!edges[2] || y>=-$signed({5'b0,pad_width})) &&
        (!edges[3] || y<$signed({3'b0,valid_h})+$signed({5'b0,pad_width}));
    wire signed [6:0] mapped_y=pad_kind==2 ?
        reflect_coordinate(y,valid_h,edges[2],edges[3]) : y;
    wire [79:0] row_pixels;
    reg [9:0] zero_pipe;
    genvar c;
    generate for(c=0;c<10;c=c+1) begin: pixel
        localparam signed [6:0] COLUMN=c;
        wire signed [6:0] x=COLUMN+$signed({4'b0,tap_c})-$signed({4'b0,ax});
        wire x_out=(edges[0] && x<0) || (edges[1] && x>=$signed({3'b0,valid_w}));
        wire x_in_pad=(!edges[0] || x>=-$signed({5'b0,pad_width})) &&
            (!edges[1] || x<$signed({3'b0,valid_w})+$signed({5'b0,pad_width}));
        wire signed [6:0] mapped_x=pad_kind==2 ?
            reflect_coordinate(x,valid_w,edges[0],edges[1]) : x;
        wire [7:0] addr={mapped_y[3:0]+4'd3,mapped_x[3:0]+4'd3};
        wire [7:0] data;
        always @(posedge clk) if(read_shadow)
            zero_pipe[c]<=(x_out || y_out) && (pad_kind!=2 || !x_in_pad || !y_in_pad);
        EFX_RAM10 #(.READ_WIDTH(8),.WRITE_WIDTH(8),.OUTPUT_REG(0)) shadow (
            .WCLK(clk),.WE({2{load_en}}),.WCLKE(1'b1),.WADDREN(load_en),
            .WDATA(load_data),.WADDR({2'b0,load_addr}),
            .RCLK(clk),.RE(read_shadow),.RST(reset),.RADDREN(read_shadow),
            .RDATA(data),.RADDR({2'b0,addr}));
        assign row_pixels[c*8+:8]=zero_pipe[c] ? 8'd0 : data;
    end
    for(c=0;c<40;c=c+1) begin: windows
        EFX_RAM10 #(.READ_WIDTH(20),.WRITE_WIDTH(20),.OUTPUT_REG(0)) ram (
            .WCLK(clk),.WE({2{state==B_STORE}}),.WCLKE(1'b1),
            .WADDREN(state==B_STORE),.WDATA(window_buffer[c*20+:20]),
            .WADDR({3'b0,tap_number}),.RCLK(clk),.RE(rd_en),.RST(reset),
            .RADDREN(rd_en),.RDATA(rd_data[c*20+:20]),.RADDR({3'b0,rd_tap}));
    end endgenerate
    assign build_done=state==B_DONE;
    always @(posedge clk) begin
        if(reset) begin state<=B_IDLE;tap_r<=0;tap_c<=0;tap_number<=0;captured<=0;end
        else case(state)
            B_IDLE:if(start) begin tap_r<=0;tap_c<=0;tap_number<=0;state<=B_PRIME;end
            B_PRIME:begin captured<=0;state<=B_STREAM;end
            B_STREAM:begin
                window_buffer<={row_pixels,window_buffer[799:80]};
                if(captured==9) state<=B_STORE;
                else captured<=captured+1'b1;
            end
            B_STORE:begin
                if(tap_r==kh-1'b1 && tap_c==kw-1'b1) state<=B_DONE;
                else begin
                    if(tap_c==kw-1'b1) begin tap_c<=0;tap_r<=tap_r+1'b1;end
                    else tap_c<=tap_c+1'b1;
                    tap_number<=tap_number+1'b1;state<=B_PRIME;
                end
            end
            B_DONE:state<=B_IDLE;
            default:state<=B_IDLE;
        endcase
    end
endmodule
