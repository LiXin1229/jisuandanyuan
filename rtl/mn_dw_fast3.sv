// Full 10x10 tile, radius-one halo: nine tile reads, nine consecutive MACs.
// Retain the center and four borders (140 bytes); bypass incoming corners.
// owner is the row-major neighbor/tap number, scheduled 4,1,7,3,5,0,2,6,8.
module mn_dw_fast3 (
    input wire clk, reset, accept,
    input wire [3:0] owner,
    input wire [3:0] edges,
    input wire [1:0] pad_kind,
    input wire [799:0] tile,
    output wire [799:0] pixels
);
    wire [7:0] incoming[0:99];
    reg [7:0] center[0:99],top[0:9],bottom[0:9],left[0:9],right[0:9];
    wire [7:0] top_in[0:9],bottom_in[0:9],left_in[0:9],right_in[0:9];
    wire [7:0] tl,tr,bl,br;
    wire reflect_pad=pad_kind==2;
    wire [8:0] select_tap=9'b1<<owner;
    genvar p,j,k;
    generate for(p=0;p<100;p=p+1) begin: center_pixel
        localparam R=p/10,C=p%10,PACK=((R/5)*2+C/5)*25+(R%5)*5+C%5;
        assign incoming[p]=tile[PACK*8+:8];
        always @(posedge clk) if(accept && !reset && owner==4) center[p]<=incoming[p];
    end
    for(j=0;j<10;j=j+1) begin: border
        assign top_in[j]=edges[2] ? (reflect_pad ? center[10+j] : 8'd0) : incoming[90+j];
        assign bottom_in[j]=edges[3] ? (reflect_pad ? center[80+j] : 8'd0) : incoming[j];
        assign left_in[j]=edges[0] ? (reflect_pad ? center[j*10+1] : 8'd0) : incoming[j*10+9];
        assign right_in[j]=edges[1] ? (reflect_pad ? center[j*10+8] : 8'd0) : incoming[j*10];
        always @(posedge clk) if(accept && !reset) begin
            if(owner==1) top[j]<=top_in[j];
            if(owner==7) bottom[j]<=bottom_in[j];
            if(owner==3) left[j]<=left_in[j];
            if(owner==5) right[j]<=right_in[j];
        end
    end endgenerate
    // Side borders are loaded before corners. Reflection in one axis uses
    // the already loaded opposite-axis side; reflection in both uses center.
    assign tl=edges[2] || edges[0] ? (!reflect_pad ? 8'd0 :
        edges[2] && edges[0] ? center[11] : edges[2] ? left[1] : top[1]) : incoming[99];
    assign tr=edges[2] || edges[1] ? (!reflect_pad ? 8'd0 :
        edges[2] && edges[1] ? center[18] : edges[2] ? right[1] : top[8]) : incoming[90];
    assign bl=edges[3] || edges[0] ? (!reflect_pad ? 8'd0 :
        edges[3] && edges[0] ? center[81] : edges[3] ? left[8] : bottom[1]) : incoming[9];
    assign br=edges[3] || edges[1] ? (!reflect_pad ? 8'd0 :
        edges[3] && edges[1] ? center[88] : edges[3] ? right[8] : bottom[8]) : incoming[0];
    generate for(p=0;p<100;p=p+1) begin: select_pixel
        localparam R=p/10,C=p%10;
        wire [7:0] term[0:8];
        for(k=0;k<9;k=k+1) begin: tap
            localparam Y=R+k/3-1,X=C+k%3-1;
            wire [7:0] sample;
            // Center MAC bypasses this selector in the executor. Only the
            // four cardinal MACs use live edge data; diagonals use storage.
            if(k==4) assign sample=0;
            else if(Y>=0 && Y<10 && X>=0 && X<10) assign sample=center[Y*10+X];
            else if(Y<0 && X>=0 && X<10) assign sample=k==1 ? top_in[X] : top[X];
            else if(Y>=10 && X>=0 && X<10) assign sample=k==7 ? bottom_in[X] : bottom[X];
            else if(X<0 && Y>=0 && Y<10) assign sample=k==3 ? left_in[Y] : left[Y];
            else if(X>=10 && Y>=0 && Y<10) assign sample=k==5 ? right_in[Y] : right[Y];
            else if(Y<0) assign sample=X<0 ? tl : tr;
            else assign sample=X<0 ? bl : br;
            assign term[k]=sample&{8{select_tap[k]}};
        end
        assign pixels[p*8+:8]=term[0]|term[1]|term[2]|term[3]|term[5]|term[6]|term[7]|term[8];
    end endgenerate
endmodule
