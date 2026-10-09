`timescale 1ns/1ps
module tb_compact;
    reg [3199:0] in_data=0;
    wire [1799:0] out_data;
    mn_compact dut(.*);
    integer batch,p,code,bitno,polarity,checks=0;
    reg signed [31:0] value;
    reg [17:0] expected;
    task check;
        input integer count;
        begin
            #1;
            for(p=0;p<count;p=p+1) begin
                value=$signed(in_data[p*32+:32]);
                expected={value>32767 || value< -32768,value[31],value[15:0]};
                if(out_data[p*18+:18]!==expected)
                    $fatal(1,"Compact lane=%0d raw=%h expected=%h actual=%h",p,value,expected,out_data[p*18+:18]);
                checks=checks+1;
            end
        end
    endtask
    initial begin
        // Exhaust all 17 high/sign bits, distributing cases across 100 lanes.
        for(batch=0;batch<131072;batch=batch+100) begin
            for(p=0;p<100;p=p+1) begin
                code=batch+p;
                in_data[p*32+:32]=(code<<15)|((p*151+batch)&32767);
            end
            check(batch+100>131072 ? 131072-batch : 100);
        end
        // Every physical lane sees both sign extensions and every mismatch.
        for(polarity=0;polarity<2;polarity=polarity+1) begin
            for(p=0;p<100;p=p+1) in_data[p*32+:32]=polarity ? -1 : 0;
            check(100);
            for(bitno=15;bitno<32;bitno=bitno+1) begin
                for(p=0;p<100;p=p+1)
                    in_data[p*32+:32]=(polarity ? 32'hffffffff : 32'd0)^(32'd1<<bitno);
                check(100);
            end
        end
        $display("PASS compact: %0d values, all high/sign patterns and every lane mismatch",checks);
        $finish;
    end
endmodule
