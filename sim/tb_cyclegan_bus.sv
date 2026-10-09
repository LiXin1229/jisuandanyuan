`timescale 1ns/1ps
module tb_cyclegan_bus;
    reg clk=0;always #5 clk=~clk;
    reg reset=1,bus_wr=0,bus_rd=0;
    reg [5:0] bus_addr=0;
    reg [31:0] bus_wdata=0;
    wire bus_ready,bus_rvalid,busy,done_sticky;
    wire [31:0] bus_rdata;
    wire [3:0] error_code;
    cyclegan_bus_top dut(.*);
    integer fd,rc,op,address,aux,case_id=0,i,ticks=0;
    reg [799:0] payload,actual;
    reg [31:0] value;
    always @(posedge clk) begin ticks<=ticks+1;if(ticks>100000) $fatal(1,"Model bus timeout");end
    task write_word(input [5:0] addr,input [31:0] data);
        begin
            @(negedge clk);bus_wr=1;bus_addr=addr;bus_wdata=data;
            while(!bus_ready) @(negedge clk);
            @(negedge clk);bus_wr=0;
        end
    endtask
    task read_word(input [5:0] addr,output [31:0] data);
        begin
            @(negedge clk);bus_rd=1;bus_addr=addr;
            while(!bus_ready) @(negedge clk);
            @(posedge clk);#1;if(!bus_rvalid) $fatal(1,"Model bus read valid");data=bus_rdata;
            @(negedge clk);bus_rd=0;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);reset=0;
        fd=$fopen("build/sim/model_smoke.txt","r");if(!fd) $fatal(1,"Missing model smoke vectors");
        while(!$feof(fd)) begin
            rc=$fscanf(fd,"%d %h %h %h\n",op,address,aux,payload);
            if(rc!=4) $fatal(1,"Invalid model vector");
            case(op)
                1:begin
                    write_word(1,address);write_word(2,aux);
                    for(i=0;i<25;i=i+1) write_word(32+i,payload[i*32+:32]);
                    write_word(3,1);
                end
                3:begin
                    write_word(0,2);
                    for(i=0;i<4;i=i+1) write_word(8+i,payload[i*32+:32]);
                    write_word(7,1);
                end
                4:begin
                    while(!done_sticky) @(negedge clk);
                    if(error_code!==address[3:0]) $fatal(1,"Model command error case %0d",case_id);
                end
                5:begin
                    write_word(1,address);write_word(4,1);read_word(0,value);
                    for(i=0;i<25;i=i+1) begin read_word(32+i,value);actual[i*32+:32]=value;end
                    if(actual!==payload) $fatal(1,"Epoch11 bus result mismatch case %0d",case_id);
                end
                8:case_id=address;
                default:$fatal(1,"Unsupported model transaction");
            endcase
        end
        $display("PASS epoch11 bus: fixed ROM DW/PW/BN/CONV-Tanh/ADD, third bank, extended parameters; %0d cycles",ticks);
        $finish;
    end
endmodule
