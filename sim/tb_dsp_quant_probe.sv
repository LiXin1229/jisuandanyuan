`timescale 1ns/1ps
// Numerical feasibility probe against the vendor DSP model, not a timing test.
module tb_dsp_quant_probe;
    reg clk=0;always #5 clk=~clk;
    reg reset=1;
    reg signed [18:0] a=0;
    reg signed [17:0] b=0,c=0;
    reg shift_enable=0;
    reg [1:0] op=0;
    wire signed [47:0] result;
    wire overflow;
    EFX_DSP48 #(.MODE("NORMAL"),.SIGNED(1),.SHIFTER(1),
        .W_REG(1),.O_REG(1),.RST_SYNC(1),.M_SEL("P"),.N_SEL("C"),
        .W_SEL("X"),.P_EXT("ALIGN_RIGHT"),.C_EXT("ALIGN_RIGHT")) mac (
        .A(a),.B(b),.C(c),.CASCIN(48'd0),.OP(op),.SHIFT_ENA(shift_enable),
        .CLK(clk),.CE(1'b1),.RST(reset),.O(result),.CASCOUT(),.OVFL(overflow));
    reg signed [18:0] acc_a=0;
    reg acc_ce=0;
    reg [17:0] shift_control=8;
    wire signed [47:0] acc_output,raw_acc;
    EFX_DSP48 #(.MODE("NORMAL"),.SIGNED(1),.SHIFTER(1),
        .W_REG(1),.O_REG(1),.O_REG_USE_CE(0),.RST_SYNC(1),
        .M_SEL("P"),.N_SEL("W"),.W_SEL("X"),.CASCOUT_SEL("W")) accum (
        .A(acc_a),.B(18'd1),.C(shift_control),.CASCIN(48'd0),.OP(2'b00),
        .SHIFT_ENA(1'b1),.CLK(clk),.CE(acc_ce),.RST(reset),
        .O(acc_output),.CASCOUT(raw_acc),.OVFL());
    integer i;
    task settle;
        begin repeat(3) @(negedge clk);end
    endtask
    initial begin
        settle();reset=0;
        a=100;b=10;c=20;shift_enable=1;settle();
        if(result!==63) $fatal(1,"C=20 must select shift 4: got %0d",result);
        c=24;settle();
        if(result!==4) $fatal(1,"Replacing low nibble changed the bias: got %0d",result);
        c=8;settle();c=20;shift_enable=0;settle();
        if(result!==3) $fatal(1,"Preloaded shift must hold independently of C: got %0d",result);
        $display("PASS C sharing: same-cycle C20 shifts by4; C24 changes answer; preload8 then C20 gives3");
        a=-5;b=10;c=0;shift_enable=1;
        for(i=0;i<4;i=i+1) begin
            op=i;settle();
            case(i)
                0,1:if(result!==-48'sd50) $fatal(1,"Unexpected negative add/sub");
                2:if(result!==48'sd50) $fatal(1,"Unexpected negate");
                3:if(result!==48'sd49) $fatal(1,"Integer OP11 must include -1");
            endcase
            if(overflow!==0) $fatal(1,"Negative value is not an overflow");
        end
        a=100;b=100;op=0;settle();
        if(result!==10000 || overflow!==0) $fatal(1,"DSP must not clamp to int8 range");
        $display("PASS OP/overflow: -50,-50,50,49; no ReLU or int8 saturation");
        c=8;settle();c=0;shift_enable=0;b=1000;settle();
        if(result!==390 || overflow!==0) $fatal(1,"Shift8 must not imply sat8");
        $display("PASS quantization: 100000>>8=390; low byte0x86 is not saturated int8 value127");
        acc_a=256;acc_ce=1;repeat(2) @(negedge clk);acc_ce=0;@(negedge clk);
        if(raw_acc!==512 || acc_output!==2) $fatal(1,"W feedback must retain raw sum: raw=%0d out=%0d",raw_acc,acc_output);
        shift_control=0;repeat(2) @(negedge clk);
        if(raw_acc!==512 || acc_output!==512) $fatal(1,"Output shift must not modify W");
        $display("PASS W feedback: raw sum512, shifted output2, shift0 restores raw output512");
        $finish;
    end
endmodule
