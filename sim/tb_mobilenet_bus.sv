`timescale 1ns/1ps
module tb_mobilenet_bus;
    reg clk=0;always #5 clk=~clk;
    reg reset=1,bus_wr=0,bus_rd=0;
    reg [5:0] bus_addr=0;
    reg [31:0] bus_wdata=0;
    wire bus_ready,bus_rvalid,busy,done_sticky;
    wire [31:0] bus_rdata;
    wire [3:0] error_code;
    mobilenet_bus_top dut(.*);
    integer i,ticks=0,r,c,dy,dx,sum,index;
    reg [799:0] expected,actual,dw_expected;
    reg [127:0] command;
    reg [31:0] word_value;
    always @(posedge clk) begin
        ticks<=ticks+1;
        if(ticks>10000) $fatal(1,"Bus timeout");
    end
    task write_word(input [5:0] address,input [31:0] value);
        begin
            @(negedge clk);bus_wr=1;bus_addr=address;bus_wdata=value;
            while(!bus_ready) @(negedge clk);
            @(negedge clk);bus_wr=0;
        end
    endtask
    task read_word(input [5:0] address,output [31:0] value);
        begin
            @(negedge clk);bus_rd=1;bus_addr=address;
            while(!bus_ready) @(negedge clk);
            @(posedge clk);#1;
            if(!bus_rvalid) $fatal(1,"Bus read valid");
            value=bus_rdata;
            @(negedge clk);bus_rd=0;
        end
    endtask
    task send_command(input [127:0] value);
        begin
            write_word(8,value[31:0]);write_word(9,value[63:32]);
            write_word(10,value[95:64]);write_word(11,value[127:96]);
            write_word(7,1);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);reset=0;
        for(i=0;i<100;i=i+1) expected[i*8+:8]=i-50;
        for(i=0;i<25;i=i+1) write_word(32+i,expected[i*32+:32]);
`ifndef MN_POSTMAP
        if(dut.tile_staging!==expected) $fatal(1,"Input tile staging mismatch");
`endif
        write_word(1,100);write_word(3,1);
        write_word(5,0);write_word(6,256);
        command=0;command[13:4]=100;command[23:14]=900;
        command[61:58]=9;command[65:62]=9;
        send_command(command);
        while(!busy) @(negedge clk);
        // Attempt a parameter write while executing; it must be backpressured.
        bus_addr=6;bus_wdata=123;bus_wr=1;#1;
        if(bus_ready) $fatal(1,"Memory write accepted while busy");
        while(!bus_ready) @(negedge clk);
        @(negedge clk);bus_wr=0;
        while(!done_sticky) @(negedge clk);
        if(error_code!==0) $fatal(1,"Identity command error: code=%h",error_code);
        write_word(1,900);write_word(4,1);
        for(i=0;i<25;i=i+1) begin read_word(32+i,word_value);actual[i*32+:32]=word_value;end
        if(actual!==expected) begin
            for(i=0;i<100;i=i+1) if(actual[i*8+:8]!==expected[i*8+:8]) $display("bus pixel %0d expected %0d got %0d",i,
                $signed(expected[i*8+:8]),$signed(actual[i*8+:8]));
`ifndef MN_POSTMAP
            $display("param0=%0d dst=%0d first accumulator=%0d",
                dut.unit.parameter_buffer[15:0],dut.unit.dst_base,$signed(dut.unit.pe_data[31:0]));
            $display("pe50=%h in50=%h q50=%h snapshot50=%h",
                dut.unit.pe_data[50*32+:32],dut.unit.input_tile[50*8+:8],
                dut.unit.qdata[50*8+:8],dut.tile_staging[50*8+:8]);
`endif
            $fatal(1,"Bus tile snapshot mismatch");
        end
        read_word(0,word_value);
        if(!word_value[1] || word_value[0] || !word_value[2]) $fatal(1,"Status register");
        write_word(0,2);
        if(done_sticky) $fatal(1,"Done W1C");
        // Complete a DW instruction through all 9 nonzero taps. The golden
        // calculation uses original input bytes and independent integer sums.
        write_word(5,200);
        for(i=0;i<9;i=i+1) write_word(6,256);
        for(r=0;r<10;r=r+1) for(c=0;c<10;c=c+1) begin
            sum=0;
            for(dy=-1;dy<=1;dy=dy+1) for(dx=-1;dx<=1;dx=dx+1)
                if(r+dy>=0 && r+dy<10 && c+dx>=0 && c+dx<10) begin
                    index=(((r+dy)/5)*2+(c+dx)/5)*25+((r+dy)%5)*5+(c+dx)%5;
                    sum=sum+$signed(expected[index*8+:8]);
                end
            if(sum>127) sum=127;
            if(sum< -128) sum= -128;
            index=((r/5)*2+c/5)*25+(r%5)*5+c%5;
            dw_expected[index*8+:8]=sum;
        end
        command[3:0]=2;command[23:14]=901;command[35:24]=200;
        command[43:41]=3;command[51:50]=1;command[53:52]=1;command[57:54]=15;
        command[75:66]=2;command[85:76]=12;
        send_command(command);
        while(!done_sticky) @(negedge clk);
        if(error_code!==0) $fatal(1,"DW command error: code=%h",error_code);
        write_word(1,901);write_word(4,1);
        for(i=0;i<25;i=i+1) begin read_word(32+i,word_value);actual[i*32+:32]=word_value;end
        if(actual!==dw_expected) $fatal(1,"DW mapped/RTL golden mismatch");
        write_word(0,2);
        // Abort a DW in halo fill and a queued PW. Reset must flush both.
        command[23:14]=900;
        send_command(command);
`ifdef MN_POSTMAP
        repeat(30) @(negedge clk);
`else
        while(dut.unit.state!=9) @(negedge clk);
`endif
        command[3:0]=0;send_command(command);
        reset=1;repeat(3) @(negedge clk);reset=0;
        repeat(30) @(negedge clk);
        read_word(0,word_value);
        if(busy || done_sticky || word_value[11:9]!=0) $fatal(1,"Reset cancellation");
        write_word(1,900);write_word(4,1);
        for(i=0;i<25;i=i+1) begin read_word(32+i,word_value);actual[i*32+:32]=word_value;end
        if(actual!==expected) $fatal(1,"Aborted instruction corrupted destination");
        $display("PASS bus: PW identity, DW 9-tap integer golden, staging, parameter increment, backpressure, result snapshot, W1C, reset cancellation");
        $finish;
    end
endmodule
