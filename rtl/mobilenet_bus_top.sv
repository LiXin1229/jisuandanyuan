// Synchronous 32-bit word-addressed host bus. Transactions accept on ready.
// Tile staging is shared between writes and read snapshots (25 words).
module mobilenet_bus_top #(parameter MODEL_PARAMS=0) (
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
    reg [10:0] cache_address;
    reg [3:0] cache_mask;
    reg [39:0] cache_slices;
    reg [14:0] parameter_address;
    wire memory_ready,command_ready,done;
    wire [2:0] queued;
    wire [799:0] cache_read_data;
    wire cache_read_valid;
    wire commit_memory=bus_wr && (bus_addr==3 || bus_addr==4 || bus_addr==6);
    assign bus_ready=!reset && (commit_memory ? memory_ready :
        bus_wr && bus_addr==7 ? command_ready : 1'b1);
    wire accept_write=bus_wr && bus_ready;
    (* syn_keep=1 *) wire [24:0] select_tile_word;
    reg [31:0] tile_read_word;
    integer read_word;
    always @* begin
        tile_read_word=0;
        for(read_word=0;read_word<25;read_word=read_word+1)
            tile_read_word=tile_read_word|(tile_staging[read_word*32+:32]&{32{select_tile_word[read_word]}});
    end
    mobilenet_unit #(.MODEL_PARAMS(MODEL_PARAMS)) unit(.clk(clk),.reset(reset),
        .instruction(command_staging),.instruction_valid(accept_write && bus_addr==7),
        .instruction_ready(command_ready),.instruction_count(queued),
        .host_cache_wr(accept_write && bus_addr==3),.host_cache_waddr(cache_address),
        .host_cache_wdata(tile_staging),.host_cache_wmask(cache_slices),
        .host_cache_rd(accept_write && bus_addr==4),.host_cache_raddr(cache_address),
        .host_memory_ready(memory_ready),.host_cache_rdata(cache_read_data),
        .host_cache_rvalid(cache_read_valid),
        .host_param_wr(accept_write && bus_addr==6),.host_param_addr(parameter_address),
        .host_param_data(bus_wdata[15:0]),.busy(busy),.done(done),.error_code(error_code));
    integer j;
    always @(posedge clk) begin
        if(reset) begin
            cache_address<=0;cache_mask<=15;cache_slices<=40'hffffffffff;parameter_address<=0;
            command_staging<=0;done_sticky<=0;bus_rvalid<=0;bus_rdata<=0;
        end else begin
            bus_rvalid<=bus_rd && bus_ready;
            if(done) done_sticky<=1;
            if(accept_write) case(bus_addr)
                0:if(bus_wdata[1]) done_sticky<=0;
                1:cache_address<=bus_wdata[10:0];
                2:begin
                    cache_mask<=bus_wdata[3:0];
                    cache_slices<={{10{bus_wdata[3]}},{10{bus_wdata[2]}},
                                  {10{bus_wdata[1]}},{10{bus_wdata[0]}}};
                end
                12:cache_slices[31:0]<=bus_wdata;
                13:cache_slices[39:32]<=bus_wdata[7:0];
                5:parameter_address<=bus_wdata[14:0];
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
                    1:bus_rdata<={21'd0,cache_address};
                    2:bus_rdata<={28'd0,cache_mask};
                    5:bus_rdata<={17'd0,parameter_address};
                    8:bus_rdata<=command_staging[31:0];
                    9:bus_rdata<=command_staging[63:32];
                    10:bus_rdata<=command_staging[95:64];
                    11:bus_rdata<=command_staging[127:96];
                    12:bus_rdata<=cache_slices[31:0];
                    13:bus_rdata<={24'd0,cache_slices[39:32]};
                    default:bus_rdata<=tile_read_word;
                endcase
            end
        end
    end
    genvar w;
    generate for(w=0;w<25;w=w+1) begin: staging_words
        assign select_tile_word[w]=bus_addr==32+w;
        always @(posedge clk) begin
            if(cache_read_valid) tile_staging[w*32+:32]<=cache_read_data[w*32+:32];
            else if(accept_write && bus_addr==32+w) tile_staging[w*32+:32]<=bus_wdata;
        end
    end endgenerate
endmodule
