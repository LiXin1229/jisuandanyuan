// Synchronous 32-bit word-addressed host bus. Transactions accept on ready.
// Tile staging is shared between writes and read snapshots (25 words).
module mobilenet_bus_top (
    input wire clk,reset,
    input wire bus_wr,bus_rd,
    input wire [5:0] bus_addr,
    input wire [31:0] bus_wdata,
    output wire bus_ready,
    output reg [31:0] bus_rdata,
    output reg bus_rvalid,
    output wire busy,
    output reg done_sticky,
    output wire [3:0] error_code
);
    reg [799:0] tile_staging;
    reg [127:0] command_staging;
    reg [9:0] cache_address;
    reg [3:0] cache_mask;
    reg [11:0] parameter_address;
    wire memory_ready,command_ready,done;
    wire [2:0] queued;
    wire [799:0] cache_read_data;
    wire cache_read_valid;
    wire commit_memory=bus_wr && (bus_addr==3 || bus_addr==4 || bus_addr==6);
    assign bus_ready=!reset && (commit_memory ? memory_ready :
        bus_wr && bus_addr==7 ? command_ready : 1'b1);
    wire accept_write=bus_wr && bus_ready;
    mobilenet_unit unit(.clk(clk),.reset(reset),
        .instruction(command_staging),.instruction_valid(accept_write && bus_addr==7),
        .instruction_ready(command_ready),.instruction_count(queued),
        .host_cache_wr(accept_write && bus_addr==3),.host_cache_waddr(cache_address),
        .host_cache_wdata(tile_staging),.host_cache_wmask(cache_mask),
        .host_cache_rd(accept_write && bus_addr==4),.host_cache_raddr(cache_address),
        .host_memory_ready(memory_ready),.host_cache_rdata(cache_read_data),
        .host_cache_rvalid(cache_read_valid),
        .host_param_wr(accept_write && bus_addr==6),.host_param_addr(parameter_address),
        .host_param_data(bus_wdata[15:0]),.busy(busy),.done(done),.error_code(error_code));
    integer j;
    always @(posedge clk) begin
        if(reset) begin
            cache_address<=0;cache_mask<=15;parameter_address<=0;
            command_staging<=0;done_sticky<=0;bus_rvalid<=0;bus_rdata<=0;
        end else begin
            bus_rvalid<=bus_rd && bus_ready;
            if(done) done_sticky<=1;
            if(accept_write) case(bus_addr)
                0:if(bus_wdata[1]) done_sticky<=0;
                1:cache_address<=bus_wdata[9:0];
                2:cache_mask<=bus_wdata[3:0];
                5:parameter_address<=bus_wdata[11:0];
                6:parameter_address<=parameter_address+1'b1;
                8:command_staging[31:0]<=bus_wdata;
                9:command_staging[63:32]<=bus_wdata;
                10:command_staging[95:64]<=bus_wdata;
                11:command_staging[127:96]<=bus_wdata;
                default: ;
            endcase
            if(bus_rd && bus_ready) begin
                case(bus_addr)
                    0:bus_rdata<={20'd0,queued,1'b0,error_code,1'b0,memory_ready,done_sticky,busy};
                    1:bus_rdata<={22'd0,cache_address};
                    2:bus_rdata<={28'd0,cache_mask};
                    5:bus_rdata<={20'd0,parameter_address};
                    8:bus_rdata<=command_staging[31:0];
                    9:bus_rdata<=command_staging[63:32];
                    10:bus_rdata<=command_staging[95:64];
                    11:bus_rdata<=command_staging[127:96];
                    default:bus_rdata<=bus_addr>=32 && bus_addr<=56 ?
                        tile_staging[(bus_addr-6'd32)*32+:32] : 32'd0;
                endcase
            end
        end
    end
    genvar w;
    generate for(w=0;w<25;w=w+1) begin: staging_words
        always @(posedge clk) begin
            if(cache_read_valid) tile_staging[w*32+:32]<=cache_read_data[w*32+:32];
            else if(accept_write && bus_addr==32+w) tile_staging[w*32+:32]<=bus_wdata;
        end
    end endgenerate
endmodule
