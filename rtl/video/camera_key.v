`timescale 1ns/1ps
// Synchronize and accept an edge only after ten continuous milliseconds.
module camera_key #(parameter TICK_CYCLES=96000,STABLE_TICKS=10)(
 input wire clk,rstn,key_n,output reg style=1,output reg pressed=0);
 localparam TW=$clog2(TICK_CYCLES),DW=$clog2(STABLE_TICKS+1);
 reg [TW-1:0] tick=0;reg [DW-1:0] stable_ticks=0;
 reg sync1=1,sync2=1,level=1;
 always @(posedge clk) begin
  sync1<=key_n;sync2<=sync1;pressed<=0;
  if(!rstn) begin tick<=0;stable_ticks<=0;sync1<=1;sync2<=1;level<=1;style<=1;end
  else if(sync2==level) begin tick<=0;stable_ticks<=0;end
  else if(tick==TICK_CYCLES-1) begin
   tick<=0;
   if(stable_ticks==STABLE_TICKS-1) begin
    stable_ticks<=0;level<=sync2;
    if(!sync2) begin style<=~style;pressed<=1;end
   end else stable_ticks<=stable_ticks+1;
  end else tick<=tick+1;
 end
endmodule
