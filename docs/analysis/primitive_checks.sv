`timescale 1ns/1ps
// Architecture evaluation only; this is not the compute-unit implementation.
module primitive_checks;
    reg clk = 0;
    always #5 clk = ~clk;
    reg reset = 1;
    reg waddren = 0, raddren = 0;
    reg [39:0] we = 0;
    reg [8:0] waddr = 0, raddr = 0;
    reg [19:0] wd [0:39];
    wire [19:0] rd [0:39];
    wire rv;
    integer i;

    mem_800_512 cache (.clk(clk), .reset(reset), .waddren(waddren),
        .we_a(we), .raddren(raddren), .waddr(waddr), .wdata_a(wd),
        .rdata_b(rd), .rdata_valid(rv), .raddr(raddr));

    reg signed [18:0] a = 0;
    reg signed [17:0] b = 0;
    reg dsp_ce = 0, dsp_reset = 1;
    wire [47:0] dsp_o, acc;
    EFX_DSP48 #(.MODE("NORMAL"), .SIGNED(1), .M_SEL("P"),
        .N_SEL("W"), .W_SEL("X"), .W_REG(1), .O_REG(0),
        .RST_SYNC(1), .CASCOUT_SEL("W")) pe (
        .A(a), .B(b), .C(18'd8), .CASCIN(48'd0), .OP(2'b00),
        .SHIFT_ENA(1'b1), .CLK(clk), .CE(dsp_ce), .RST(dsp_reset),
        .O(dsp_o), .CASCOUT(acc), .OVFL());

    task mac;
        input signed [18:0] av;
        input signed [17:0] bv;
        input signed [47:0] expected;
        begin
            @(negedge clk); a = av; b = bv; dsp_ce = 1;
            @(posedge clk); #1;
            if ($signed(acc) !== expected)
                $fatal(1, "MAC: expected %0d, got %0d", expected, $signed(acc));
        end
    endtask

    initial begin
        for (i = 0; i < 40; i = i + 1) wd[i] = 0;
        repeat (2) @(negedge clk);
        reset = 0; dsp_reset = 0;
        waddren = 1; we = {40{1'b1}}; waddr = 9'd3;
        for (i = 0; i < 40; i = i + 1) wd[i] = 20'd100 + i;
        @(negedge clk);
        we = 40'h00000ffc00;
        for (i = 0; i < 40; i = i + 1) wd[i] = 20'd200 + i;
        @(negedge clk);
        // A disabled address latch must never write even if the mask is set.
        waddren = 0; we = {40{1'b1}};
        for (i = 0; i < 40; i = i + 1) wd[i] = 20'd999;
        @(negedge clk); raddren = 1; raddr = 9'd3;
        @(posedge clk); #1;
        if (rv !== 1) $fatal(1, "Read valid latency");
        for (i = 0; i < 40; i = i + 1)
            if (rd[i] !== ((i >= 10 && i <= 19) ? 20'd200+i : 20'd100+i))
                $fatal(1, "Masked cache write: slice %0d, got %0d", i, rd[i]);
        @(negedge clk); raddren = 0;
        @(posedge clk); #1;
        if (rv !== 0) $fatal(1, "Read valid deassertion");
        $display("PASS cache: slice mask, write stall, read valid");

        // Q8.8 bias preloaded through the multiplier, then x*a.
        mac(19'sd16, 18'sd128, 48'sd2048);
        mac(19'sd32, 18'sd384, 48'sd14336);
        if ($signed(dsp_o) !== 48'sd56) $fatal(1, "Norm scale");
        @(negedge clk); dsp_ce = 0; a = 999; b = 999;
        @(posedge clk); #1;
        if ($signed(acc) !== 48'sd14336) $fatal(1, "Accumulator hold");
        @(negedge clk); dsp_reset = 1;
        @(posedge clk); #1;
        if (acc !== 0) $fatal(1, "Accumulator clear");
        @(negedge clk); dsp_reset = 0;
        mac(19'sd16, 18'sd32767, 48'sd524272);
        mac(-19'sd128, -18'sd32768, 48'sd4718576);
        mac(19'sd127, -18'sd32768, 48'sd557040);
        $display("PASS DSP: feedback MAC, CE hold, clear, full-range bias, signed products");
        $display("LIMIT: no synthesis, timing, pipelined-front-end or complete DW verification");
        $finish;
    end
endmodule
