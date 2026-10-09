`timescale 1ns/1ps
module tb_model_assets;
    reg clk=0;always #5 clk=~clk;
    reg rd_en=0;
    reg [14:0] addr=0;
    wire [15:0] data;
    reg [15:0] expected[0:22015];
    reg [7:0] lut[0:4095];
    reg rstn=0,start=0;
    reg [3199:0] in_data=0;
    wire busy,valid;
    wire [799:0] result;
    reg ready=0;
    integer i,j,p,batch,code,packed_index;
    reg [15:0] held;
    mn_model_rom rom(.clk(clk),.rd_en(rd_en),.addr(addr),.data(data));
    wire [1799:0] compact_data;
    mn_compact compact(.in_data(in_data),.out_data(compact_data));
    mn_tanh_tile tanh(.clk(clk),.rstn(rstn),.start(start),.in_data(compact_data),
        .busy(busy),.valid(valid),.ready(ready),.data(result));
    initial begin
        $readmemh("build/cyclegan_model/generator_params_q88.mem",expected);
        $readmemh("rtl/mn_tanh_u8.mem",lut);
        repeat(3) @(negedge clk);rstn=1;
        for(i=0;i<22016;i=i+1) begin
            @(negedge clk);addr=i;rd_en=1;
            @(posedge clk);#1;
            if(data!==expected[i]) $fatal(1,"Model ROM mismatch at %0d: %h != %h",i,data,expected[i]);
            if(i%31==0) begin
                held=data;@(negedge clk);rd_en=0;addr=22015-i;
                @(posedge clk);#1;if(data!==held) $fatal(1,"Disabled ROM output changed");
            end
        end
        @(negedge clk);rd_en=0;
        for(batch=0;batch<42;batch=batch+1) begin
            for(p=0;p<100;p=p+1) begin
                code=batch*100+p;if(code>4095) code=4095;
                in_data[p*32+:32]=(code-2048)*16;
            end
            start=1;@(negedge clk);start=0;
            while(!valid) @(negedge clk);
            for(p=0;p<100;p=p+1) begin
                code=batch*100+p;if(code>4095) code=4095;
                packed_index=(((p/10)/5)*2+(p%10)/5)*25+((p/10)%5)*5+(p%10)%5;
                if(result[packed_index*8+:8]!==lut[code])
                    $fatal(1,"Tanh pipeline mismatch at %0d",code);
            end
            repeat(3) @(negedge clk);
            if(!valid) $fatal(1,"Tanh result did not hold under backpressure");
            ready=1;@(negedge clk);ready=0;
        end
        // Overflow, signed extremes, and half-step address rounding.
        for(p=0;p<100;p=p+1) begin
            case(p%4)
                0:in_data[p*32+:32]=32'h7fffffff;
                1:in_data[p*32+:32]=32'h80000000;
                2:in_data[p*32+:32]=32'd8;
                3:in_data[p*32+:32]=-32'sd9;
            endcase
        end
        start=1;@(negedge clk);start=0;while(!valid) @(negedge clk);
        for(p=0;p<100;p=p+1) begin
            code=p%4==0 ? 4095 : p%4==1 ? 0 : p%4==2 ? 2049 : 2047;
            packed_index=(((p/10)/5)*2+(p%10)/5)*25+((p/10)%5)*5+(p%10)%5;
            if(result[packed_index*8+:8]!==lut[code]) $fatal(1,"Tanh overflow/rounding mismatch");
        end
        $display("PASS assets: 22016 native ROM words, stop-read hold, 4096 Tanh addresses, backpressure, extremes and ties");
        $finish;
    end
    initial begin #1000000;$fatal(1,"Asset test timeout");end
endmodule
