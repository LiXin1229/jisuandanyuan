`timescale 1ns/1ps
module tb_mobilenet_unit;
    reg clk=0;always #5 clk=~clk;
    reg reset=1;
    reg [127:0] instruction=0;
    reg instruction_valid=0;
    wire instruction_ready;
    wire [2:0] instruction_count;
    reg host_cache_wr=0,host_cache_rd=0,host_param_wr=0;
    reg [10:0] host_cache_waddr=0,host_cache_raddr=0;
    reg [799:0] host_cache_wdata=0;
    reg [39:0] host_cache_wmask=40'hffffffffff;
    reg [14:0] host_param_addr=0;
    reg [15:0] host_param_data=0;
    wire host_memory_ready,host_cache_rvalid,busy,done;
    wire [799:0] host_cache_rdata;
    wire [3:0] error_code;
    mobilenet_unit dut(.*);
    integer completed=0,consumed=0,cycle=0,op,address,aux,fd,rc,n;
    integer last_case=0;
    integer metrics,started=0;
    reg [127:0] active_command;
    reg [799:0] payload;
    reg [3:0] errors [0:2047];
    always @(posedge clk) begin
        cycle<=cycle+1;
        if(done) begin
            errors[completed]=error_code;
            $fwrite(metrics,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",completed+1,last_case,
                active_command[3:0],active_command[40:36]+1,active_command[43:41],
                active_command[51:50],cycle-started,error_code);
            completed=completed+1;
        end
        if(dut.fifo_pop) begin started=cycle;active_command=dut.fifo_head;end
        if(cycle>150000) $fatal(1,"Global timeout, case %0d state %0d",last_case,dut.state);
    end
    task wait_memory;
        begin
            while(!host_memory_ready) @(negedge clk);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);reset=0;
        fd=$fopen("sim/vectors.txt","r");
        metrics=$fopen("build/sim/commands.csv","w");
        $fwrite(metrics,"command,case,opcode,channels,kernel,padding,cycles,error\n");
        if(fd==0) $fatal(1,"Missing generated vectors");
        while(!$feof(fd)) begin
            rc=$fscanf(fd,"%d %h %h %h\n",op,address,aux,payload);
            if(rc!=4) $fatal(1,"Malformed transaction, rc=%0d",rc);
            @(negedge clk);
            case(op)
                1:begin
                    wait_memory();host_cache_wr=1;host_cache_waddr=address;
                    host_cache_wdata=payload;
                    host_cache_wmask={{10{aux[3]}},{10{aux[2]}},{10{aux[1]}},{10{aux[0]}}};
                    @(negedge clk);host_cache_wr=0;
                end
                2:begin
                    wait_memory();host_param_wr=1;host_param_addr=address;host_param_data=aux;
                    @(negedge clk);host_param_wr=0;
                end
                3:begin
                    while(!instruction_ready) @(negedge clk);
                    instruction=payload[127:0];instruction_valid=1;
                    @(negedge clk);instruction_valid=0;
                end
                4:begin
                    n=0;
                    while(completed<=consumed) begin
                        @(negedge clk);n=n+1;
                        if(n>6000) $fatal(1,"Command timeout case=%0d state=%0d",last_case,dut.state);
                    end
                    if(errors[consumed]!==address[3:0])
                        $fatal(1,"case %0d error expected %0d actual %0d",last_case,address,errors[consumed]);
                    consumed=consumed+1;
                end
                5:begin
                    wait_memory();host_cache_rd=1;host_cache_raddr=address;
                    @(posedge clk);#1;
                    if(!host_cache_rvalid) $fatal(1,"Host read valid");
                    if(host_cache_rdata!==payload) begin
                        for(n=0;n<100;n=n+1)
                            if(host_cache_rdata[n*8+:8]!==payload[n*8+:8])
                                $display("case %0d packed pixel %0d expected %0d got %0d",last_case,n,
                                    $signed(payload[n*8+:8]),$signed(host_cache_rdata[n*8+:8]));
                        $fatal(1,"Cache mismatch");
                    end
                    @(negedge clk);host_cache_rd=0;
                end
                8:begin last_case=address;$display("CASE %0d at cycle %0d",last_case,cycle);end
                default:$fatal(1,"Unknown vector operation %0d",op);
            endcase
        end
        if(consumed!=completed || instruction_count!=0 || busy)
            $fatal(1,"Unfinished commands");
        $display("PASS: %0d cases, %0d commands, %0d cycles",last_case,completed,cycle);
        $fclose(fd);$fclose(metrics);$finish;
    end
endmodule
