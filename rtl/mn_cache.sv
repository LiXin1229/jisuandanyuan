module mn_cache (
    input wire clk, reset,
    input wire wr_en,
    input wire [9:0] wr_addr,
    input wire [799:0] wr_data,
    input wire [3:0] wr_quadrants,
    input wire rd_en,
    input wire [9:0] rd_addr,
    output wire [799:0] rd_data,
    output reg rd_valid,
    input wire host_wr,host_rd,
    input wire [9:0] host_waddr,host_raddr,
    input wire [799:0] host_wdata,
    input wire [3:0] host_mask,
    output wire [799:0] host_rdata,
    output reg host_rvalid
);
    genvar b;
    generate for (b=0; b<80; b=b+1) begin: bank
        EFX_DPRAM10 #(.READ_WIDTH_A(10),.WRITE_WIDTH_A(10),
            .READ_WIDTH_B(10),.WRITE_WIDTH_B(10),.OUTPUT_REG_A(0),.OUTPUT_REG_B(0)) ram (
            .CLKA(clk),.WEA(host_wr && host_mask[b/20]),.CLKEA(host_wr || host_rd),
            .RSTA(reset),.ADDRENA(host_wr || host_rd),
            .WDATAA(host_wdata[b*10+:10]),.ADDRA(host_wr ? host_waddr : host_raddr),
            .RDATAA(host_rdata[b*10+:10]),
            .CLKB(clk),.WEB(wr_en && wr_quadrants[b/20]),.CLKEB(wr_en || rd_en),
            .RSTB(reset),.ADDRENB(wr_en || rd_en),.WDATAB(wr_data[b*10+:10]),
            .ADDRB(wr_en ? wr_addr : rd_addr),.RDATAB(rd_data[b*10+:10]));
    end endgenerate
    always @(posedge clk) begin
        if (reset) begin rd_valid <= 0;host_rvalid<=0;end
        else begin rd_valid <= rd_en;host_rvalid<=host_rd;end
    end
endmodule
