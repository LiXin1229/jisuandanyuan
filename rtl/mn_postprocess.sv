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
    // Quantize the stable DSP vector in parallel. Compact saturation tests
    // avoid the wide arithmetic/comparison trees of the original v1 post.
    reg signed [7:0] q[0:99],pooled[0:24];
    wire signed [7:0] quantized[0:99];
    function automatic signed [7:0] quant;
        input [17:0] s;
        input [1:0] act;
        reg pos_over,neg_over,sat_pos,sat_neg,clamp6,pass;
        integer bitno;
        begin
            pos_over=s[17];neg_over=s[17];
            clamp6=!s[16] && act==`MN_ACT_RELU6 && (pos_over || s[14] && s[13]);
            sat_pos=!s[16] && pos_over && !clamp6;
            sat_neg=s[16] && neg_over && act==`MN_ACT_NONE;
            pass=!(s[16] && act!=`MN_ACT_NONE) && !clamp6 && !sat_pos && !sat_neg;
            for(bitno=0;bitno<8;bitno=bitno+1)
                quant[bitno]=(s[bitno+8] && pass) ||
                    (bitno<7 && sat_pos) || (bitno==7 && sat_neg) ||
                    ((bitno==5 || bitno==6) && clamp6);
        end
    endfunction
    genvar p,g;
    generate for(p=0;p<100;p=p+1) begin: pixel
        wire [31:0] s=in_data[p*32+:32];
        wire [17:0] compact={|(s[31:16]^{16{s[15]}}),s[31],s[15:0]};
        localparam R=p/10,C=p%10,PACK=((R/5)*2+C/5)*25+(R%5)*5+C%5;
        assign quantized[p]=quant(compact,activation);
        assign tile_data[PACK*8+:8]=q[p];
        always @(posedge clk) if(in_valid && !reset)
            q[p]<=R<valid_h && C<valid_w ? quantized[p] : 8'd0;
    end
    for(g=0;g<25;g=g+1) begin: pool_group
        localparam R=(g/5)*2,C=(g%5)*2,P=R*10+C;
        wire signed [7:0] max0=quantized[P]>quantized[P+1] ? quantized[P] : quantized[P+1];
        wire signed [7:0] max1=quantized[P+10]>quantized[P+11] ? quantized[P+10] : quantized[P+11];
        always @(posedge clk) if(in_valid && !reset)
            pooled[g]<=R+1<valid_h && C+1<valid_w ? (max0>max1 ? max0 : max1) : 8'd0;
        assign pool_data[g*8+:8]=pooled[g];
    end endgenerate
    always @(posedge clk) begin
        if(reset) begin tile_valid<=0;pool_valid<=0;end
        else begin tile_valid<=in_valid;pool_valid<=in_valid;end
    end
endmodule
