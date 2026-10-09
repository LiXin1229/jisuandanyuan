`include "mn_isa.vh"
module mn_postprocess (
    input wire clk, reset,
    input wire in_valid,
    input wire [3199:0] in_data,
    input wire [1:0] activation,
    input wire [3:0] valid_w, valid_h,
    output reg tile_valid,
    output wire [799:0] tile_data,
    output reg pool_valid,
    output wire [199:0] pool_data
);
    reg signed [7:0] q [0:99];
    reg signed [7:0] pair0 [0:24], pair1 [0:24], pooled [0:24];
    reg pair_valid;
    function automatic signed [7:0] quant;
        input signed [31:0] s;
        input [1:0] act;
        reg pos_over,neg_over,sat_pos,sat_neg,clamp6,pass;
        integer bitno;
        begin
            pos_over=|s[30:15];
            neg_over=~&s[30:15];
            clamp6=!s[31] && act==`MN_ACT_RELU6 && (pos_over || s[14] && s[13]);
            sat_pos=!s[31] && pos_over && !clamp6;
            sat_neg=s[31] && neg_over && act==`MN_ACT_NONE;
            pass=!(s[31] && act!=`MN_ACT_NONE) && !clamp6 && !sat_pos && !sat_neg;
            for(bitno=0;bitno<8;bitno=bitno+1)
                quant[bitno]=(s[bitno+8] && pass) ||
                    (bitno<7 && sat_pos) || (bitno==7 && sat_neg) ||
                    ((bitno==5 || bitno==6) && clamp6);
        end
    endfunction
    genvar r,c;
    generate for(r=0;r<10;r=r+1) begin: qr
        for(c=0;c<10;c=c+1) begin: qc
            localparam P=r*10+c;
            localparam PACK=((r/5)*2+c/5)*25+(r%5)*5+c%5;
            always @(posedge clk) if(in_valid)
                q[P]<= (r<valid_h && c<valid_w) ?
                    quant($signed(in_data[P*32+:32]),activation) : 8'd0;
            assign tile_data[PACK*8+:8]=q[P];
        end
    end
    for(r=0;r<5;r=r+1) begin: pr
        for(c=0;c<5;c=c+1) begin: pc
            localparam G=r*5+c;
            localparam P=r*20+c*2;
            always @(posedge clk) begin
                if(tile_valid) begin
                    // VALID 2x2 pooling; incomplete windows are suppressed.
                    pair0[G]<=q[P]>q[P+1] ? q[P] : q[P+1];
                    pair1[G]<=q[P+10]>q[P+11] ? q[P+10] : q[P+11];
                end
                if(pair_valid)
                    pooled[G]<= (2*r+1<valid_h && 2*c+1<valid_w) ?
                        (pair0[G]>pair1[G] ? pair0[G] : pair1[G]) : 8'd0;
            end
            assign pool_data[G*8+:8]=pooled[G];
        end
    end endgenerate
    always @(posedge clk) begin
        if(reset) begin tile_valid<=0; pair_valid<=0; pool_valid<=0; end
        else begin tile_valid<=in_valid; pair_valid<=tile_valid; pool_valid<=pair_valid; end
    end
endmodule
