`timescale 1ns/1ps
module tb_dw_fast3;
    reg clk=0;always #5 clk=~clk;
    reg reset=1,accept=0;
    reg [3:0] owner=4,edges=0;
    reg [1:0] pad_kind=0;
    reg [799:0] tile=0;
    wire [799:0] pixels,shifted_pixels;
    genvar lane;
    generate for(lane=0;lane<100;lane=lane+1) begin: bypass
        localparam R=lane/10,C=lane%10,PACK=((R/5)*2+C/5)*25+(R%5)*5+C%5;
        assign pixels[lane*8+:8]=owner==4 ? tile[PACK*8+:8] : shifted_pixels[lane*8+:8];
    end endgenerate
    integer trial,e,pad,slot,p,r,c,x,y,dy,dx,pack,expected,checks=0;
    integer order[0:8];
    mn_dw_fast3 dut(.clk(clk),.reset(reset),.accept(accept),.owner(owner),
        .edges(edges),.pad_kind(pad_kind),.tile(tile),.pixels(shifted_pixels));
    function automatic integer value;
        input integer y,x,seed;
        begin value=((y*31+x*17+seed*43+10000)%251)-125;end
    endfunction
    initial begin
        order[0]=4;order[1]=1;order[2]=7;order[3]=3;order[4]=5;
        order[5]=0;order[6]=2;order[7]=6;order[8]=8;
        repeat(3) @(negedge clk);reset=0;
        // Consecutive nine-cycle sequences cover every edge combination,
        // zero/reflect padding, both edges of a single-tile dimension,
        // and buffer reuse with different input values.
        for(trial=0;trial<3;trial=trial+1)
        for(pad=1;pad<=2;pad=pad+1)
        for(e=0;e<16;e=e+1) begin
            edges=e;pad_kind=pad;accept=1;
            for(slot=0;slot<9;slot=slot+1) begin
                owner=order[slot];dy=owner/3-1;dx=owner%3-1;
                for(p=0;p<100;p=p+1) begin
                    r=p/10;c=p%10;pack=((r/5)*2+c/5)*25+(r%5)*5+c%5;
                    // An absent neighbor is deliberately poisoned, as the
                    // cache response holds unrelated data when RE is low.
                    tile[pack*8+:8]=((dy<0 && edges[2]) || (dy>0 && edges[3]) ||
                        (dx<0 && edges[0]) || (dx>0 && edges[1])) ? 8'h80 : value(r+dy*10,c+dx*10,trial);
                end
                #1;
                for(p=0;p<100;p=p+1) begin
                    r=p/10;c=p%10;x=c+dx;y=r+dy;
                    if((edges[0] && x<0) || (edges[1] && x>=10) ||
                       (edges[2] && y<0) || (edges[3] && y>=10)) begin
                        if(pad==1) expected=0;
                        else begin
                            if(edges[0] && x<0) x=-x;
                            if(edges[1] && x>=10) x=18-x;
                            if(edges[2] && y<0) y=-y;
                            if(edges[3] && y>=10) y=18-y;
                            expected=value(y,x,trial);
                        end
                    end else expected=value(y,x,trial);
                    if($signed(pixels[p*8+:8])!==expected)
                        $fatal(1,"Fast3 trial=%0d edges=%0h pad=%0d slot=%0d pixel=%0d expected=%0d got=%0d",
                            trial,edges,pad,owner,p,expected,$signed(pixels[p*8+:8]));
                    checks=checks+1;
                end
                @(negedge clk);
            end
        end
        accept=0;
        $display("PASS fast3 windows: %0d pixels, 96 consecutive nine-MAC sequences, all edge masks and zero/reflect padding",checks);
        $finish;
    end
endmodule
