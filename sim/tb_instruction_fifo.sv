`timescale 1ns/1ps
module tb_instruction_fifo;
    reg clk=0;always #5 clk=~clk;
    reg reset=1,in_valid=0,out_ready=0;
    reg [127:0] in_data=0;
    wire in_ready,out_valid;
    wire [127:0] out_data;
    wire [2:0] count;
    reg [127:0] expected[0:8191];
    integer head=0,tail=0,live=0,seq=0,n,pushes=0,pops=0,both=0,seed=32'h12345678;
    reg push,pop;
    mn_instruction_fifo dut(.*);
    task step;
        input valid,ready,rst;
        begin
            @(negedge clk);reset=rst;in_valid=valid;out_ready=ready;
            in_data={32'h10203040^seq,32'hffeeddcc+seq,32'h87654321-seq,32'h55aa55aa^seq};seq=seq+1;
            #1;
            if(in_ready!==(live<4) || out_valid!==(live!=0)) $fatal(1,"FIFO handshake mismatch");
            if(live!=0 && out_data!==expected[head]) $fatal(1,"FIFO oldest word mismatch");
            push=in_valid && in_ready;pop=out_ready && out_valid;
            @(posedge clk);
            if(reset) begin head=0;tail=0;live=0;end
            else begin
                if(push) begin expected[tail]=in_data;tail=tail+1;pushes=pushes+1;end
                if(pop) begin head=head+1;pops=pops+1;end
                if(push && pop) both=both+1;
                live=live+push-pop;
            end
            #1;if(count!==live[2:0]) $fatal(1,"FIFO occupancy mismatch");
            if(live!=0 && out_data!==expected[head]) $fatal(1,"FIFO post-edge head mismatch");
        end
    endtask
    initial begin
        @(posedge clk);#1;
        repeat(6) step(1,0,0); // Fill and reject excess writes.
        repeat(8) step(1,1,0); // Pop a full queue, then simultaneous traffic.
        repeat(6) step(0,1,0); // Drain and reject excess reads.
        for(n=0;n<4000;n=n+1) step($random(seed)&1,$random(seed)&1,n%137==0);
        repeat(5) step(0,1,0);
        if(live!=0 || both<100) $fatal(1,"FIFO coverage incomplete");
        $display("PASS FIFO: %0d pushes, %0d pops, %0d simultaneous cycles, full/empty and repeated reset",pushes,pops,both);
        $finish;
    end
endmodule
