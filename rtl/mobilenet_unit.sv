`include "mn_isa.vh"
module mobilenet_unit #(parameter MODEL_PARAMS=0) (
    input wire clk,reset,
    input wire [127:0] instruction,
    input wire instruction_valid,
    output wire instruction_ready,
    output wire [2:0] instruction_count,
    input wire host_cache_wr,
    input wire [10:0] host_cache_waddr,
    input wire [799:0] host_cache_wdata,
    input wire [39:0] host_cache_wmask,
    input wire host_cache_rd,
    input wire [10:0] host_cache_raddr,
    output wire host_memory_ready,
    output wire [799:0] host_cache_rdata,
    output wire host_cache_rvalid,
    input wire host_param_wr,
    input wire [14:0] host_param_addr,
    input wire [15:0] host_param_data,
    output wire busy,
    output reg done,
    output reg [3:0] error_code
);
    localparam IDLE=0,CHECK=1,CLEAR=2,LOAD=3,LOAD_DRAIN=4,PAD_X=5,PAD_Y=6,
        DW_RUN=7,PW_RUN=8,N_X=9,ADD_FIRST=10,ADD_SECOND=11,
        WAIT_PE=12,WAIT_POST=13,WAIT_TANH=14,COMPLETE=15,ALIGN_X=16,ALIGN_Y=17;
    localparam SRC_WINDOW=0,SRC_CACHE=1,SRC_BIAS=2,SRC_ROUND=3;
    localparam [10:0] WINDOW_BASE=11'd1487; // Preserve the public V2 address limit.
    reg [4:0] state;
    reg [127:0] cmd;
    wire [3:0] opcode=cmd[3:0];
    wire [10:0] src_base={cmd[90],cmd[13:4]},dst_base={cmd[91],cmd[23:14]};
    wire [14:0] param_base={cmd[94:92],cmd[35:24]};
    wire ring_enable=cmd[95];
    wire [10:0] top_src=cmd[106:96],bottom_src=cmd[117:107];
    wire tanh_enable=cmd[118];
    wire spatial=opcode==`MN_OP_DW || opcode==`MN_OP_CONV;
    wire continuation=opcode==`MN_OP_PW || opcode==`MN_OP_CONV;
    wire [5:0] channels={1'b0,cmd[40:36]}+6'd1;
    wire [2:0] kernel=cmd[43:41];
    wire [1:0] activation=cmd[45:44];
    wire pool_enable=cmd[46];
    wire [2:0] write_mode=cmd[49:47];
    wire [1:0] pad_kind=cmd[51:50],pad_width=cmd[53:52];
    wire [3:0] edges=cmd[57:54],valid_w=cmd[61:58]+4'd1,valid_h=cmd[65:62]+4'd1;
    wire [9:0] tile_pitch=cmd[75:66],row_pitch=cmd[85:76];
    wire rounding=cmd[86],keep_acc=cmd[87],more_acc=cmd[88],stride2=cmd[89];
    reg [2:0] kh,kw;
    wire [1:0] origin=kernel==4 ? 0 : kernel==3 ? 2 : 3;
    always @* begin
        kh=1;kw=2;
        case(kernel)
            1:begin kh=2;kw=1;end
            2:begin kh=2;kw=2;end
            3:begin kh=3;kw=3;end
            4:begin kh=7;kw=7;end
            5:begin kh=1;kw=1;end
            default:;
        endcase
    end
    wire [5:0] kernel_area=kernel==5 ? 1 : kernel==4 ? 49 : kernel==3 ? 9 : kernel==2 ? 4 : 2;
    wire [127:0] fifo_head;
    wire fifo_valid;
    wire fifo_pop=state==IDLE && fifo_valid && !reset && !(host_cache_wr || host_cache_rd || host_param_wr);
    mn_instruction_fifo fifo(.clk(clk),.reset(reset),.in_data(instruction),
        .in_valid(instruction_valid),.in_ready(instruction_ready),.out_data(fifo_head),
        .out_valid(fifo_valid),.out_ready(fifo_pop),.count(instruction_count));
    assign busy=state!=IDLE;
    assign host_memory_ready=state==IDLE && !reset;
    reg acc_live,acc_round;
    reg [10:0] acc_dst;
    reg [8:0] acc_channels;
    wire [5:0] terms=spatial ? kernel_area : channels;
    reg [5:0] channel_idx;
    reg [3:0] owner;
    wire [1:0] owner_row=owner<3 ? 0 : owner<6 ? 1 : 2;
    wire [1:0] owner_col=owner==0 || owner==3 || owner==6 ? 0 : owner==1 || owner==4 || owner==7 ? 1 : 2;
    wire tile_absent=(owner_row==0 && edges[2]) || (owner_row==2 && edges[3]) ||
        (owner_col==0 && edges[0]) || (owner_col==2 && edges[1]);
    reg signed [13:0] neighbor_addr;
    always @* begin
        neighbor_addr=$signed({3'b0,src_base});
        if(owner_row==0) neighbor_addr=ring_enable ? $signed({3'b0,top_src}) : neighbor_addr-$signed({4'b0,row_pitch});
        if(owner_row==2) neighbor_addr=ring_enable ? $signed({3'b0,bottom_src}) : neighbor_addr+$signed({4'b0,row_pitch});
        if(owner_col==0) neighbor_addr=neighbor_addr-$signed({4'b0,tile_pitch});
        if(owner_col==2) neighbor_addr=neighbor_addr+$signed({4'b0,tile_pitch});
    end
    wire signed [13:0] upper_base=ring_enable ? $signed({3'b0,top_src}) : $signed({3'b0,src_base})-$signed({4'b0,row_pitch});
    wire signed [13:0] lower_base=ring_enable ? $signed({3'b0,bottom_src}) : $signed({3'b0,src_base})+$signed({4'b0,row_pitch});
    wire signed [13:0] signed_pitch=$signed({4'b0,tile_pitch});
    wire bad_neighbors=
        (!edges[0] && $signed({3'b0,src_base})-signed_pitch<0) ||
        (!edges[1] && $signed({3'b0,src_base})+signed_pitch>=WINDOW_BASE) ||
        (!edges[2] && (upper_base<0 || upper_base>=WINDOW_BASE ||
            (!edges[0] && upper_base-signed_pitch<0) || (!edges[1] && upper_base+signed_pitch>=WINDOW_BASE))) ||
        (!edges[3] && (lower_base<0 || lower_base>=WINDOW_BASE ||
            (!edges[0] && lower_base-signed_pitch<0) || (!edges[1] && lower_base+signed_pitch>=WINDOW_BASE)));

    wire reflect_pad=pad_kind==2;
    wire need_left=reflect_pad && edges[0],need_right=edges[1] && (reflect_pad || valid_w!=10);
    wire need_top=reflect_pad && edges[2],need_bottom=edges[3] && (reflect_pad || valid_h!=10);
    wire need_x=need_left || need_right,need_y=need_top || need_bottom;
    reg pad_side;
    reg [1:0] pad_idx;
    wire pad_axis=state==PAD_Y;
    wire [3:0] extent=pad_axis ? valid_h : valid_w;
    wire lower_edge=pad_axis ? edges[2] : edges[0],upper_edge=pad_axis ? edges[3] : edges[1];
    wire [3:0] pad_dst=pad_side ? extent+4'd3+pad_idx : {2'b0,pad_idx};
    wire signed [6:0] pad_local=$signed({3'b0,pad_dst})-7'sd3;
    function automatic signed [6:0] reflected;
        input signed [6:0] v;
        input [3:0] n;
        input lo,hi;
        reg signed [6:0] t,size;
        begin
            t=v;size=$signed({3'b0,n});
            if(lo && hi && n==1) t=0;
            else if(lo && hi && n==2) t=$signed({6'b0,v[0]});
            else if(lo && hi && n==3) begin
                case(v[1:0]) 0:t=0;2:t=2;default:t=1;endcase
            end else begin
                if(lo && t<0) t=-t;
                if(hi && t>=size) t=(size<<<1)-7'sd2-t;
            end
            reflected=t;
        end
    endfunction
    wire signed [6:0] pad_mapped=reflected(pad_local,extent,lower_edge,upper_edge)+7'sd3;
    wire pad_zero=!reflect_pad || (lower_edge && pad_local<-$signed({5'b0,pad_width})) ||
        (upper_edge && pad_local>=$signed({3'b0,extent})+$signed({5'b0,pad_width}));
    wire pad_last=pad_idx==2 && (pad_side || !(pad_axis ? need_bottom : need_right));
    reg [1:0] align_idx;
    wire buffer_ready=(state==LOAD_DRAIN && !need_x && !need_y) ||
        (state==PAD_X && pad_last && !need_y) || (state==PAD_Y && pad_last);
    wire dw_start=(buffer_ready && origin==0) || (state==ALIGN_Y && align_idx==origin-1'b1);
    reg [2:0] tap_row,tap_col;
    wire row_end=tap_row[0] ? tap_col==0 : tap_col==kw-1'b1;
    wire tap_last=tap_row==kh-1'b1 && row_end;
    wire [5:0] tap_offset=kernel==4 ? ({3'b0,tap_row}<<3)-tap_row+tap_col :
        kernel==3 ? ({3'b0,tap_row}<<1)+tap_row+tap_col :
        kernel==2 ? ({3'b0,tap_row}<<1)+tap_col : kernel==1 ? {3'b0,tap_row} : {3'b0,tap_col};
    wire [1:0] tap_direction=row_end ? 2 : tap_row[0] ? 1 : 0;
    reg issue_valid,issue_last,issue_bias,issue_const,issue_add,load_request,load_zero;
    reg [3:0] issue_owner;
    reg [1:0] issue_source,issue_direction;
    reg [5:0] issue_tap;
    reg [14:0] issue_param;
    reg cache_rd_en;
    reg [10:0] cache_rd_addr;
    wire [799:0] cache_data;
    wire cache_valid;
    always @* begin
        issue_valid=0;issue_last=0;issue_bias=0;issue_const=0;issue_add=0;
        issue_source=SRC_CACHE;issue_param=param_base;issue_direction=tap_direction;issue_tap=tap_offset;
        load_request=0;load_zero=0;issue_owner=4;cache_rd_en=0;cache_rd_addr=src_base;
        case(state)
            CLEAR:begin
                if(spatial && kernel!=5) begin
                    load_request=1;cache_rd_en=1;
                    if(rounding && !keep_acc) begin issue_valid=1;issue_source=SRC_ROUND;issue_const=1;end
                end else begin
                    issue_valid=1;
                    if(opcode==`MN_OP_NORM) begin issue_source=SRC_BIAS;issue_bias=1;issue_param=param_base+15'd1;end
                    else if(rounding && !keep_acc) begin issue_source=SRC_ROUND;issue_const=1;end
                    else begin cache_rd_en=1;if(opcode==`MN_OP_ADD) issue_add=1;else issue_last=channels==1;end
                end
            end
            LOAD:begin
                load_request=1;load_zero=tile_absent;issue_owner=owner;
                cache_rd_en=!tile_absent;cache_rd_addr=neighbor_addr[10:0];
            end
            PW_RUN:begin issue_valid=1;issue_last=channel_idx==channels-1'b1;cache_rd_en=1;
                issue_param=param_base+channel_idx;cache_rd_addr=src_base+channel_idx;end
            N_X:begin issue_valid=1;issue_last=1;cache_rd_en=1;end
            ADD_FIRST:begin issue_valid=1;issue_add=1;cache_rd_en=1;end
            ADD_SECOND:begin issue_valid=1;issue_last=1;issue_add=1;cache_rd_en=1;cache_rd_addr=param_base[10:0];end
            DW_RUN:begin issue_valid=1;issue_last=tap_last;issue_source=SRC_WINDOW;issue_param=param_base+tap_offset;end
            default:;
        endcase
        if(dw_start) begin
            issue_valid=1;issue_source=SRC_WINDOW;issue_param=param_base;
            issue_tap=0;issue_direction=kw==1 ? 2 : 0;
        end
        if(reset) begin issue_valid=0;cache_rd_en=0;load_request=0;end
    end
    wire [15:0] param_data;
    wire param_valid;
    generate if(MODEL_PARAMS) begin: model_parameters
        mn_model_rom parameters(.clk(clk),.rd_en(issue_valid && !issue_const && !issue_add),.addr(issue_param),.data(param_data));
        reg pv;always @(posedge clk) if(reset) pv<=0;else pv<=issue_valid && !issue_const && !issue_add;
        assign param_valid=pv;
    end else begin: writable_parameters
        mn_param_ram parameters(.clk(clk),.reset(reset),.wr_en(host_param_wr && host_memory_ready),
            .wr_addr(host_param_addr[11:0]),.wr_data(host_param_data),.rd_en(issue_valid && !issue_const && !issue_add),
            .rd_addr(issue_param[11:0]),.rd_data(param_data),.rd_valid(param_valid));
    end endgenerate
    reg d1_valid,d1_last,d1_bias,d1_const,d1_add,d1_load,d1_zero;
    reg [3:0] d1_owner;
    reg [1:0] d1_source,d1_direction;
    reg [5:0] d1_tap;
    always @(posedge clk) begin
        if(reset) begin
            d1_valid<=0;d1_last<=0;d1_bias<=0;d1_const<=0;d1_add<=0;d1_load<=0;d1_zero<=0;
            d1_owner<=0;d1_source<=0;d1_direction<=0;d1_tap<=0;
        end else begin
            d1_valid<=issue_valid;d1_last<=issue_valid && issue_last;d1_bias<=issue_bias;
            d1_const<=issue_const;d1_add<=issue_add;d1_source<=issue_source;
            d1_load<=load_request;d1_zero<=load_zero;d1_owner<=issue_owner;d1_direction<=issue_direction;d1_tap<=issue_tap;
        end
    end
    wire [799:0] window_pixels,input_tile;
    mn_dw_buffer windows(.clk(clk),.reset(reset),.load_en(d1_load),.load_zero(d1_zero),.load_owner(d1_owner),.tile(cache_data),
        .pad_en(state==PAD_X || state==PAD_Y),.pad_axis(pad_axis),.pad_zero(pad_zero),.pad_dst(pad_dst),.pad_src(pad_mapped[3:0]),
        .rotate_en((d1_valid && d1_source==SRC_WINDOW && !d1_last) || state==ALIGN_X || state==ALIGN_Y),
        .rotate_dir(state==ALIGN_X ? 2'd0 : state==ALIGN_Y ? 2'd2 : d1_direction),.pixels(window_pixels));
    mn_input_mux input_mux(.source(d1_source),.window_pixels(window_pixels),
        .cache_data(cache_data),.pixels(input_tile));
    genvar p;
    wire signed [17:0] pe_weight=d1_add ? 18'sd256 : d1_const ? 18'sd128 :
        $signed({{2{param_data[15]}},param_data})+(d1_bias && rounding ? 18'sd8 : 18'sd0);
    wire [3199:0] pe_data;
    wire pe_valid,pe_last;
    mn_pe_array pes(.clk(clk),.reset(reset),.clear(state==CLEAR && !keep_acc),.in_valid(d1_valid),
        .in_last(d1_last),.in_data(input_tile),.weight(pe_weight),.out_data(pe_data),.out_valid(pe_valid),.out_last(pe_last));
    wire qvalid,pvalid,tanh_valid;
    wire [799:0] qdata,tanh_data;
    wire [199:0] pdata;
    wire result_write=(state==WAIT_POST && (pool_enable ? pvalid : qvalid)) || (state==WAIT_TANH && tanh_valid);
    mn_tanh_tile tanh_post(.clk(clk),.rstn(!reset),.start(state==WAIT_PE && pe_valid && pe_last && !more_acc && tanh_enable),
        .in_data(pe_data),.busy(),.valid(tanh_valid),.ready(result_write),.data(tanh_data));
    mn_postprocess post(.clk(clk),.reset(reset),.in_valid(state==WAIT_PE && pe_valid && pe_last && !more_acc && !tanh_enable),
        .in_data(pe_data),.activation(activation),.valid_w(valid_w),.valid_h(valid_h),
        .tile_valid(qvalid),.tile_data(qdata),.pool_valid(pvalid),.pool_data(pdata));
    wire [199:0] sampled;
    generate for(p=0;p<25;p=p+1) begin: sampling
        localparam R=(p/5)*2,C=(p%5)*2,PACK=((R/5)*2+C/5)*25+(R%5)*5+C%5;
        assign sampled[p*8+:8]=qdata[PACK*8+:8];
    end endgenerate
    reg [3:0] result_mask;
    always @* case(write_mode)
        0:result_mask=15;1:result_mask=1;2:result_mask=2;3:result_mask=4;4:result_mask=8;default:result_mask=0;
    endcase
    wire [199:0] small_result=pool_enable ? pdata : sampled;
    wire write_small=!tanh_enable && (pool_enable || stride2);
    wire write_tile=!tanh_enable && !pool_enable && !stride2;
    wire [799:0] result_data=(tanh_data&{800{tanh_enable}}) |
        ({4{small_result}}&{800{write_small}}) | (qdata&{800{write_tile}});
    mn_cache cache(.clk(clk),.reset(reset),.wr_en(result_write),.wr_addr(dst_base),.wr_data(result_data),.wr_quadrants(result_mask),
        .rd_en(cache_rd_en),.rd_addr(cache_rd_addr),.rd_data(cache_data),.rd_valid(cache_valid),
        .host_wr(host_cache_wr && host_memory_ready),.host_rd(host_cache_rd && host_memory_ready),
        .host_waddr(host_cache_waddr),.host_raddr(host_cache_raddr),.host_wdata(host_cache_wdata),.host_mask(host_cache_wmask),
        .host_rdata(host_cache_rdata),.host_rvalid(host_cache_rvalid));
    wire [11:0] pw_end={1'b0,src_base}+channels;
    wire [15:0] param_end={1'b0,param_base}+(spatial ? kernel_area : opcode==`MN_OP_NORM ? 6'd2 : channels);
    wire bad_padding=spatial && edges!=0 && (pad_kind==`MN_PAD_NONE || pad_width==0 || pad_width==2 || (kernel==4 && pad_width<3));
    wire bad_command=opcode>`MN_OP_ADD || activation==3 || write_mode>4 || cmd[61:58]>9 || cmd[65:62]>9 || cmd[127:119]!=0 ||
        (opcode!=`MN_OP_NOP && (src_base>=WINDOW_BASE || dst_base>=WINDOW_BASE)) || (opcode==`MN_OP_PW && pw_end>WINDOW_BASE) ||
        (opcode==`MN_OP_ADD ? param_base>=WINDOW_BASE : opcode!=`MN_OP_NOP && param_end>(MODEL_PARAMS ? 21603 : 4096)) ||
        (spatial && (kernel>5 || channels!=1 || tile_pitch==0 || row_pitch==0 || pad_kind==3)) ||
        ((pool_enable || stride2) && write_mode==0) || (pool_enable && stride2) || (opcode==`MN_OP_NORM && channels!=1) || bad_padding ||
        (keep_acc && (!continuation || !acc_live || acc_dst!=dst_base || acc_round!=rounding)) ||
        (keep_acc && {1'b0,acc_channels}+{4'b0,terms}>(opcode==`MN_OP_CONV ? 10'd511 : 10'd256)) ||
        (more_acc && !continuation) || (tanh_enable && (opcode!=`MN_OP_CONV || activation!=0 || pool_enable || stride2 || write_mode!=0 || rounding));
    always @(posedge clk) begin
        if(reset) begin
            state<=IDLE;cmd<=0;done<=0;error_code<=0;acc_live<=0;acc_dst<=0;acc_round<=0;acc_channels<=0;
            channel_idx<=0;owner<=0;pad_side<=0;pad_idx<=0;tap_row<=0;tap_col<=0;align_idx<=0;
        end else begin
            done<=0;
            case(state)
                IDLE:if(fifo_pop) begin cmd<=fifo_head;state<=CHECK;error_code<=0;end
                CHECK:begin
                    if(bad_command) begin error_code<=1;state<=COMPLETE;end
                    else if(spatial && kernel!=5 && bad_neighbors) begin error_code<=2;state<=COMPLETE;end
                    else if(opcode==`MN_OP_NOP) state<=COMPLETE;
                    else state<=CLEAR;
                end
                CLEAR:begin
                    acc_channels<=keep_acc ? acc_channels+terms : terms;if(!keep_acc) acc_live<=0;
                    channel_idx<=rounding && !keep_acc ? 0 : 1;
                    if(spatial && kernel!=5) begin owner<=0;state<=LOAD;end
                    else if(opcode==`MN_OP_NORM) state<=N_X;
                    else if(rounding && !keep_acc) state<=opcode==`MN_OP_ADD ? ADD_FIRST : PW_RUN;
                    else if(opcode==`MN_OP_ADD) state<=ADD_SECOND;
                    else state<=channels==1 ? WAIT_PE : PW_RUN;
                end
                LOAD:begin
                    if(owner==8) state<=LOAD_DRAIN;
                    else owner<=owner==3 ? 5 : owner+1'b1;
                end
                LOAD_DRAIN:begin
                    if(need_x) begin pad_side<=!need_left;pad_idx<=0;state<=PAD_X;end
                    else if(need_y) begin pad_side<=!need_top;pad_idx<=0;state<=PAD_Y;end
                end
                PAD_X,PAD_Y:begin
                    if(pad_last) begin
                        if(state==PAD_X && need_y) begin pad_side<=!need_top;pad_idx<=0;state<=PAD_Y;end
                    end else if(pad_idx==2) begin pad_idx<=0;pad_side<=1;end
                    else pad_idx<=pad_idx+1'b1;
                end
                DW_RUN:begin
                    if(tap_last) state<=WAIT_PE;
                    else if(row_end) tap_row<=tap_row+1'b1;
                    else tap_col<=tap_row[0] ? tap_col-1'b1 : tap_col+1'b1;
                end
                ALIGN_X:if(align_idx==origin-1'b1) begin align_idx<=0;state<=ALIGN_Y;end
                    else align_idx<=align_idx+1'b1;
                ALIGN_Y:align_idx<=align_idx+1'b1;
                PW_RUN:if(channel_idx==channels-1'b1) state<=WAIT_PE;else channel_idx<=channel_idx+1'b1;
                N_X,ADD_SECOND:state<=WAIT_PE;
                ADD_FIRST:state<=ADD_SECOND;
                WAIT_PE:if(pe_valid && pe_last) begin
                    if(more_acc) begin acc_live<=1;acc_dst<=dst_base;acc_round<=rounding;state<=COMPLETE;end
                    else begin acc_live<=0;state<=tanh_enable ? WAIT_TANH : WAIT_POST;end
                end
                WAIT_POST:if(pool_enable ? pvalid : qvalid) state<=COMPLETE;
                WAIT_TANH:if(tanh_valid) state<=COMPLETE;
                COMPLETE:begin done<=1;state<=IDLE;end
                default:begin error_code<=15;state<=COMPLETE;end
            endcase
            if(buffer_ready && origin!=0) begin align_idx<=0;state<=ALIGN_X;end
            if(dw_start) begin
                tap_row<=kw==1 ? 1 : 0;tap_col<=kw==1 ? 0 : 1;state<=DW_RUN;
            end
        end
    end
endmodule
