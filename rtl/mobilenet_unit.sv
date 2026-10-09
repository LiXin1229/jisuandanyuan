`include "mn_isa.vh"
module mobilenet_unit (
    input wire clk, reset,
    input wire [127:0] instruction,
    input wire instruction_valid,
    output wire instruction_ready,
    output wire [2:0] instruction_count,
    input wire host_cache_wr,
    input wire [9:0] host_cache_waddr,
    input wire [799:0] host_cache_wdata,
    input wire [3:0] host_cache_wmask,
    input wire host_cache_rd,
    input wire [9:0] host_cache_raddr,
    output wire host_memory_ready,
    output wire [799:0] host_cache_rdata,
    output wire host_cache_rvalid,
    input wire host_param_wr,
    input wire [11:0] host_param_addr,
    input wire [15:0] host_param_data,
    output wire busy,
    output reg done,
    output reg [3:0] error_code
);
    localparam IDLE=0, CHECK=1, CLEAR=2, ROUND=3, PW_RUN=4,
        N_BIAS=5, N_X=6, DW_CENTER=7, DW_RET=8, DW_LOAD=9,
        DW_SET=10, BUILD_START=11, BUILD_WAIT=12,
        DW_TAPS=15, WAIT_PE=18,
        WAIT_POST=19, WRITE=20, COMPLETE=21;
    localparam SRC_WINDOW=0, SRC_CACHE=1, SRC_BIAS=2, SRC_ROUND=3;
    reg [4:0] state;
    reg [127:0] cmd;
    wire [3:0] opcode=cmd[3:0];
    wire [9:0] src_base=cmd[13:4], dst_base=cmd[23:14];
    wire [11:0] param_base=cmd[35:24];
    wire [5:0] channels={1'b0,cmd[40:36]}+6'd1;
    wire [2:0] kernel=cmd[43:41];
    wire [1:0] activation=cmd[45:44];
    wire pool_enable=cmd[46];
    wire [2:0] write_mode=cmd[49:47];
    wire [1:0] pad_kind=cmd[51:50], pad_width=cmd[53:52];
    wire [3:0] edges=cmd[57:54]; // bit0 L, bit1 R, bit2 T, bit3 B
    wire [3:0] valid_w=cmd[61:58]+4'd1, valid_h=cmd[65:62]+4'd1;
    wire [9:0] tile_pitch=cmd[75:66], row_pitch=cmd[85:76];
    wire rounding=cmd[86], keep_acc=cmd[87], more_acc=cmd[88];
    wire stride2=cmd[89];
    reg [2:0] kh,kw,ay,ax;
    always @* begin
        kh=1; kw=2; ay=0; ax=0;
        case(kernel)
            0: begin kh=1;kw=2;end
            1: begin kh=2;kw=1;end
            2: begin kh=2;kw=2;end
            3: begin kh=3;kw=3;ay=1;ax=1;end
            4: begin kh=7;kw=7;ay=3;ax=3;end
            default: ;
        endcase
    end
    wire [5:0] kernel_area=kernel==4 ? 6'd49 : kernel==3 ? 6'd9 : kernel==2 ? 6'd4 : 6'd2;
    wire [5:0] center_tap=kernel==4 ? 6'd24 : kernel==3 ? 6'd4 : 6'd0;
    wire [127:0] fifo_head;
    wire fifo_valid;
    wire fifo_pop=state==IDLE && fifo_valid && !reset &&
        !(host_cache_wr || host_cache_rd || host_param_wr);
    mn_instruction_fifo fifo(.clk(clk),.reset(reset),.in_data(instruction),
        .in_valid(instruction_valid),.in_ready(instruction_ready),
        .out_data(fifo_head),.out_valid(fifo_valid),.out_ready(fifo_pop),
        .count(instruction_count));
    assign busy=state!=IDLE;
    assign host_memory_ready=state==IDLE && !reset;

    reg acc_live, acc_round;
    reg [9:0] acc_dst;
    reg [8:0] acc_channels;
    reg [5:0] channel_idx;
    reg [3:0] owner;
    reg [1:0] owner_row,owner_col;
    reg [3:0] hrow,hcol;
    reg [3:0] row_start,col_start,row_end,col_end;
    reg missing_tile;
    reg [2:0] tap_row,tap_col;
    wire center_position=tap_row==ay && tap_col==ax;
    wire last_position=tap_row==kh-1'b1 && tap_col==kw-1'b1;
    wire [5:0] tap_offset=kernel==4 ? ({3'b0,tap_row}<<3)-tap_row+tap_col :
        kernel==3 ? ({3'b0,tap_row}<<1)+tap_row+tap_col :
        kernel==2 ? ({3'b0,tap_row}<<1)+tap_col : kernel==1 ? {3'b0,tap_row} : {3'b0,tap_col};
    always @* begin
        case(owner)
            0:begin owner_row=0;owner_col=0;end
            1:begin owner_row=0;owner_col=1;end
            2:begin owner_row=0;owner_col=2;end
            3:begin owner_row=1;owner_col=0;end
            4:begin owner_row=1;owner_col=1;end
            5:begin owner_row=1;owner_col=2;end
            6:begin owner_row=2;owner_col=0;end
            7:begin owner_row=2;owner_col=1;end
            default:begin owner_row=2;owner_col=2;end
        endcase
        row_start=owner_row==0 ? 0 : owner_row==1 ? 3 : 13;
        col_start=owner_col==0 ? 0 : owner_col==1 ? 3 : 13;
        row_end=owner_row==0 ? 2 : owner_row==1 ? 12 : 15;
        col_end=owner_col==0 ? 2 : owner_col==1 ? 12 : 15;
    end
    wire tile_absent=(owner_row==0 && edges[2]) || (owner_row==2 && edges[3]) ||
        (owner_col==0 && edges[0]) || (owner_col==2 && edges[1]);
    reg signed [13:0] neighbor_addr;
    always @* begin
        neighbor_addr=$signed({4'b0,src_base});
        if(owner_row==0) neighbor_addr=neighbor_addr-$signed({4'b0,row_pitch});
        if(owner_row==2) neighbor_addr=neighbor_addr+$signed({4'b0,row_pitch});
        if(owner_col==0) neighbor_addr=neighbor_addr-$signed({4'b0,tile_pitch});
        if(owner_col==2) neighbor_addr=neighbor_addr+$signed({4'b0,tile_pitch});
    end
    wire neighbor_ok=neighbor_addr>=0 && neighbor_addr<1024;

    function automatic [6:0] packed_pixel;
        input [3:0] r,c;
        reg [3:0] lr,lc;
        reg [1:0] quad;
        reg [7:0] index_sum;
        begin
            lr=r>=5 ? r-4'd5 : r; lc=c>=5 ? c-4'd5 : c;
            quad={r>=5,c>=5};
            index_sum=quad*8'd25+lr*8'd5+lc;
            packed_pixel=index_sum[6:0]; // Valid local coordinates bound this to 0..99.
        end
    endfunction
    wire signed [6:0] load_x=$signed({3'b000,hcol})-7'sd3;
    wire signed [6:0] load_y=$signed({3'b000,hrow})-7'sd3;
    wire load_outside=(edges[0] && load_x<0) ||
        (edges[1] && load_x>=$signed({3'b000,valid_w})) ||
        (edges[2] && load_y<0) ||
        (edges[3] && load_y>=$signed({3'b000,valid_h}));
    wire [3:0] local_r=owner_row==0 ? hrow+4'd7 :
        owner_row==1 ? hrow-4'd3 : hrow-4'd13;
    wire [3:0] local_c=owner_col==0 ? hcol+4'd7 :
        owner_col==1 ? hcol-4'd3 : hcol-4'd13;
    wire [6:0] load_pixel=packed_pixel(local_r,local_c);

    reg issue_valid,issue_last,issue_bias,issue_const;
    reg [1:0] issue_source;
    reg [11:0] issue_param;
    reg cache_rd_en;
    reg [9:0] cache_rd_addr;
    wire [799:0] cache_data;
    wire cache_valid;
    always @* begin
        issue_valid=0;issue_last=0;issue_source=SRC_WINDOW;
        issue_param=param_base;issue_bias=0;issue_const=0;
        cache_rd_en=0;
        cache_rd_addr=src_base;
        case(state)
            ROUND:begin issue_valid=1;issue_source=SRC_ROUND;issue_const=1;end
            PW_RUN:begin
                issue_valid=1;issue_last=channel_idx==channels-1'b1;
                issue_source=SRC_CACHE;issue_param=param_base+channel_idx;
                cache_rd_en=1;cache_rd_addr=src_base+channel_idx;
            end
            N_BIAS:begin
                issue_valid=1;issue_source=SRC_BIAS;issue_bias=1;
                issue_param=param_base+12'd1;
            end
            N_X:begin
                issue_valid=1;issue_last=1;issue_source=SRC_CACHE;
                cache_rd_en=1;cache_rd_addr=src_base;
            end
            DW_CENTER:begin
                issue_valid=1;issue_source=SRC_CACHE;
                issue_param=param_base+center_tap;
                cache_rd_en=1;cache_rd_addr=src_base;
            end
            DW_SET:begin
                cache_rd_en=!tile_absent && neighbor_ok;
                cache_rd_addr=neighbor_addr[9:0];
            end
            DW_TAPS:begin
                issue_valid=!center_position;issue_last=last_position;
                issue_param=param_base+tap_offset;
            end
            default: ;
        endcase
        if(reset) begin issue_valid=0;cache_rd_en=0;end
    end
    wire [15:0] param_data;
    wire param_valid;
    mn_param_ram parameters(.clk(clk),.reset(reset),
        .wr_en(host_param_wr && host_memory_ready),.wr_addr(host_param_addr),
        .wr_data(host_param_data),.rd_en(issue_valid && !issue_const),
        .rd_addr(issue_param),.rd_data(param_data),.rd_valid(param_valid));

    wire [799:0] window_data;
    wire windows_done;
    wire [7:0] halo_load_data=missing_tile || load_outside ? 8'd0 : cache_data[load_pixel*8+:8];
    mn_dw_windows dw_windows(.clk(clk),.reset(reset),.load_en(state==DW_LOAD),
        .load_addr({hrow,hcol}),.load_data(halo_load_data),.start(state==BUILD_START),
        .kh(kh),.kw(kw),.ay(ay),.ax(ax),.pad_kind(pad_kind),.pad_width(pad_width),
        .edges(edges),.valid_w(valid_w),.valid_h(valid_h),.build_done(windows_done),
        .rd_en(state==DW_TAPS && issue_valid),.rd_tap(tap_offset),.rd_data(window_data));

    reg [799:0] input_tile;
    reg [31:0] parameter_buffer;
    reg d1_valid,d2_valid,d1_last,d2_last;
    reg [1:0] d1_source;
    reg d1_bias,d2_bias,d1_const,d2_const;
    genvar p;
    generate for(p=0;p<100;p=p+1) begin: input_pixels
        localparam R=p/10,C=p%10;
        localparam PACK=((R/5)*2+C/5)*25+(R%5)*5+C%5;
        always @(posedge clk) begin
            if(d1_valid) case(d1_source)
                SRC_WINDOW:input_tile[p*8+:8]<=window_data[p*8+:8];
                SRC_CACHE:input_tile[p*8+:8]<=cache_data[PACK*8+:8];
                SRC_BIAS:input_tile[p*8+:8]<=8'd16;
                default:input_tile[p*8+:8]<=8'd1;
            endcase
        end
    end endgenerate
    always @(posedge clk) begin
        if(reset) begin
            d1_valid<=0;d2_valid<=0;d1_last<=0;d2_last<=0;
            d1_source<=0;d1_bias<=0;d2_bias<=0;d1_const<=0;d2_const<=0;
            parameter_buffer<=0;
        end else begin
            d1_valid<=issue_valid;d2_valid<=d1_valid;
            d1_last<=issue_valid && issue_last;d2_last<=d1_last;
            d1_source<=issue_source;
            d1_bias<=issue_bias;d2_bias<=d1_bias;
            d1_const<=issue_const;d2_const<=d1_const;
            if(param_valid) parameter_buffer<={parameter_buffer[15:0],param_data};
        end
    end
    wire signed [17:0] pe_weight=d2_const ? 18'sd128 :
        $signed({{2{parameter_buffer[15]}},parameter_buffer[15:0]})+
        (d2_bias && rounding ? 18'sd8 : 18'sd0);
    wire pe_clear=state==CLEAR && !keep_acc;
    wire [3199:0] pe_data;
    wire pe_valid,pe_last;
    mn_pe_array pes(.clk(clk),.reset(reset),.clear(pe_clear),
        .in_valid(d2_valid),.in_last(d2_last),.in_data(input_tile),
        .weight(pe_weight),.out_data(pe_data),.out_valid(pe_valid),.out_last(pe_last));
    wire qvalid,pvalid;
    wire [799:0] qdata;
    wire [199:0] pdata;
    mn_postprocess post(.clk(clk),.reset(reset),
        .in_valid(state==WAIT_PE && pe_valid && pe_last && !more_acc),
        .in_data(pe_data),.activation(activation),.valid_w(valid_w),.valid_h(valid_h),
        .tile_valid(qvalid),.tile_data(qdata),.pool_valid(pvalid),.pool_data(pdata));
    wire [199:0] sampled;
    generate for(p=0;p<25;p=p+1) begin: sampling
        localparam R=(p/5)*2,C=(p%5)*2;
        localparam PACK=((R/5)*2+C/5)*25+(R%5)*5+C%5;
        assign sampled[p*8+:8]=qdata[PACK*8+:8];
    end endgenerate
    reg [3:0] result_mask;
    always @* begin
        case(write_mode)
            0:result_mask=4'b1111;
            1:result_mask=4'b0001;
            2:result_mask=4'b0010;
            3:result_mask=4'b0100;
            4:result_mask=4'b1000;
            default:result_mask=0;
        endcase
    end
    wire [799:0] result_data=pool_enable ? {4{pdata}} : stride2 ? {4{sampled}} : qdata;
    mn_cache cache(.clk(clk),.reset(reset),
        .wr_en(state==WRITE),.wr_addr(dst_base),.wr_data(result_data),.wr_quadrants(result_mask),
        .rd_en(cache_rd_en),.rd_addr(cache_rd_addr),.rd_data(cache_data),.rd_valid(cache_valid),
        .host_wr(host_cache_wr && host_memory_ready),.host_rd(host_cache_rd && host_memory_ready),
        .host_waddr(host_cache_waddr),.host_raddr(host_cache_raddr),.host_wdata(host_cache_wdata),
        .host_mask(host_cache_wmask),.host_rdata(host_cache_rdata),.host_rvalid(host_cache_rvalid));

    wire [10:0] pw_end={1'b0,src_base}+channels;
    wire [12:0] param_end={1'b0,param_base}+
        (opcode==`MN_OP_DW ? kernel_area : opcode==`MN_OP_NORM ? 6'd2 : channels);
    wire bad_padding=opcode==`MN_OP_DW && edges!=0 &&
        (pad_kind==`MN_PAD_NONE || pad_width==0 || pad_width==2 ||
         (kernel==4 && pad_width<3));
    wire bad_command=opcode>`MN_OP_NOP || activation==3 || write_mode>4 ||
        cmd[61:58]>9 || cmd[65:62]>9 || cmd[127:90]!=0 ||
        (opcode==`MN_OP_PW && pw_end>1024) ||
        (opcode!=`MN_OP_NOP && param_end>4096) ||
        (opcode==`MN_OP_DW && (kernel>4 || tile_pitch==0 || row_pitch==0 || pad_kind==3)) ||
        ((pool_enable || stride2) && write_mode==0) || (pool_enable && stride2) ||
        (opcode==`MN_OP_NORM && channels!=1) || bad_padding ||
        (keep_acc && (opcode!=`MN_OP_PW || !acc_live || acc_dst!=dst_base || acc_round!=rounding)) ||
        (keep_acc && {1'b0,acc_channels}+{4'b0,channels}>10'd256) ||
        (more_acc && opcode!=`MN_OP_PW);

    always @(posedge clk) begin
        if(reset) begin
            state<=IDLE;cmd<=0;done<=0;error_code<=0;
            acc_live<=0;acc_dst<=0;acc_round<=0;acc_channels<=0;channel_idx<=0;
            owner<=4;hrow<=3;hcol<=3;missing_tile<=0;
            tap_row<=0;tap_col<=0;
        end else begin
            done<=0;
            case(state)
                IDLE:if(fifo_pop) begin cmd<=fifo_head;state<=CHECK;error_code<=0;end
                CHECK:begin
                    if(bad_command) begin error_code<=1;state<=COMPLETE;end
                    else if(opcode==`MN_OP_NOP) state<=COMPLETE;
                    else state<=CLEAR;
                end
                CLEAR:begin
                    channel_idx<=0;
                    acc_channels<=keep_acc ? acc_channels+channels : channels;
                    if(!keep_acc) acc_live<=0;
                    if(opcode==`MN_OP_NORM) state<=N_BIAS;
                    else if(rounding && !keep_acc) state<=ROUND;
                    else if(opcode==`MN_OP_DW) state<=DW_CENTER;
                    else state<=PW_RUN;
                end
                ROUND:state<=opcode==`MN_OP_DW ? DW_CENTER : PW_RUN;
                PW_RUN:begin
                    if(channel_idx==channels-1'b1) state<=WAIT_PE;
                    else channel_idx<=channel_idx+1'b1;
                end
                N_BIAS:state<=N_X;
                N_X:state<=WAIT_PE;
                DW_CENTER:begin owner<=4;missing_tile<=0;state<=DW_RET;end
                DW_SET:begin
                    if(!tile_absent && !neighbor_ok) begin error_code<=2;state<=COMPLETE;end
                    else begin missing_tile<=tile_absent;state<=DW_RET;end
                end
                DW_RET:begin hrow<=row_start;hcol<=col_start;state<=DW_LOAD;end
                DW_LOAD:begin
                    if(hcol!=col_end) hcol<=hcol+1'b1;
                    else if(hrow!=row_end) begin hcol<=col_start;hrow<=hrow+1'b1;end
                    else if(owner==8) state<=BUILD_START;
                    else begin
                        case(owner)
                            4:owner<=0;
                            3:owner<=5;
                            default:owner<=owner+1'b1;
                        endcase
                        state<=DW_SET;
                    end
                end
                BUILD_START:state<=BUILD_WAIT;
                BUILD_WAIT:if(windows_done) begin tap_row<=0;tap_col<=0;state<=DW_TAPS;end
                DW_TAPS:begin
                    if(last_position) state<=WAIT_PE;
                    else if(tap_col<kw-1'b1) tap_col<=tap_col+1'b1;
                    else begin tap_row<=tap_row+1'b1;tap_col<=0;end
                end
                WAIT_PE:if(pe_valid && pe_last) begin
                    if(more_acc) begin
                        acc_live<=1;acc_dst<=dst_base;acc_round<=rounding;state<=COMPLETE;
                    end else begin acc_live<=0;state<=WAIT_POST;end
                end
                WAIT_POST:if(pool_enable ? pvalid : qvalid) state<=WRITE;
                WRITE:state<=COMPLETE;
                COMPLETE:begin done<=1;state<=IDLE;end
                default:begin error_code<=15;state<=COMPLETE;end
            endcase
        end
    end
endmodule
