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
    // Logical banks 0/1 share native TDP 1024x10 planes; bank 2 is SDP 512x20.
    // Host and core writes to the first 1024 addresses use different physical
    // ports, removing an 800-bit write-data mux. Reads share port B since host
    // memory traffic is accepted only while the core is idle.
    wire read_enable=rd_en || host_rd;
    wire [10:0] read_addr=host_rd ? host_raddr : rd_addr;
    wire [799:0] main_data,third_data;
    reg read_third,read_ok;
    genvar b,s;
    generate for(b=0;b<80;b=b+1) begin: main_plane
        wire core_write=wr_en && !wr_addr[10] && wr_quadrants[b/20];
        wire read_main=read_enable && !read_addr[10];
        EFX_DPRAM10 #(.READ_WIDTH_A(10),.WRITE_WIDTH_A(10),
            .READ_WIDTH_B(10),.WRITE_WIDTH_B(10),.OUTPUT_REG_A(0),.OUTPUT_REG_B(0)) ram (
            .CLKA(clk),.WEA(host_wr && !host_waddr[10] && host_mask[b/2]),
            .CLKEA(host_wr && !host_waddr[10]),.RSTA(reset),
            .ADDRENA(host_wr && !host_waddr[10]),.WDATAA(host_wdata[b*10+:10]),
            .ADDRA(host_waddr[9:0]),.RDATAA(),
            .CLKB(clk),.WEB(core_write),.CLKEB(core_write || read_main),.RSTB(reset),
            .ADDRENB(core_write || read_main),.WDATAB(wr_data[b*10+:10]),
            .ADDRB(core_write ? wr_addr[9:0] : read_addr[9:0]),.RDATAB(main_data[b*10+:10]));
    end
    for(s=0;s<40;s=s+1) begin: third_plane
            wire host_write=host_wr && host_waddr[10:9]==2;
            wire core_write=wr_en && wr_addr[10:9]==2;
            wire write_slice=host_write ? host_mask[s] : core_write && wr_quadrants[s/10];
            wire read_bank=read_enable && read_addr[10:9]==2;
            EFX_RAM10 #(.READ_WIDTH(20),.WRITE_WIDTH(20),.OUTPUT_REG(0)) ram (
                .WCLK(clk),.WE({2{write_slice}}),.WCLKE(1'b1),
                .WADDREN(write_slice),
                .WDATA(host_write ? host_wdata[s*20+:20] : wr_data[s*20+:20]),
                .WADDR(host_write ? host_waddr[8:0] : wr_addr[8:0]),
                .RCLK(clk),.RE(read_bank),.RST(reset),.RADDREN(read_bank),
                .RDATA(third_data[s*20+:20]),.RADDR(read_addr[8:0]));
    end endgenerate
    wire [799:0] selected=((read_third ? third_data : main_data)&{800{read_ok}});
    assign rd_data=selected;
    assign host_rdata=selected;
    always @(posedge clk) begin
        if(reset) begin rd_valid<=0;host_rvalid<=0;read_third<=0;read_ok<=0;end
        else begin
            rd_valid<=rd_en;host_rvalid<=host_rd;
            if(read_enable) begin read_third<=read_addr[10];read_ok<=read_addr[10:9]!=3;end
        end
    end
endmodule
