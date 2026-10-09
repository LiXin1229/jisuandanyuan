// Epoch11 deployment variant: fixed model ROM, extended 128-bit commands.
// Feature tile transfers and network scheduling are supplied by the host/DMA.
module cyclegan_bus_top (
    input wire clk,reset,bus_wr,bus_rd,
    input wire [5:0] bus_addr,
    input wire [31:0] bus_wdata,
    output wire bus_ready,
    output wire [31:0] bus_rdata,
    output wire bus_rvalid,busy,done_sticky,
    output wire [3:0] error_code
);
    mobilenet_bus_top #(.MODEL_PARAMS(1)) core(.*);
endmodule
