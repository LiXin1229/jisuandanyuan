`timescale 1ns/1ps
module tb_key;
 reg clk=0,rstn=0,key_n=1;always #5 clk=~clk;
 wire style,pressed;integer presses=0;
 camera_key #(.TICK_CYCLES(4),.STABLE_TICKS(3)) dut(.clk(clk),.rstn(rstn),.key_n(key_n),.style(style),.pressed(pressed));
 always @(negedge clk) if(pressed) presses=presses+1;
 initial begin
  repeat(5) @(negedge clk);rstn=1;
  repeat(8) begin key_n=0;repeat(2) @(negedge clk);key_n=1;repeat(2) @(negedge clk);end
  repeat(20) @(negedge clk);if(!style || presses) $fatal(1,"bounce toggled mode");
  key_n=0;repeat(100) @(negedge clk);if(style || presses!=1) $fatal(1,"long press toggled more than once");
  key_n=1;repeat(30) @(negedge clk);key_n=0;repeat(40) @(negedge clk);
  if(!style || presses!=2) $fatal(1,"second press");
  $display("PASS camera key: bounce rejection, one toggle per press, long-hold and release/repress");$finish;
 end
endmodule
