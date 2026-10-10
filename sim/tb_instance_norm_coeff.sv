`timescale 1ns/1ps
module tb_instance_norm_coeff;
 reg clk=0;always #2.916667 clk=~clk;
 reg rstn=0,start=0;
 reg [16:0] count;reg signed [24:0] total;reg [30:0] squares;
 reg signed [15:0] gamma,beta;wire busy,done,fault;wire signed [15:0] a,b;
 reg [136:0] vectors[0:259];reg [15:0] gold_a,gold_b;
 integer i,latency,max_latency=0;
 generator_norm_coeff dut(.*);
 initial begin
  $readmemh("coeff_edge.mem",vectors);
  repeat(5) @(negedge clk);rstn=1;
  for(i=0;i<260;i=i+1) begin
   {count,total,squares,gamma,beta,gold_a,gold_b}=vectors[i];
   @(negedge clk);start=1;@(negedge clk);start=0;latency=0;
   while(!done && latency<400) begin @(negedge clk);latency=latency+1;end
   if(!done || fault || a!==gold_a || b!==gold_b)
    $fatal(1,"Coefficient edge case %0d latency=%0d fault=%0d got=%h/%h gold=%h/%h",i,latency,fault,a,b,gold_a,gold_b);
   if(latency>max_latency) max_latency=latency;
  end
  // Reset during each iterative operation must discard the in-flight result.
  for(i=0;i<2;i=i+1) begin
   @(negedge clk);start=1;@(negedge clk);start=0;
   if(i==0) wait(dut.state==dut.ROOT_WAIT);else wait(dut.state==dut.DIV_A_WAIT);
   repeat(9) @(negedge clk);rstn=0;repeat(3) @(negedge clk);rstn=1;
   repeat(90) begin @(negedge clk);if(done || busy) $fatal(1,"Stale coefficient after reset");end
  end
  @(negedge clk);start=1;@(negedge clk);start=0;wait(done);@(negedge clk);
  if(fault || a!==gold_a || b!==gold_b) $fatal(1,"Restart after reset");
  $display("PASS instance coefficient: 260 cases, four sample counts, zero variance, signed extremes, reset/restart; max_latency=%0d",max_latency);
  $finish;
 end
endmodule
