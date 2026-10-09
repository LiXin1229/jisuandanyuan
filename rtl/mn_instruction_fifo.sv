module mn_instruction_fifo (
    input wire clk, reset,
    input wire [127:0] in_data,
    input wire in_valid,
    output wire in_ready,
    output wire [127:0] out_data,
    output wire out_valid,
    input wire out_ready,
    output reg [2:0] count
);
    // Push shifts newest-to-oldest; count selects the oldest live word.
    // Pops only change count, including a simultaneous push/pop. This form
    // permits SRL inference instead of four independently written slots.
    reg [127:0] words [0:3];
    wire push=in_valid && in_ready;
    wire pop=out_valid && out_ready;
    assign in_ready=count<4;
    assign out_valid=count!=0;
    wire [1:0] head_index=count[1:0]-2'd1;
    assign out_data=words[head_index];
    genvar slot;
    generate for(slot=0;slot<4;slot=slot+1) begin: slots
        if(slot==0) begin: first
            always @(posedge clk) if(!reset && push) words[slot]<=in_data;
        end else begin: older
            always @(posedge clk) if(!reset && push) words[slot]<=words[slot-1];
        end
    end endgenerate
    always @(posedge clk) begin
        if (reset) count<=0;
        else begin
            case ({push,pop})
                2'b10: count<=count+1'b1;
                2'b01: count<=count-1'b1;
                default: ;
            endcase
        end
    end
endmodule
