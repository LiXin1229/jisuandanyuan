module mn_cache (
    input wire clk, reset,
    input wire wr_en,
    input wire [10:0] wr_addr,
    input wire [799:0] wr_data,
    input wire [3:0] wr_quadrants,
    input wire rd_en,
    input wire [10:0] rd_addr,
    output wire [799:0] rd_data,
    output reg rd_valid,
    input wire host_wr,host_rd,
    input wire [10:0] host_waddr,host_raddr,
    input wire [799:0] host_wdata,
    input wire [39:0] host_mask,
    output wire [799:0] host_rdata,
    output reg host_rvalid
);
    // 160 native 2048x5 TDP planes cover all three 512-word logical banks.
    // Port A accepts masked host writes; port B accepts core writes and reads.
    // The unused fourth logical bank remains inaccessible. A synchronous RAM
    // output reset returns zero for illegal reads without an 800-bit AND/mux.
    // Reset changes the RAM output only, never stored feature-map contents.
    wire read_enable=rd_en || host_rd;
    wire [10:0] read_addr=host_rd ? host_raddr : rd_addr;
    wire read_legal=read_addr[10:9]!=3;
    wire host_write=host_wr && host_waddr[10:9]!=3;
    wire core_write=wr_en && wr_addr[10:9]!=3;
    wire [10:0] port_b_addr=core_write ? wr_addr : read_addr;
    wire port_b_reset=reset || (read_enable && !read_legal);
    genvar b;
    generate for(b=0;b<160;b=b+1) begin: plane
        wire write_slice=core_write && wr_quadrants[b/40];
        EFX_DPRAM10 #(.READ_WIDTH_A(5),.WRITE_WIDTH_A(5),
            .READ_WIDTH_B(5),.WRITE_WIDTH_B(5),.OUTPUT_REG_A(0),.OUTPUT_REG_B(0),
            .RESET_RAM_B("SYNC"),.WRITE_MODE_B("NO_CHANGE")) ram (
            .CLKA(clk),.WEA(host_write && host_mask[b/4]),
            .CLKEA(host_write),.RSTA(reset),.ADDRENA(host_write),
            .WDATAA(host_wdata[b*5+:5]),.ADDRA(host_waddr),.RDATAA(),
            .CLKB(clk),.WEB(write_slice),.CLKEB(reset || write_slice || read_enable),
            .RSTB(port_b_reset),.ADDRENB(write_slice || (read_enable && read_legal)),
            .WDATAB(wr_data[b*5+:5]),.ADDRB(port_b_addr),.RDATAB(rd_data[b*5+:5]));
    end endgenerate
    assign host_rdata=rd_data;
    always @(posedge clk) begin
        if(reset) begin rd_valid<=0;host_rvalid<=0;end
        else begin rd_valid<=rd_en;host_rvalid<=host_rd;end
    end
endmodule
