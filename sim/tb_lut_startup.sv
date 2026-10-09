`timescale 1ns/1ps
module tb_lut_startup;
    wire a,b;
    reg z=0;
    EFX_LUT4 #(.LUTMASK(16'hffff)) constant_lut(.O(a));
    EFX_LUT4 #(.LUTMASK(16'h5555)) invert_initial(.I0(z),.O(b));
    initial begin
        #1;
        $display("LUT startup: constant_one=%b invert_zero=%b",a,b);
        if(a!==1 || b!==1) $fatal(1,"LUT constant-input startup evaluation");
        $finish;
    end
endmodule
