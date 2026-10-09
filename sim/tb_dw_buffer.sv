`timescale 1ns/1ps
module tb_dw_buffer;
    reg clk=0;always #5 clk=~clk;
    reg reset=1,load_en=0,load_zero=0,pad_en=0,pad_axis=0,pad_zero=0,rotate_en=0;
    reg [3:0] load_owner=0,pad_dst=0,pad_src=0;
    reg [799:0] tile=0;
    reg [1:0] rotate_dir=0;
    wire [799:0] pixels;
    integer trial,k,owner,p,r,c,pack,x,y,kr,kc,kh,kw,radius,expected,checks=0;
    integer axis,dst,src,z;
    mn_dw_buffer dut(.*);
    function automatic integer value;
        input integer y,x,seed;
        begin value=((y*31+x*17+seed*43+10000)%251)-125;end
    endfunction
    initial begin
        repeat(3) @(negedge clk);reset=0;
        for(trial=0;trial<3;trial=trial+1) for(k=0;k<5;k=k+1) begin
            case(k)
                0:begin kh=1;kw=2;radius=0;end
                1:begin kh=2;kw=1;radius=0;end
                2:begin kh=2;kw=2;radius=0;end
                3:begin kh=3;kw=3;radius=1;end
                4:begin kh=7;kw=7;radius=3;end
            endcase
            for(owner=0;owner<9;owner=owner+1) begin
                load_en=1;load_owner=owner;
                for(p=0;p<100;p=p+1) begin
                    r=p/10;c=p%10;pack=((r/5)*2+c/5)*25+(r%5)*5+c%5;
                    tile[pack*8+:8]=value(r+(owner/3-1)*10,c+(owner%3-1)*10,trial);
                end
                @(negedge clk);
            end
            load_en=0;
            rotate_en=1;rotate_dir=0;repeat(3-radius) @(negedge clk);
            rotate_dir=2;repeat(3-radius) @(negedge clk);
            rotate_en=0;
            for(kr=0;kr<kh;kr=kr+1) for(kc=0;kc<kw;kc=kc+1) begin
                x=kr%2 ? kw-1-kc : kc;
                #1;
                for(p=0;p<100;p=p+1) begin
                    expected=value(p/10+kr-radius,p%10+x-radius,trial);
                    if($signed(pixels[p*8+:8])!==expected)
                        $fatal(1,"Buffer k=%0d row=%0d col=%0d lane=%0d expected=%0d actual=%0d",k,kr,x,p,expected,$signed(pixels[p*8+:8]));
                    checks=checks+1;
                end
                rotate_en=!(kr==kh-1 && kc==kw-1);
                rotate_dir=kc==kw-1 ? 2 : kr%2 ? 1 : 0;
                @(negedge clk);
            end
            rotate_en=0;
        end
        // Every supported padding source/destination, including zero fill.
        // Reload an independent coordinate pattern before each operation.
        for(axis=0;axis<2;axis=axis+1) for(dst=0;dst<16;dst=dst+1)
        for(src=0;src<12;src=src+1) for(z=0;z<2;z=z+1) begin
            for(owner=0;owner<9;owner=owner+1) begin
                load_en=1;load_owner=owner;
                for(p=0;p<100;p=p+1) begin
                    r=p/10;c=p%10;pack=((r/5)*2+c/5)*25+(r%5)*5+c%5;
                    tile[pack*8+:8]=value(r+(owner/3-1)*10,c+(owner%3-1)*10,src+dst+axis);
                end
                @(negedge clk);
            end
            load_en=0;pad_en=1;pad_axis=axis;pad_dst=dst;pad_src=src;pad_zero=z;
            @(negedge clk);pad_en=0;
            for(p=0;p<256;p=p+1) begin
                r=p/16;c=p%16;
                expected=value(r-3,c-3,src+dst+axis);
                if(axis ? r==dst : c==dst)
                    expected=z ? 0 : value((axis ? src : r)-3,(axis ? c : src)-3,src+dst+axis);
                if($signed(dut.cell_data[p])!==expected)
                    $fatal(1,"Padding axis=%0d dst=%0d src=%0d zero=%0d cell=%0d expected=%0d actual=%0d",axis,dst,src,z,p,expected,$signed(dut.cell_data[p]));
                checks=checks+1;
            end
        end
        $display("PASS shared DW buffer: %0d pixels, five kernel shapes, snake rotations, exhaustive padding and reuse",checks);
        $finish;
    end
endmodule
