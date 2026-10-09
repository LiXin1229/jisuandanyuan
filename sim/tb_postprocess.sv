`timescale 1ns/1ps
module tb_postprocess;
    reg clk=0;always #5 clk=~clk;
    reg reset=1,in_valid=0;
    reg [3199:0] in_data=0;
    reg [1:0] activation=0;
    reg [3:0] valid_w=10,valid_h=10;
    wire tile_valid,pool_valid;
    wire [799:0] tile_data;
    wire [199:0] pool_data;
    integer batch,act,p,r,c,k,index,expected,max_value,checks=0;
    reg signed [31:0] source[0:99];
    integer golden[0:99];
    mn_postprocess dut(.*);
    task check_tile;
        begin
            in_valid=1;@(negedge clk);in_valid=0;
            if(!tile_valid) $fatal(1,"Parallel postprocess exceeded one acceptance cycle");
            if(!pool_valid) $fatal(1,"Pool and full-tile completion lost alignment");
            for(p=0;p<100;p=p+1) begin
                r=p/10;c=p%10;
                expected=source[p]>>>8;
                if(expected>127) expected=127;if(expected< -128) expected= -128;
                if(activation!=0 && expected<0) expected=0;
                if(activation==2 && expected>96) expected=96;
                if(r>=valid_h || c>=valid_w) expected=0;
                golden[p]=expected;
                index=((r/5)*2+c/5)*25+(r%5)*5+c%5;
                if($signed(tile_data[index*8+:8])!==expected)
                    $fatal(1,"Postprocess raw=%0d act=%0d lane=%0d expected=%0d actual=%0d",source[p],activation,p,expected,$signed(tile_data[index*8+:8]));
                checks=checks+1;
            end
            for(r=0;r<5;r=r+1) for(c=0;c<5;c=c+1) begin
                max_value= -128;
                for(k=0;k<4;k=k+1) begin
                    expected=golden[(r*2+k/2)*10+c*2+k%2];
                    if(expected>max_value) max_value=expected;
                end
                if(r*2+1>=valid_h || c*2+1>=valid_w) max_value=0;
                if($signed(pool_data[(r*5+c)*8+:8])!==max_value) $fatal(1,"Signed/incomplete pooling mismatch");
            end
            @(negedge clk);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);reset=0;
        for(act=0;act<3;act=act+1) begin
            activation=act;
            for(batch=0;batch<656;batch=batch+1) begin
                for(p=0;p<100;p=p+1) begin
                    source[p]=batch*100+p-32768;
                    in_data[p*32+:32]=source[p];
                end
                check_tile();
            end
            for(batch=0;batch<30;batch=batch+1) begin
                valid_w=batch%10+1;valid_h=(batch*7)%10+1;
                for(p=0;p<100;p=p+1) begin
                    case(p%8)
                        0:source[p]=32'h7fffffff;
                        1:source[p]=32'h80000000;
                        2:source[p]=32768;
                        3:source[p]= -32769;
                        4:source[p]=24575;
                        5:source[p]=24576;
                        6:source[p]= -65536;
                        7:source[p]=$random;
                    endcase
                    in_data[p*32+:32]=source[p];
                end
                check_tile();
            end
            valid_w=10;valid_h=10;
        end
        // Reset on the acceptance edge suppresses both one-cycle outputs.
        in_valid=1;reset=1;@(negedge clk);in_valid=0;
        if(tile_valid || pool_valid) $fatal(1,"Postprocess accepted during reset");
        reset=0;repeat(3) @(negedge clk);
        if(tile_valid || pool_valid) $fatal(1,"Canceled postprocess completed");
        $display("PASS parallel postprocess: %0d pixels, signed16 exhaustive, signed32 extremes, partial pooling and reset",checks);
        $finish;
    end
endmodule
