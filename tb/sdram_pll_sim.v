//=============================================================================
//  sdram_pll_sim.v -- 仅用于 iverilog 仿真的 PLL 行为模型
//  综合时删除本文件,用 Quartus MegaWizard 按 doc/PLL_设置说明.md 生成的
//  sdram_pll.v (同名模块,同端口列表) 替代.
//=============================================================================
`timescale 1ns / 1ps

module sdram_pll (
    input  wire inclk0,     // 50MHz 板载晶振
    input  wire areset,     // 异步复位,高有效
    output reg  c0,         // 100MHz, 0 度 (sys_clk)
    output reg  c1,         // 100MHz, 超前 c0 3ns(-108 度, sdram_clk)
    output reg  locked
);

    // 注:areset 仅影响 locked(行为级简化);真正的时钟门控由顶层用 locked 做.
    initial begin
        c0        = 1'b0;
        c1        = 1'b0;
        locked    = 1'b0;
        #1000 locked = 1'b1; // 模拟 PLL 锁定延时
        // c1(sdram_clk) 上升沿:2,12,22... c0(sys_clk) 上升沿:5,15,25...(超前 3ns)
        forever begin
            #2  c1 = 1'b1;
            #3  c0 = 1'b1;
            #2  c1 = 1'b0;
            #3  c0 = 1'b0;
        end
    end

endmodule
