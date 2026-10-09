`timescale 1ns/1ps

//===========================================================================
// mem_800_512 —— 512 深 x 800 宽（40 片 bram_10kb 同址并联）
//
//   ★ we_a[39:0]：**每片一个写使能**（本次修改新增）
//     原来这里把 bram_10kb 的 we 接死 1'b1，只有 waddren 可用；而 waddren 在
//     efx_ram10.v 里只是"地址锁存使能"：
//         WADDR_r = WADDREN ? WADDR : WADDR_r;   // 地址锁存
//         if (WE[0]) write_ram(WADDR_r, WDATA);  // 写动作**每拍都发生**
//     于是被"门控"的片会拿当前 wdata_a 往它锁存的旧地址上写 —— 没法做掩码。
//     efx_simple_dual_port_ram 里 `w_wclke` 恒 1（bram_10kb 传 WCLKE_ENABLE=0），
//     `w_we = we`，所以真正管用的是 we。
//     现在 we_a 直接驱动每片的 we：we_a[i]=0 的片这一拍完全不写。
//
//   行为兼容：we_a 全 1 时与修改前逐位一致。
//===========================================================================
module mem_800_512 (
    input                       clk,
    input                       reset,
    input                       waddren,
    input      [39:0]           we_a,           // 按片写使能：第 i 位 = 第 i 片 bram_10kb 的 we（1=本拍写这一片）
    input                       raddren,
    input      [8:0]            waddr,
    input      [19:0]           wdata_a [0:39],      // packed 数组：40 × 20
    output     [19:0]           rdata_b [0:39],      // packed 数组：40 × 20
    output                      rdata_valid,    // 读出数据有效（晚 raddren 一拍）
    input      [8:0]            raddr
);

    //=========================================================
    // 40 片 bram_10kb (512 x 20) 拼成 512 深 x 800 宽
    //   we_a[i] = 0 时该片不写（其余片照写）—— 用于池化的
    //   "只写一个 5x5 角"（一个角正好占某平面的 10 个整片）
    //
    //   ★ we 必须与 waddren 相与：efx_ram10.v 里 waddren 只是"地址锁存使能"，
    //     真正的写动作只看 we：
    //         WADDR_r = WADDREN ? WADDR : WADDR_r;   // 地址锁存
    //         if (WE[0]) write_ram(WADDR_r, WDATA);  // 写动作每拍都发生
    //     如果只用 waddren 当写使能（we 常 1 / we 由上层组合产生），
    //     不写的那一拍会把**当前 wdata 写到上次锁存的旧地址**上，把别的行冲掉。
    //=========================================================
    genvar i;
    generate
        for (i = 0; i < 40; i = i + 1) begin: SLICE
            bram_10kb u_bram (
                .clk     (clk),
                .reset   (reset),
                .re      (1'b1),
                .we      (we_a[i] & waddren),   // ★ 按片写使能，且与 waddren 相与（原来接死 1'b1）
                .waddren (waddren),
                .raddren (raddren),
                .waddr   (waddr),
                .wdata_a (wdata_a[i]),
                .rdata_b (rdata_b[i]),
                .raddr   (raddr)
            );
        end
    endgenerate

    //=========================================================
    // 读出数据有效信号：raddren 打一拍
    //=========================================================
    reg rdata_valid_r;
    always @(posedge clk) begin
        if (reset) rdata_valid_r <= 1'b0;
        else       rdata_valid_r <= raddren;    
    end

    assign rdata_valid = rdata_valid_r;

endmodule