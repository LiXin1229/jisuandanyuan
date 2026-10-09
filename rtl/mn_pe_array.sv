// Four clocks from in_valid acceptance through A/B, P, W, O.
// A/B/P keep running on bubbles; only W's CE follows delayed valid.
module mn_pe_array (
    input wire clk, reset, clear,
    input wire in_valid, in_last,
    input wire [799:0] in_data,
    input wire signed [17:0] weight,
    output wire [3199:0] out_data,
    output wire out_valid, out_last
);
    reg [3:0] val_pipe, last_pipe;
    always @(posedge clk) begin
        if (reset || clear) begin val_pipe<=0; last_pipe<=0; end
        else begin
            val_pipe<={val_pipe[2:0],in_valid};
            last_pipe<={last_pipe[2:0],in_valid && in_last};
        end
    end
    assign out_valid=val_pipe[3];
    assign out_last=last_pipe[3];
    genvar p;
    generate for(p=0;p<100;p=p+1) begin: pe
        wire [47:0] result;
        EFX_DSP48 #(.MODE("NORMAL"), .SIGNED(1), .A_REG(1), .B_REG(1),
            .P_REG(1), .W_REG(1), .O_REG(1), .RST_SYNC(1),
            .M_SEL("P"), .N_SEL("W"), .W_SEL("X"),
            .P_EXT("ALIGN_RIGHT"), .A_REG_USE_CE(0), .B_REG_USE_CE(0),
            .P_REG_USE_CE(0), .O_REG_USE_CE(0),
            .A_REG_USE_RST(0), .B_REG_USE_RST(0), .P_REG_USE_RST(0)) dsp (
            .A({{11{in_data[p*8+7]}},in_data[p*8+:8]}), .B(weight),
            .C(18'd0), .CASCIN(48'd0), .OP(2'b00), .SHIFT_ENA(1'b0),
            .CLK(clk), .CE(val_pipe[1]), .RST(reset || clear),
            .O(result), .CASCOUT(), .OVFL());
        // PW <=32 and single-channel DW <=49 have a proven signed32 bound.
        assign out_data[p*32+:32]=result[31:0];
    end endgenerate
endmodule
