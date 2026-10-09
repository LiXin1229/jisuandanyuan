// The PE source has two data inputs and two constants. Each output bit is a
// four-input truth table: window, cache, source[0], source[1]. Mapping it
// explicitly avoids replicated source decoders and priority-mux stages.
module mn_input_mux (
    input wire [1:0] source,
    input wire [799:0] window_pixels,cache_data,
    output wire [799:0] pixels
);
    genvar p,b;
    generate for(p=0;p<100;p=p+1) begin: pixel
        localparam R=p/10,C=p%10,PACK=((R/5)*2+C/5)*25+(R%5)*5+C%5;
        for(b=0;b<8;b=b+1) begin: bit_mux
            // Source 0=window, 1=cache, 2=16 (bias), 3=1 (rounding).
            localparam [15:0] MASK=b==0 ? 16'hf0ca : b==4 ? 16'h0fca : 16'h00ca;
            EFX_LUT4 #(.LUTMASK(MASK)) mux (
                .I0(window_pixels[p*8+b]),.I1(cache_data[PACK*8+b]),
                .I2(source[0]),.I3(source[1]),.O(pixels[p*8+b]));
        end
    end endgenerate
endmodule
