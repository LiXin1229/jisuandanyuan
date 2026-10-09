`timescale 1ns/1ps
module tb_cache;
    reg clk=0; always #5 clk=~clk;
    reg reset=1,wr_en=0,rd_en=0,host_wr=0,host_rd=0;
    reg [10:0] wr_addr=0,rd_addr=0,host_waddr=0,host_raddr=0;
    reg [799:0] wr_data=0,host_wdata=0;
    reg [3:0] wr_quadrants=0;
    reg [39:0] host_mask=0;
    wire [799:0] rd_data,host_rdata;
    wire rd_valid,host_rvalid;
    mn_cache dut(.*);
    reg [799:0] golden[0:1535];
    reg [799:0] held;
    integer checks=0,a,j,n;
    function automatic [799:0] pattern(input integer addr,input integer salt);
        integer k;
        begin
            for(k=0;k<100;k=k+1) pattern[k*8+:8]=(addr*19+k*73+salt*29)^(addr>>3);
        end
    endfunction
    task automatic host_write(input integer addr,input [39:0] mask,input integer salt);
        begin
            @(negedge clk); host_wr=1;host_waddr=addr;host_mask=mask;
            host_wdata=pattern(addr,salt);
            @(posedge clk); #1;
            if(addr<1536) for(integer k=0;k<40;k=k+1)
                if(mask[k]) golden[addr][k*20+:20]=host_wdata[k*20+:20];
            @(negedge clk);host_wr=0;
        end
    endtask
    task automatic core_write(input integer addr,input [3:0] mask,input integer salt);
        begin
            @(negedge clk);wr_en=1;wr_addr=addr;wr_quadrants=mask;wr_data=pattern(addr,salt);
            @(posedge clk);#1;
            if(addr<1536) for(integer k=0;k<4;k=k+1)
                if(mask[k]) golden[addr][k*200+:200]=wr_data[k*200+:200];
            @(negedge clk);wr_en=0;
        end
    endtask
    task automatic read_word(input integer addr,input bit host);
        reg [799:0] expected;
        begin
            @(negedge clk);host_rd=host;rd_en=!host;host_raddr=addr;rd_addr=addr;
            @(posedge clk);#1;
            expected=addr<1536 ? golden[addr] : 800'b0;
            if(rd_valid!==!host || host_rvalid!==host || rd_data!==expected || host_rdata!==expected)
                $fatal(1,"cache mismatch addr=%0d host=%0d",addr,host);
            checks=checks+1;
            @(negedge clk);rd_en=0;host_rd=0;
            held=rd_data;
            @(posedge clk);#1;
            if(rd_data!==held || rd_valid || host_rvalid) $fatal(1,"idle read hold mismatch");
        end
    endtask
    initial begin
        repeat(3) @(posedge clk);
        @(negedge clk);reset=0;
        for(a=0;a<1536;a=a+1) host_write(a,40'hffffffffff,0);
        for(a=0;a<1536;a=a+1) read_word(a,a%2);
        // Every independent 20-bit host slice and every 200-bit core quadrant.
        for(n=0;n<3;n=n+1) begin
            a=n*512+511;
            for(j=0;j<40;j=j+1) begin
                host_write(a,40'b1<<j,j+1);read_word(a,1);
            end
            for(j=0;j<16;j=j+1) begin
                core_write(a,j,j+60);read_word(a,0);
            end
        end
        // Illegal reads synchronously clear only the output, never memory.
        for(a=1536;a<2048;a=a+1) begin
            host_write(a,40'hffffffffff,97);core_write(a,15,98);
            read_word(a,a%2);read_word(a-512,!(a%2));
        end
        for(a=0;a<1536;a=a+1) read_word(a,a%2);
        @(negedge clk);reset=1;
        @(posedge clk);#1;
        if(rd_data!==0 || rd_valid || host_rvalid) $fatal(1,"reset output mismatch");
        @(negedge clk);reset=0;
        read_word(511,0);read_word(1023,1);read_word(1535,0);
        // Continuous one-read-per-cycle traffic, including illegal reads.
        @(negedge clk);rd_en=1;
        for(n=0;n<12;n=n+1) begin
            case(n%6)
                0:a=511;1:a=1024;2:a=2047;3:a=1536;4:a=1535;5:a=0;
            endcase
            rd_addr=a;
            @(posedge clk);#1;
            if(!rd_valid || rd_data!==(a<1536 ? golden[a] : 800'b0))
                $fatal(1,"continuous read mismatch addr=%0d",a);
            checks=checks+1;
            @(negedge clk);
        end
        rd_en=0;
        $display("PASS cache: %0d full-word checks, all legal/illegal addresses, masks, hold, reset and continuous reads",checks);
        $finish;
    end
    initial begin #1000000; $fatal(1,"cache timeout");end
    initial if($test$plusargs("cache_progress")) begin
        #100;
        $display("CACHE_PROGRESS time=%0t checks=%0d addr=%0d",$time,checks,a);
        forever begin
            #10000;
            $display("CACHE_PROGRESS time=%0t checks=%0d addr=%0d",$time,checks,a);
        end
    end
endmodule
