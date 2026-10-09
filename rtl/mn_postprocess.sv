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
    // Process five 2x2 groups (20 pixels) per clock, starting on in_valid.
    // DSP outputs hold during the four remaining batches; no wide snapshot.
    reg signed [7:0] q [0:99],pooled [0:24];
    reg active;
    reg [2:0] group_index;
    reg [1:0] act;
    reg [3:0] width,height;
    wire processing=active || in_valid;
    wire [2:0] batch=active ? group_index : 3'd0;
    wire [4:0] select_group=5'b1<<batch;
    wire [1:0] current_act=active ? act : activation;
    wire [3:0] current_width=active ? width : valid_w;
    wire [3:0] current_height=active ? height : valid_h;
    wire [17:0] compact[0:99];
    wire [17:0] selected[0:19];
    wire signed [7:0] quantized[0:19];
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
    genvar p,lane,g;
    generate for(p=0;p<100;p=p+1) begin: compact_sum
        wire [31:0] s=in_data[p*32+:32];
        assign compact[p]={|(s[31:16]^{16{s[15]}}),s[31],s[15:0]};
        localparam R=p/10,C=p%10,PACK=((R/5)*2+C/5)*25+(R%5)*5+C%5;
        assign tile_data[PACK*8+:8]=q[p];
    end
    for(lane=0;lane<20;lane=lane+1) begin: select_lane
        localparam OFFSET=((lane%4)/2)*10+lane%2+(lane/4)*2;
        reg [17:0] chosen;
        integer k;
        always @* begin
            chosen=0;
            for(k=0;k<5;k=k+1)
                chosen=chosen | (compact[k*20+OFFSET]&{18{select_group[k]}});
        end
        assign selected[lane]=chosen;
        assign quantized[lane]=quant(selected[lane],current_act);
    end
    for(g=0;g<25;g=g+1) begin: output_group
        localparam R=(g/5)*2,C=(g%5)*2,P=R*10+C,Q=(g%5)*4;
        wire signed [7:0] max0=quantized[Q+0]>quantized[Q+1] ? quantized[Q+0] : quantized[Q+1];
        wire signed [7:0] max1=quantized[Q+2]>quantized[Q+3] ? quantized[Q+2] : quantized[Q+3];
        always @(posedge clk) if(processing && !reset && batch==g/5) begin
            q[P] <= R<current_height && C<current_width ? quantized[Q+0] : 8'd0;
            q[P+1] <= R<current_height && C+1<current_width ? quantized[Q+1] : 8'd0;
            q[P+10] <= R+1<current_height && C<current_width ? quantized[Q+2] : 8'd0;
            q[P+11] <= R+1<current_height && C+1<current_width ? quantized[Q+3] : 8'd0;
            pooled[g] <= R+1<current_height && C+1<current_width ? (max0>max1 ? max0 : max1) : 8'd0;
        end
        assign pool_data[g*8+:8]=pooled[g];
    end endgenerate
    always @(posedge clk) begin
        if(reset) begin tile_valid<=0;pool_valid<=0;active<=0;group_index<=0;act<=0;width<=0;height<=0;end
        else begin
            tile_valid<=0;pool_valid<=0;
            if(in_valid && !active) begin active<=1;group_index<=1;act<=activation;width<=valid_w;height<=valid_h;end
            if(active) begin
                if(group_index==4) begin active<=0;tile_valid<=1;pool_valid<=1;end
                else group_index<=group_index+1'b1;
            end
        end
    end
endmodule
