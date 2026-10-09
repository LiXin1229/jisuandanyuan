`timescale 1ns/1ps
module tb_input_mux;
    reg [1:0] source;
    reg [799:0] window_pixels,cache_data;
    wire [799:0] pixels;
    mn_input_mux dut(.*);
    integer s,t,p,r,c,pack,checks=0;
    reg [7:0] expected;
    task check;
        begin
            #1;
            for(p=0;p<100;p=p+1) begin
                r=p/10;c=p%10;
                pack=(r/5)*50+(c/5)*25+(r%5)*5+c%5;
                case(source)
                    0:expected=window_pixels[p*8+:8];
                    1:expected=cache_data[pack*8+:8];
                    2:expected=16;
                    3:expected=1;
                endcase
                if(pixels[p*8+:8]!==expected)
                    $fatal(1,"Input mux source=%0d pixel=%0d expected=%h actual=%h",source,p,expected,pixels[p*8+:8]);
                checks=checks+1;
            end
        end
    endtask
    initial begin
        // All 16 binary input combinations of every LUT, including bits 0/4.
        for(s=0;s<4;s=s+1) for(t=0;t<4;t=t+1) begin
            source=s;window_pixels={800{t[0]}};cache_data={800{t[1]}};
            check();
        end
        // Distinct packed/raster patterns exercise every lane and byte value.
        for(s=0;s<4;s=s+1) for(t=0;t<256;t=t+1) begin
            source=s;
            for(p=0;p<100;p=p+1) begin
                window_pixels[p*8+:8]=t+7*p;
                cache_data[p*8+:8]=t*13+17*p;
            end
            check();
        end
        $display("PASS PE input mux: %0d pixels, exhaustive binary truth tables and packed lane patterns",checks);
        $finish;
    end
endmodule
