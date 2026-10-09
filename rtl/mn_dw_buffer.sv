// Shared 16x16 tile/halo buffer. Snake-order MACs rotate a column or row.
module mn_dw_buffer (
    input wire clk,reset,load_en,load_zero,
    input wire [3:0] load_owner,
    input wire [799:0] tile,
    input wire pad_en,pad_axis,pad_zero,
    input wire [3:0] pad_dst,pad_src,
    input wire rotate_en,
    input wire [1:0] rotate_dir,
    output wire [799:0] pixels
);
    reg [7:0] cell_data[0:255];
    wire [7:0] column[0:15],row[0:15];
    (* syn_keep=1 *) wire move_left=rotate_en && rotate_dir==0 && !reset;
    (* syn_keep=1 *) wire move_right=rotate_en && rotate_dir==1 && !reset;
    (* syn_keep=1 *) wire move_up=rotate_en && rotate_dir==2 && !reset;
    // CE selects the destination owner/row/column. Data masks select only
    // the active phase, allowing equal tile/column pairs to share one LUT.
    (* syn_keep=1 *) wire data_load=load_en && !load_zero && !reset;
    (* syn_keep=1 *) wire data_column=pad_en && !pad_axis && !pad_zero && !reset;
    (* syn_keep=1 *) wire data_row=pad_en && pad_axis && !pad_zero && !reset;
    wire [7:0] load_column[0:159];
    // A radius-three reflection source is at most local x/y=8 (grid 11).
    // For tiny tiles a reflected coordinate may reach the preceding halo.
    (* syn_keep=1 *) wire [11:0] select_pad=12'b1<<pad_src;
    genvar p,j;
    generate for(j=0;j<16;j=j+1) begin: padding_source
        reg [7:0] col_value,row_value;
        integer k;
        always @* begin
            col_value=0;row_value=0;
            for(k=0;k<12;k=k+1) begin
                col_value=col_value|(cell_data[j*16+k]&{8{select_pad[k]}});
                row_value=row_value|(cell_data[k*16+j]&{8{select_pad[k]}});
            end
        end
        assign column[j]=col_value;
        assign row[j]=row_value;
    end
    for(p=0;p<160;p=p+1) begin: shared_load_column
        localparam R=p/10,X=p%10,Y=R<3 ? R+7 : R<13 ? R-3 : R-13;
        localparam PACK=((Y/5)*2+X/5)*25+(Y%5)*5+X%5;
        (* syn_keep=1 *) wire [7:0] pair=(tile[PACK*8+:8]&{8{data_load}}) |
            (column[R]&{8{data_column}});
        assign load_column[p]=pair;
    end
    for(p=0;p<256;p=p+1) begin: buffer_cell
        localparam R=p/16,C=p%16;
        localparam OWNER=(R<3 ? 0 : R<13 ? 1 : 2)*3+(C<3 ? 0 : C<13 ? 1 : 2);
        localparam X=C<3 ? C+7 : C<13 ? C-3 : C-13;
        wire put_tile=load_en && load_owner==OWNER && !reset;
        wire put_col=pad_en && !pad_axis && pad_dst==C && !reset;
        wire put_row=pad_en && pad_axis && pad_dst==R && !reset;
        // These phases are mutually exclusive. One-hot terms avoid a
        // cascaded priority mux on every bit of the 256-byte register grid.
        wire [7:0] pair0=load_column[R*10+X];
        (* syn_keep=1 *) wire [7:0] pair1=(row[C]&{8{data_row}}) |
            (cell_data[R*16+(C+1)%16]&{8{move_left}});
        (* syn_keep=1 *) wire [7:0] pair2=(cell_data[R*16+(C+15)%16]&{8{move_right}}) |
            (cell_data[((R+1)%16)*16+C]&{8{move_up}});
        wire [7:0] next_data=pair0|pair1|pair2;
        always @(posedge clk) if(put_tile || put_col || put_row || rotate_en && !reset)
            cell_data[p]<=next_data;
    end
    for(p=0;p<100;p=p+1) begin: output_pixel
        localparam R=p/10,C=p%10;
        assign pixels[p*8+:8]=cell_data[R*16+C];
    end endgenerate
endmodule
