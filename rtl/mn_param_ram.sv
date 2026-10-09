module mn_param_ram (
    input wire clk, reset,
    input wire wr_en,
    input wire [11:0] wr_addr,
    input wire [15:0] wr_data,
    input wire rd_en,
    input wire [11:0] rd_addr,
    output wire [15:0] rd_data,
    output reg rd_valid
);
    wire [15:0] bank_data [0:7];
    reg [2:0] read_bank;
    genvar b;
    generate for (b=0; b<8; b=b+1) begin: bank
        EFX_RAM10 #(.READ_WIDTH(16), .WRITE_WIDTH(16), .OUTPUT_REG(0),
            .WRITE_MODE("READ_FIRST")) ram (
            .WCLK(clk), .WE({2{wr_en && wr_addr[11:9]==b}}),
            .WCLKE(1'b1), .WADDREN(wr_en), .WDATA(wr_data),
            .WADDR(wr_addr[8:0]), .RCLK(clk), .RE(rd_en), .RST(reset),
            .RADDREN(rd_en), .RDATA(bank_data[b]), .RADDR(rd_addr[8:0]));
    end endgenerate
    assign rd_data = bank_data[read_bank];
    always @(posedge clk) begin
        if (reset) begin rd_valid<=0; read_bank<=0; end
        else begin
            rd_valid <= rd_en;
            if (rd_en) read_bank <= rd_addr[11:9];
        end
    end
endmodule
