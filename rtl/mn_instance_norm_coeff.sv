`timescale 1ns/1ps
// One shared Efinix SINGLE sqrt and iterative Divider_2 for all channels.
// See tools/live_norm_reference.py for the exact integer contract.
module generator_norm_coeff(
 input wire clk,rstn,start,input wire [16:0] count,
 input wire signed [24:0] total,input wire [30:0] squares,
 input wire signed [15:0] gamma,beta,
 output wire busy,output reg done,fault,
 output reg signed [15:0] a,b);
 localparam IDLE=0,MUL_REQ=1,MUL_WAIT=2,VAR=3,ROOT_INIT=4,
  ROOT_REQ=5,ROOT_WAIT=6,DIV_A_REQ=7,DIV_A_WAIT=8,ROUND_A=9,
  DIV_B_INIT=10,DIV_B_REQ=11,DIV_B_WAIT=12,ROUND_B=13;
 localparam PROD_NT=0,PROD_SS=1,PROD_GN=2,PROD_BR=3,PROD_GS=4;
 reg [3:0] state=0;
 reg [16:0] n;
 reg signed [24:0] s;
 reg signed [15:0] g,be;
 reg [47:0] nt,ss,d;
 reg [79:0] rad;
 reg [39:0] root;
 reg [63:0] dividend,quotient;
 reg [39:0] remainder;
 reg negative;
 reg signed [63:0] numerator_b;
 reg [2:0] product_kind;
 reg [39:0] mul_x;
 reg [24:0] mul_y;
 reg [55:0] beta_root;
 wire mul_busy,mul_done;
 wire [64:0] mul_product;
 generator_norm_mul u_mul(.clk(clk),.rstn(rstn),.start(state==MUL_REQ),
  .x(mul_x),.y(mul_y),.busy(mul_busy),.done(mul_done),.product(mul_product));
 wire [39:0] ip_root;
 wire sqrt_done,sqrt_idle,div_ready,div_done,div_zero;
 wire [63:0] ip_quotient;
 wire [39:0] ip_remainder;
 norm_sqrt80 u_sqrt(.sysclk(clk),.reset_n(rstn),.clken(1'b1),
  .calcen(state==ROOT_REQ && sqrt_idle),.din(rad),.vout(ip_root),
  .rout(),.calcend(sqrt_done),.sqrtidle(sqrt_idle));
 norm_div64_40 u_div(.clk(clk),.reset(!rstn),.clken(1'b1),
  .in_valid((state==DIV_A_REQ || state==DIV_B_REQ) && div_ready),
  .numer(dividend),.denom(root),.quotient(ip_quotient),.remain(ip_remainder),
  .rfd(div_ready),.rdy(div_done),.div_by_zero(div_zero));
 // Preserve ties-to-even on the magnitude, then restore sign and saturate.
 wire [40:0] twice_remainder={remainder,1'b0};
 wire round_up=(twice_remainder>{1'b0,root}) ||
  ((twice_remainder=={1'b0,root}) && quotient[0]);
 // Any quotient above 65535 is already saturated. Carry only 16 bits into
 // the final signed16 result instead of a 64-bit add/compare/negate chain.
 wire [16:0] rounded={1'b0,quotient[15:0]}+round_up;
 wire rounded_high=|quotient[63:16];
 wire [24:0] abs_sum=s[24] ? (~s+25'd1) : s;
 wire [15:0] abs_gamma=g[15] ? (~g+16'd1) : g;
 wire [15:0] abs_beta=be[15] ? (~be+16'd1) : be;
 wire signed [63:0] br_signed=be[15] ? -$signed({8'd0,beta_root}) : $signed({8'd0,beta_root});
 wire signed [63:0] gs_signed=(g[15]^s[24]) ? -$signed(mul_product[63:0]) : $signed(mul_product[63:0]);
 function [55:0] epsilon;
  input [16:0] samples;
  begin case(samples)
   // Filled from exact rational round(256*N*N*2**32/100000).
   76800:epsilon=56'd64851834634135142;
   19200:epsilon=56'd4053239664633446;
   4800:epsilon=56'd253327479039590;
   1200:epsilon=56'd15832967439974;
   default:epsilon=0;
  endcase end
 endfunction
 function [15:0] saturated;
  input [16:0] magnitude;input sign_bit,high_bits;
  begin
   if(high_bits || |magnitude[16:15]) saturated=sign_bit ? 16'h8000 : 16'h7fff;
   else saturated=sign_bit ? -magnitude[15:0] : magnitude[15:0];
  end
 endfunction
 assign busy=state!=IDLE;
 always @(posedge clk) begin
  done<=0;
  if(!rstn) begin state<=IDLE;done<=0;fault<=0;a<=0;b<=0;end
  else case(state)
   IDLE:if(start) begin
    n<=count;s<=total;g<=gamma;be<=beta;fault<=0;
    mul_x<={9'd0,squares};mul_y<={8'd0,count};
    product_kind<=PROD_NT;state<=MUL_REQ;
   end
   MUL_REQ:if(!mul_busy) state<=MUL_WAIT;
   MUL_WAIT:if(mul_done) begin
    case(product_kind)
     PROD_NT:begin
      nt<=mul_product[47:0];mul_x<={15'd0,abs_sum};mul_y<=abs_sum;
      product_kind<=PROD_SS;state<=MUL_REQ;
     end
     PROD_SS:begin ss<=mul_product[47:0];state<=VAR;end
     PROD_GN:begin
      dividend<=mul_product[63:0]<<20;negative<=g[15];
      mul_x<=root;mul_y<={9'd0,abs_beta};
      product_kind<=PROD_BR;state<=MUL_REQ;
     end
     PROD_BR:begin
      beta_root<=mul_product[55:0];mul_x<={15'd0,abs_sum};mul_y<={9'd0,abs_gamma};
      product_kind<=PROD_GS;state<=MUL_REQ;
     end
     PROD_GS:begin
      // Use the unrounded gamma*sum product, independently of saturated a.
      numerator_b<=br_signed-(gs_signed<<<16);state<=DIV_A_REQ;
     end
     default:begin fault<=1;done<=1;state<=IDLE;end
    endcase
   end
   VAR:begin
    d<=nt-ss;
    if(nt<ss || epsilon(n)==0) begin fault<=1;done<=1;state<=IDLE;end
    else state<=ROOT_INIT;
   end
   ROOT_INIT:begin rad<={d,32'd0}+{24'd0,epsilon(n)};state<=ROOT_REQ;end
   ROOT_REQ:if(sqrt_idle) state<=ROOT_WAIT;
   ROOT_WAIT:if(sqrt_done) begin
    if(ip_root==0) begin fault<=1;done<=1;state<=IDLE;end
    else begin
     root<=ip_root;mul_x<={24'd0,abs_gamma};mul_y<={8'd0,n};
     product_kind<=PROD_GN;state<=MUL_REQ;
    end
   end
   DIV_A_REQ,DIV_B_REQ:if(div_ready) state<=state==DIV_A_REQ ? DIV_A_WAIT : DIV_B_WAIT;
   DIV_A_WAIT,DIV_B_WAIT:if(div_done) begin
    if(div_zero) begin fault<=1;done<=1;state<=IDLE;end
    else begin
     quotient<=ip_quotient;remainder<=ip_remainder;
     state<=state==DIV_A_WAIT ? ROUND_A : ROUND_B;
    end
   end
   ROUND_A:begin a<=saturated(rounded,negative,rounded_high);state<=DIV_B_INIT;end
   DIV_B_INIT:begin
    dividend<=numerator_b<0 ? -numerator_b : numerator_b;negative<=numerator_b<0;
    state<=DIV_B_REQ;
   end
   ROUND_B:begin b<=saturated(rounded,negative,rounded_high);done<=1;state<=IDLE;end
   default:begin fault<=1;done<=1;state<=IDLE;end
  endcase
 end
endmodule

// Exact unsigned 40x25 multiplication using one registered 17x17 multiplier.
// Six limb products share the same datapath; fixed shifts retain all 65 bits.
module generator_norm_mul(
 input wire clk,rstn,start,input wire [39:0] x,input wire [24:0] y,
 output wire busy,output reg done,output wire [64:0] product);
 localparam IDLE=0,MULTIPLY=1,ACCUMULATE=2;
 reg [1:0] state=0;
 reg [2:0] limb;
 reg [39:0] x_hold;
 reg [24:0] y_hold;
 reg [33:0] partial_product;
 reg [64:0] accumulated;
 wire [16:0] limb_x=(limb==0 || limb==3) ? x_hold[16:0] :
  (limb==1 || limb==4) ? x_hold[33:17] : {11'd0,x_hold[39:34]};
 wire [16:0] limb_y=limb<3 ? y_hold[16:0] : {9'd0,y_hold[24:17]};
 reg [64:0] shifted_product;
 always @* begin
  case(limb)
   0:shifted_product={31'd0,partial_product};
   1,3:shifted_product={14'd0,partial_product,17'd0};
   2,4:shifted_product={partial_product[30:0],34'd0};
   5:shifted_product={partial_product[13:0],51'd0};
   default:shifted_product=0;
  endcase
 end
 assign busy=state!=IDLE;
 assign product=accumulated;
 always @(posedge clk) begin
  done<=0;
  if(!rstn) begin state<=IDLE;done<=0;accumulated<=0;end
  else case(state)
   IDLE:if(start) begin x_hold<=x;y_hold<=y;limb<=0;accumulated<=0;state<=MULTIPLY;end
   MULTIPLY:begin partial_product<=limb_x*limb_y;state<=ACCUMULATE;end
   ACCUMULATE:begin
    accumulated<=accumulated+shifted_product;
    if(limb==5) begin done<=1;state<=IDLE;end
    else begin limb<=limb+1'b1;state<=MULTIPLY;end
   end
   default:state<=IDLE;
  endcase
 end
endmodule
