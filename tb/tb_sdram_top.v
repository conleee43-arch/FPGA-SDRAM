//=============================================================================
//  tb_sdram_top.v -- 板级顶层集成冒烟测试
//  sdram_top(含 PLL 仿真模型 + 控制器 + 自检) + SDRAM 行为模型.
//  检查:init_done 拉高;自检跑完多轮;err 指示灯不亮.
//=============================================================================
`timescale 1ns / 1ps

module tb_sdram_top;

    reg clk_50m;
    reg rst_n;

    wire        sdram_clk;
    wire        sdram_cke;
    wire        sdram_cs_n;
    wire        sdram_ras_n, sdram_cas_n, sdram_we_n;
    wire [1:0]  sdram_dqm;
    wire [12:0] sdram_a;
    wire [1:0]  sdram_ba;
    wire [15:0] sdram_dq;
    wire        led_init_done, led_err;

    initial begin
        clk_50m = 1'b0;
        forever #10 clk_50m = ~clk_50m; // 50MHz
    end

    sdram_top u_top (
        .clk_50m      (clk_50m),
        .rst_n        (rst_n),
        .sdram_clk    (sdram_clk),
        .sdram_cke    (sdram_cke),
        .sdram_cs_n   (sdram_cs_n),
        .sdram_ras_n  (sdram_ras_n),
        .sdram_cas_n  (sdram_cas_n),
        .sdram_we_n   (sdram_we_n),
        .sdram_dqm    (sdram_dqm),
        .sdram_a      (sdram_a),
        .sdram_ba     (sdram_ba),
        .sdram_dq     (sdram_dq),
        .led_init_done(led_init_done),
        .led_err      (led_err)
    );

    sdram_model #(
        .CL  (3),
        .TAC (5)
    ) mem (
        .clk   (sdram_clk),
        .cke   (sdram_cke),
        .cs_n  (sdram_cs_n),
        .ras_n (sdram_ras_n),
        .cas_n (sdram_cas_n),
        .we_n  (sdram_we_n),
        .a     (sdram_a),
        .ba    (sdram_ba),
        .dqm   (sdram_dqm),
        .dq    (sdram_dq)
    );

    integer err;
    integer pass0;

    initial begin
        $dumpfile("tb_sdram_top.vcd");
        $dumpvars(0, tb_sdram_top);
        err = 0;
        rst_n = 1'b0;
        #500;
        rst_n = 1'b1;

        // 等初始化完成
        wait (led_init_done == 1'b1);
        $display("INFO @%0t: init_done 拉高", $time);

        // 等自检跑完 3 轮
        pass0 = u_top.u_selftest.pass_cnt;
        wait (u_top.u_selftest.pass_cnt >= pass0 + 3);
        $display("INFO @%0t: 自检完成 3 轮, pass_cnt=%0d",
                 $time, u_top.u_selftest.pass_cnt);

        #10000;
        if (led_err !== 1'b0) begin
            err = err + 1;
            $display("FAIL: led_err 拉高,有数据 mismatch");
        end
        if (u_top.u_selftest.err_sticky !== 1'b0) begin
            err = err + 1;
            $display("FAIL: 自检 err_sticky 置位");
        end
        if (mem.err_cnt != 0) begin
            err = err + 1;
            $display("FAIL: 模型报告协议违例 %0d", mem.err_cnt);
        end

        if (err == 0)
            $display("PASS: 顶层集成测试通过(3 轮自检无错误)");
        else
            $display("FAIL: %0d 处错误", err);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("FAIL: 仿真超时");
        $finish;
    end

endmodule
