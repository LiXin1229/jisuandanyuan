// Static 16x16 backing store: bank=(row+column)%8, address={row,column[3]}.
// Two 8-bit TDP ports per bank read/write all 16 positions of any row/column.
// Only the live 10x10 PE window moves; each movement consumes one prefetched
// 10-byte border. Tile data must remain stable until load_done.
module mn_dw_buffer_bram (
    input wire clk,reset,load_en,load_zero,
    input wire [3:0] load_owner,
    input wire [799:0] tile,
    output reg load_done,
    output wire load_last,
    input wire pad_en,pad_axis,pad_zero,
    input wire [3:0] pad_dst,pad_src,
    output reg pad_done,
    input wire init_start,
    input wire [2:0] init_x,init_y,
    output reg init_done,
    input wire prefetch_en,
    input wire [1:0] prefetch_dir,
    input wire rotate_en,
    input wire [1:0] rotate_dir,
    output wire [799:0] pixels
);
    localparam IDLE=0,STORE=1,PAD_WRITE=2,INIT_READ=3,INIT_DRAIN=4;
    reg [2:0] state;
    reg [3:0] store_row,store_end,owner_q;
    reg zero_q,pad_axis_q,pad_zero_q;
    reg [3:0] pad_dst_q;
    reg [3:0] x,y;
    reg [3:0] init_row;
    reg [2:0] init_x_q,init_y_q;
    reg read_init_q;
    reg [3:0] init_tag_q;
    reg [2:0] read_fixed_q,read_shift_q;
    reg [7:0] cell_data[0:99];

    wire start_load=state==IDLE && load_en && !reset;
    assign load_last=state==STORE && store_row==store_end && !reset;
    wire store=state==STORE || start_load;
    wire pad_write=state==PAD_WRITE;
    wire [3:0] active_owner=start_load ? load_owner : owner_q;
    wire [3:0] first_row=load_owner<3 ? 0 : load_owner<6 ? 3 : 13;
    wire [3:0] write_fixed=store ? (start_load ? first_row : store_row) : pad_dst_q;
    wire [1:0] owner_col=active_owner==0 || active_owner==3 || active_owner==6 ? 0 :
                         active_owner==1 || active_owner==4 || active_owner==7 ? 1 : 2;
    wire write_axis=store || pad_axis_q;
    wire [3:0] tile_y=write_fixed<3 ? write_fixed+7 : write_fixed<13 ? write_fixed-3 : write_fixed-13;
    wire [9:0] select_tile=(start_load ? load_zero : zero_q) ? 10'b0 : 10'b1<<tile_y;
    wire [79:0] tile_row;
    genvar c,r,b;
    generate for(c=0;c<10;c=c+1) begin: select_tile_column
        reg [7:0] selected;
        integer k;
        always @* begin
            selected=0;
            for(k=0;k<10;k=k+1)
                selected=selected | (tile[(((k/5)*2+c/5)*25+(k%5)*5+c%5)*8+:8]&{8{select_tile[k]}});
        end
        assign tile_row[c*8+:8]=selected;
    end endgenerate

    wire [63:0] bank_a,bank_b;
    wire [127:0] ordered_a={bank_a,bank_a} >> {read_fixed_q,3'b0};
    wire [127:0] ordered_b={bank_b,bank_b} >> {read_fixed_q,3'b0};
    wire [127:0] line_data={ordered_b[63:0],ordered_a[63:0]};
    wire [127:0] shifted_line=line_data >> {read_shift_q,3'b0};
    wire [79:0] border=shifted_line[79:0];
    wire [127:0] write_line;
    generate for(c=0;c<16;c=c+1) begin: write_pixel
        localparam X=c<3 ? c+7 : c<13 ? c-3 : c-13;
        assign write_line[c*8+:8]=store ? tile_row[X*8+:8] : (pad_zero_q ? 8'b0 : line_data[c*8+:8]);
    end endgenerate
    wire [2:0] write_rotation=-write_fixed[2:0];
    wire [127:0] write_a={write_line[63:0],write_line[63:0]} >> {write_rotation,3'b0};
    wire [127:0] write_b={write_line[127:64],write_line[127:64]} >> {write_rotation,3'b0};

    // Prefetch addresses account for the movement being consumed on this edge.
    // The request issued with tap N supplies the border for tap N's movement
    // one clock later; a simultaneous movement belongs to tap N-1.
    wire [3:0] after_x=x+(rotate_en && rotate_dir==0 ? 4'd1 : rotate_en && rotate_dir==1 ? 4'hf : 4'd0);
    wire [3:0] after_y=y+(rotate_en && rotate_dir==2 ? 4'd1 : 4'd0);
    wire init_read=(state==IDLE && init_start) || state==INIT_READ;
    wire [3:0] init_index=state==IDLE ? 0 : init_row;
    wire [2:0] init_origin_x=state==IDLE ? init_x : init_x_q;
    wire [2:0] init_origin_y=state==IDLE ? init_y : init_y_q;
    wire pad_read=state==IDLE && pad_en;
    wire prefetch=state==IDLE && prefetch_en;
    wire read_enable=(init_read || pad_read || prefetch) && !reset;
    wire read_axis=init_read || (pad_read ? pad_axis : prefetch_dir==2);
    wire [3:0] read_fixed=init_read ? {1'b0,init_origin_y}+init_index : pad_read ? pad_src :
        prefetch_dir==2 ? after_y+4'd10 : prefetch_dir==0 ? after_x+4'd10 : after_x-1'b1;
    wire [2:0] read_shift=init_read ? init_origin_x : pad_read ? 3'd0 : prefetch_dir==2 ? after_x[2:0] : after_y[2:0];

    generate for(b=0;b<8;b=b+1) begin: bank
        localparam [2:0] BANK=b;
        wire [2:0] read_position=BANK-read_fixed[2:0];
        wire [2:0] write_position=BANK-write_fixed[2:0];
        wire [4:0] ra=read_axis ? {read_fixed,1'b0} : {1'b0,read_position,read_fixed[3]};
        wire [4:0] rb=read_axis ? {read_fixed,1'b1} : {1'b1,read_position,read_fixed[3]};
        wire [4:0] wa=write_axis ? {write_fixed,1'b0} : {1'b0,write_position,write_fixed[3]};
        wire [4:0] wb=write_axis ? {write_fixed,1'b1} : {1'b1,write_position,write_fixed[3]};
        wire [3:0] ca={1'b0,write_position},cb={1'b1,write_position};
        wire mask_a=owner_col==0 ? ca<3 : owner_col==1 ? ca>=3 && ca<13 : ca>=13;
        wire mask_b=owner_col==0 ? cb<3 : owner_col==1 ? cb>=3 && cb<13 : cb>=13;
        wire wea=(pad_write || store && mask_a) && !reset;
        wire web=(pad_write || store && mask_b) && !reset;
        EFX_DPRAM10 #(.READ_WIDTH_A(8),.WRITE_WIDTH_A(8),.READ_WIDTH_B(8),.WRITE_WIDTH_B(8),
            .OUTPUT_REG_A(0),.OUTPUT_REG_B(0),.WRITE_MODE_A("NO_CHANGE"),.WRITE_MODE_B("NO_CHANGE")) ram (
            .CLKA(clk),.WEA(wea),.CLKEA(wea || read_enable),.RSTA(reset),.ADDRENA(wea || read_enable),
            .WDATAA(write_a[b*8+:8]),.ADDRA({5'b0,wea ? wa : ra}),.RDATAA(bank_a[b*8+:8]),
            .CLKB(clk),.WEB(web),.CLKEB(web || read_enable),.RSTB(reset),.ADDRENB(web || read_enable),
            .WDATAB(write_b[b*8+:8]),.ADDRB({5'b0,web ? wb : rb}),.RDATAB(bank_b[b*8+:8]));
    end endgenerate

    (* syn_keep=1 *) wire left=rotate_en && rotate_dir==0 && !reset;
    (* syn_keep=1 *) wire right=rotate_en && rotate_dir==1 && !reset;
    (* syn_keep=1 *) wire up=rotate_en && rotate_dir==2 && !reset;
    (* syn_keep=1 *) wire initialize=read_init_q && !reset;
    wire [79:0] initial_line=border&{80{initialize}};
    generate for(r=0;r<10;r=r+1) begin: active_row
        for(c=0;c<10;c=c+1) begin: active_col
            localparam P=r*10+c;
            wire [7:0] lvalue,rvalue,uvalue;
            if(c==9) assign lvalue=border[r*8+:8];else assign lvalue=cell_data[P+1];
            if(c==0) assign rvalue=border[r*8+:8];else assign rvalue=cell_data[P-1];
            if(r==9) assign uvalue=border[c*8+:8];else assign uvalue=cell_data[P+10];
            (* syn_keep=1 *) wire [7:0] pair0=(lvalue&{8{left}})|(rvalue&{8{right}});
            (* syn_keep=1 *) wire [7:0] pair1=(uvalue&{8{up}})|initial_line[c*8+:8];
            always @(posedge clk) if(!reset && (rotate_en || read_init_q && init_tag_q==r))
                cell_data[P]<=pair0|pair1;
            assign pixels[P*8+:8]=cell_data[P];
        end
    end endgenerate
    always @(posedge clk) begin
        load_done<=0;pad_done<=0;init_done<=0;
        read_init_q<=read_enable && init_read;
        if(read_enable) begin read_fixed_q<=read_fixed[2:0];read_shift_q<=read_shift;init_tag_q<=init_index;end
        if(reset) begin
            state<=IDLE;load_done<=0;pad_done<=0;init_done<=0;read_init_q<=0;
            x<=0;y<=0;store_row<=0;store_end<=0;owner_q<=0;zero_q<=0;
            pad_axis_q<=0;pad_dst_q<=0;pad_zero_q<=0;
            init_row<=0;init_x_q<=0;init_y_q<=0;read_fixed_q<=0;read_shift_q<=0;init_tag_q<=0;
        end else begin
            if(rotate_en) begin x<=after_x;y<=after_y;end
            case(state)
                IDLE:begin
                    if(load_en) begin
                        owner_q<=load_owner;zero_q<=load_zero;store_row<=first_row+1'b1;
                        store_end<=load_owner<3 ? 2 : load_owner<6 ? 12 : 15;state<=STORE;
                    end else if(pad_en) begin
                        pad_axis_q<=pad_axis;pad_dst_q<=pad_dst;pad_zero_q<=pad_zero;state<=PAD_WRITE;
                    end else if(init_start) begin
                        init_x_q<=init_x;init_y_q<=init_y;x<={1'b0,init_x};y<={1'b0,init_y};
                        init_row<=1;state<=INIT_READ;
                    end
                end
                STORE:if(store_row==store_end) begin load_done<=1;state<=IDLE;end
                    else store_row<=store_row+1'b1;
                PAD_WRITE:begin pad_done<=1;state<=IDLE;end
                INIT_READ:if(init_row==9) state<=INIT_DRAIN;else init_row<=init_row+1'b1;
                INIT_DRAIN:if(read_init_q && init_tag_q==9) begin init_done<=1;state<=IDLE;end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
