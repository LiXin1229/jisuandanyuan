// Shared signed32 -> {signed16 overflow, true sign, low16} conversion.
// Five LUT4s compare three high bits to the sign; two LUT4s reduce them
// together with the remaining bit. Seven LUT4s per lane, no registers.
module mn_compact (
    input wire [3199:0] in_data,
    output wire [1799:0] out_data
);
    genvar p,g;
    generate for(p=0;p<100;p=p+1) begin: lane
        wire [31:0] s=in_data[p*32+:32];
        wire [4:0] mismatch;
        wire partial_overflow,overflow;
        for(g=0;g<5;g=g+1) begin: high_group
            EFX_LUT4 #(.LUTMASK(16'h7ffe)) compare (
                .I0(s[15+g*3]),.I1(s[16+g*3]),.I2(s[17+g*3]),
                .I3(s[31]),.O(mismatch[g]));
        end
        EFX_LUT4 #(.LUTMASK(16'hfffe)) reduce_four (
            .I0(mismatch[0]),.I1(mismatch[1]),.I2(mismatch[2]),
            .I3(mismatch[3]),.O(partial_overflow));
        EFX_LUT4 #(.LUTMASK(16'heffe)) reduce_last (
            .I0(partial_overflow),.I1(mismatch[4]),.I2(s[30]),
            .I3(s[31]),.O(overflow));
        assign out_data[p*18+:18]={overflow,s[31],s[15:0]};
    end endgenerate
endmodule
