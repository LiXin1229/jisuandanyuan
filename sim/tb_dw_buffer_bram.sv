`timescale 1ns/1ps
module tb_dw_buffer_bram;
    reg clk=0;always #5 clk=~clk;
    reg reset=1,load_en=0,load_zero=0,pad_en=0,pad_axis=0,pad_zero=0;
    reg init_start=0,prefetch_en=0,rotate_en=0;
    reg [3:0] load_owner=0,pad_dst=0,pad_src=0;
    reg [2:0] init_x=0,init_y=0;
    reg [1:0] prefetch_dir=0,rotate_dir=0;
    reg [799:0] tile=0;
    wire load_done,load_last,pad_done,init_done;
    wire [799:0] pixels;
    mn_dw_buffer_bram dut(.*);
    reg [7:0] golden[0:255];
    integer checks=0,seed,k,axis,dst,src,z,oy,ox,p,rr,cc,j,kw,kh,radius,area;
    integer tap_x[0:48],tap_y[0:48],direction[0:48];
    function automatic [7:0] value(input integer y,x,s);
        value=((y*31+x*17+s*43+10000)%251)-125;
    endfunction
    task automatic load_all(input integer s,input bit zero_center);
        integer owner,n,r,c,pack,gr,gc;
        begin
            for(n=0;n<256;n=n+1) begin
                r=n/16;c=n%16;
                golden[n]=zero_center && r>=3 && r<13 && c>=3 && c<13 ? 0 : value(r-3,c-3,s);
            end
            for(owner=0;owner<9;owner=owner+1) begin
                @(negedge clk);load_en=1;load_owner=owner;load_zero=zero_center && owner==4;
                for(n=0;n<100;n=n+1) begin
                    r=n/10;c=n%10;pack=((r/5)*2+c/5)*25+(r%5)*5+c%5;
                    tile[pack*8+:8]=value(r+(owner/3-1)*10,c+(owner%3-1)*10,s);
                end
                @(negedge clk);load_en=0;
                while(!load_done) @(negedge clk);
            end
            load_zero=0;
        end
    endtask
    task automatic initialize(input integer x0,y0);
        begin
            @(negedge clk);init_x=x0;init_y=y0;init_start=1;
            @(negedge clk);init_start=0;
            while(!init_done) @(negedge clk);
        end
    endtask
    task automatic check_window(input integer x0,y0);
        begin
            #1;
            for(integer n=0;n<100;n=n+1) begin
                if(pixels[n*8+:8]!==golden[(y0+n/10)*16+x0+n%10])
                    $fatal(1,"BRAM window mismatch x=%0d y=%0d lane=%0d expected=%0h actual=%0h",x0,y0,n,
                        golden[(y0+n/10)*16+x0+n%10],pixels[n*8+:8]);
                checks=checks+1;
            end
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);reset=0;
        for(seed=0;seed<3;seed=seed+1) for(k=0;k<5;k=k+1) begin
            case(k)
                0:begin kh=1;kw=2;radius=0;end
                1:begin kh=2;kw=1;radius=0;end
                2:begin kh=2;kw=2;radius=0;end
                3:begin kh=3;kw=3;radius=1;end
                4:begin kh=7;kw=7;radius=3;end
            endcase
            load_all(seed,seed==2);
            initialize(3-radius,3-radius);
            area=kh*kw;
            for(j=0;j<area;j=j+1) begin
                rr=j/kw;cc=j%kw;
                tap_x[j]=3-radius+(rr%2 ? kw-1-cc : cc);tap_y[j]=3-radius+rr;
                direction[j]=cc==kw-1 ? 2 : rr%2 ? 1 : 0;
            end
            // Read one movement ahead, then rotate on every consecutive clock.
            prefetch_en=1;prefetch_dir=direction[0];
            @(negedge clk);
            for(j=0;j<area;j=j+1) begin
                check_window(tap_x[j],tap_y[j]);
                rotate_en=j<area-1;rotate_dir=direction[j];
                prefetch_en=j<area-2;prefetch_dir=direction[j+1<area ? j+1 : j];
                @(negedge clk);
            end
            prefetch_en=0;rotate_en=0;
        end
        // All padding axes, source/destination lines, zero fill and corners.
        // Four overlapping 10x10 views cover every byte of the backing store.
        for(axis=0;axis<2;axis=axis+1) for(dst=0;dst<16;dst=dst+1)
        for(src=0;src<12;src=src+1) for(z=0;z<2;z=z+1) begin
            load_all(src+dst+axis,0);
            @(negedge clk);pad_en=1;pad_axis=axis;pad_dst=dst;pad_src=src;pad_zero=z;
            @(negedge clk);pad_en=0;
            while(!pad_done) @(negedge clk);
            for(p=0;p<16;p=p+1)
                golden[axis ? dst*16+p : p*16+dst]=z ? 0 : golden[axis ? src*16+p : p*16+src];
            for(oy=0;oy<=6;oy=oy+6) for(ox=0;ox<=6;ox=ox+6) begin
                initialize(ox,oy);check_window(ox,oy);
            end
        end
        // Abort a partly stored tile and verify a clean subsequent reuse.
        @(negedge clk);load_en=1;load_owner=4;
        @(negedge clk);load_en=0;
        @(negedge clk);reset=1;
        @(negedge clk);reset=0;
        load_all(71,0);initialize(6,6);check_window(6,6);
        $display("PASS BRAM DW buffer: %0d pixels, eight diagonal banks, continuous snake prefetch, exhaustive padding, zero tiles and reset",checks);
        $finish;
    end
    initial begin #5000000;$fatal(1,"BRAM buffer timeout state=%0d",dut.state);end
endmodule
