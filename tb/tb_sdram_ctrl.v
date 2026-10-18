//=============================================================================
//  tb_sdram_ctrl.v -- sdram_ctrl 的功能验证
//
//  时钟: sys_clk 100MHz; sdram_clk 超前 3ns(模拟 PLL 移相,见 README 时序分析).
//  模型: sdram_model(带 tAC=5ns、初始化序列检查、tRCD/tRC/刷新检查).
//
//  测试项:
//    1. 初始化完成时间约为 200us(+ overhead < 1us),且模型确认序列正确.
//    2. 单字写/读回.
//    3. 字节使能(DQM).
//    4. 跨 bank/跨行读写.
//    5. 64 字连续写 + 连续读.
//    6. 2000 次随机读写(记分牌).
//    7. 空闲 30us,检查自动刷新发生且最大间隔 <= 8.2us.
//    8. busy 时打 req 置起 err_busy_req.
//=============================================================================

`timescale 1ns / 1ps

module tb_sdram_ctrl;

    reg sys_clk;
    reg sdram_clk;
    reg rst_n;

    // 用户侧
    reg        wr_req;
    reg [23:0] wr_addr;
    reg [15:0] wr_data;
    reg [1:0]  wr_be;
    reg        rd_req;
    reg [23:0] rd_addr;
    wire [15:0] rd_data;
    wire        rd_valid;
    wire        busy;
    wire        init_done;
    wire        err_busy_req;

    // SDRAM 侧
    wire [12:0] s_a;
    wire [1:0]  s_ba;
    wire        s_cke;
    wire        s_cs_n, s_ras_n, s_cas_n, s_we_n;
    wire [1:0]  s_dqm;
    wire [15:0] dut_dq_out;
    wire        dut_dq_oe;
    wire [15:0] dut_dq_in;
    wire [15:0] sdq;

    // 时钟: sys 100MHz; sdram_clk 超前 3ns
    initial begin
        sys_clk = 1'b0;
        forever #5 sys_clk = ~sys_clk;
    end
    initial begin
        sdram_clk = 1'b0;
        #2;
        forever #5 sdram_clk = ~sdram_clk;
    end

    sdram_ctrl dut (
        .clk        (sys_clk),
        .rst_n      (rst_n),
        .wr_req     (wr_req),
        .wr_addr    (wr_addr),
        .wr_data    (wr_data),
        .wr_be      (wr_be),
        .rd_req     (rd_req),
        .rd_addr    (rd_addr),
        .rd_data    (rd_data),
        .rd_valid   (rd_valid),
        .busy       (busy),
        .init_done  (init_done),
        .err_busy_req (err_busy_req),
        .s_a        (s_a),
        .s_ba       (s_ba),
        .s_cke      (s_cke),
        .s_cs_n     (s_cs_n),
        .s_ras_n    (s_ras_n),
        .s_cas_n    (s_cas_n),
        .s_we_n     (s_we_n),
        .s_dqm      (s_dqm),
        .s_dq_out   (dut_dq_out),
        .s_dq_oe    (dut_dq_oe),
        .s_dq_in    (dut_dq_in)
    );

    // DQ 三态互连
    assign sdq      = dut_dq_oe ? dut_dq_out : 16'hzzzz;
    assign dut_dq_in = sdq;

    sdram_model #(
        .CL  (3),
        .TAC (5)
    ) mem (
        .clk   (sdram_clk),
        .cke   (s_cke),
        .cs_n  (s_cs_n),
        .ras_n (s_ras_n),
        .cas_n (s_cas_n),
        .we_n  (s_we_n),
        .a     (s_a),
        .ba    (s_ba),
        .dqm   (s_dqm),
        .dq    (sdq)
    );

    integer err;
    integer t_rst_rel;
    integer aref_before;

    // 地址拼接: {bank[1:0], row[12:0], col[8:0]}
    function [23:0] mkaddr;
        input [1:0] b; input [12:0] r; input [8:0] c;
        begin mkaddr = {b, r, c}; end
    endfunction

    task sdram_write;
        input [23:0] addr;
        input [15:0] data;
        input [1:0]  be;
        begin
            wait (busy == 1'b0);
            @(negedge sys_clk); // 下降沿驱动,上升沿采样,无竞争
            wr_req = 1'b1; wr_addr = addr; wr_data = data; wr_be = be;
            @(negedge sys_clk);
            wr_req = 1'b0;
            wait (busy == 1'b1);
            wait (busy == 1'b0);
        end
    endtask

    task sdram_read;
        input  [23:0] addr;
        output [15:0] data;
        begin
            wait (busy == 1'b0);
            @(negedge sys_clk); // 下降沿驱动,上升沿采样,无竞争
            rd_req = 1'b1; rd_addr = addr;
            @(negedge sys_clk);
            rd_req = 1'b0;
            wait (rd_valid == 1'b1);
            data = rd_data;
            @(posedge sys_clk);
        end
    endtask

    task check_eq;
        input [23:0] addr;
        input [15:0] exp;
        input [15:0] got;
        begin
            if (got !== exp) begin
                err = err + 1;
                $display("FAIL @%0t: addr=%h exp=%h got=%h", $time, addr, exp, got);
            end
        end
    endtask

    // 随机测试记分牌(256 条目)
    reg [23:0] sb_addr [0:255];
    reg [15:0] sb_data [0:255];
    integer    sb_cnt;

    integer seed;
    integer i, k;
    reg [15:0] rdata;
    reg [23:0] rnd_addr;
    reg [15:0] rnd_data;

    initial begin
        $dumpfile("tb_sdram_ctrl.vcd");
        $dumpvars(0, tb_sdram_ctrl);

        err = 0; sb_cnt = 0; seed = 12345;
        if ($value$plusargs("SEED=%d", seed))
            $display("INFO: 使用随机种子 %0d", seed);
        wr_req = 0; rd_req = 0; wr_be = 2'b11;
        wr_addr = 0; wr_data = 0; rd_addr = 0;
        rst_n = 1'b0;
        #100;
        rst_n = 1'b1;
        t_rst_rel = $time;

        // ---- 1. 等待初始化完成,检查耗时 ----
        wait (init_done == 1'b1);
        $display("INFO: init_done @%0t ns (复位释放后 %0d ns)",
                 $time, $time - t_rst_rel);
        if (($time - t_rst_rel < 200000) || ($time - t_rst_rel > 202000)) begin
            err = err + 1;
            $display("FAIL: 初始化耗时异常,期望约 200us");
        end
        if (mem.err_cnt != 0) begin
            err = err + 1;
            $display("FAIL: 模型报告初始化序列错误");
        end
        repeat (10) @(posedge sys_clk);

        // ---- 2. 单字写/读 ----
        sdram_write(mkaddr(2'b01, 13'h1ABC, 9'h012), 16'hA5A5, 2'b11);
        sdram_read(mkaddr(2'b01, 13'h1ABC, 9'h012), rdata);
        check_eq(mkaddr(2'b01, 13'h1ABC, 9'h012), 16'hA5A5, rdata);
        $display("INFO: 单字读写测试完成");

        // ---- 3. 字节使能 ----
        sdram_write(mkaddr(2'b00, 13'h0001, 9'h000), 16'hFFFF, 2'b11);
        sdram_read(mkaddr(2'b00, 13'h0001, 9'h000), rdata);
        check_eq(24'h0, 16'hFFFF, rdata);
        sdram_write(mkaddr(2'b00, 13'h0001, 9'h000), 16'h0034, 2'b01); // 只写低字节
        sdram_read(mkaddr(2'b00, 13'h0001, 9'h000), rdata);
        check_eq(24'h0, 16'hFF34, rdata);
        sdram_write(mkaddr(2'b00, 13'h0001, 9'h000), 16'h1200, 2'b10); // 只写高字节
        sdram_read(mkaddr(2'b00, 13'h0001, 9'h000), rdata);
        check_eq(24'h0, 16'h1234, rdata);
        $display("INFO: 字节使能测试完成");

        // ---- 4. 跨 bank/跨行 ----
        for (i = 0; i < 16; i = i + 1)
            sdram_write(mkaddr(i[1:0], 13'h1000 + i, i[8:0]), 16'hB000 + i, 2'b11);
        for (i = 0; i < 16; i = i + 1) begin
            sdram_read(mkaddr(i[1:0], 13'h1000 + i, i[8:0]), rdata);
            check_eq(mkaddr(i[1:0], 13'h1000 + i, i[8:0]), 16'hB000 + i, rdata);
        end
        $display("INFO: 跨 bank/行测试完成");

        // ---- 5. 64 字连续 ----
        for (i = 0; i < 64; i = i + 1)
            sdram_write(mkaddr(2'b10, 13'h0055, i[8:0]), 16'h6000 + i, 2'b11);
        for (i = 0; i < 64; i = i + 1) begin
            sdram_read(mkaddr(2'b10, 13'h0055, i[8:0]), rdata);
            check_eq(mkaddr(2'b10, 13'h0055, i[8:0]), 16'h6000 + i, rdata);
        end
        $display("INFO: 64 字连续读写测试完成");

        // ---- 6. 随机压力测试(2000 次,期间必穿过多次刷新) ----
        for (k = 0; k < 2000; k = k + 1) begin
            rnd_addr = {$random(seed)} & 24'hFFFFF; // 低 20 位随机
            rnd_data = $random(seed);
            if (($random(seed) & 1) || sb_cnt == 0) begin
                // 写
                sdram_write(rnd_addr, rnd_data, 2'b11);
                if (sb_cnt < 256) begin
                    sb_addr[sb_cnt] = rnd_addr;
                    sb_data[sb_cnt] = rnd_data;
                    sb_cnt = sb_cnt + 1;
                end else begin
                    i = $random(seed) & 255;
                    sb_addr[i] = rnd_addr;
                    sb_data[i] = rnd_data;
                end
            end else begin
                // 读记分牌中的地址($random 可为负,先取绝对值再取模)
                i = ($random(seed) & 32'h7fffffff) % sb_cnt;
                sdram_read(sb_addr[i], rdata);
                check_eq(sb_addr[i], sb_data[i], rdata);
            end
        end
        $display("INFO: 随机压力测试完成,模型 err_cnt=%0d", mem.err_cnt);
        if (mem.err_cnt != 0) begin
            err = err + 1;
            $display("FAIL: 模型报告协议/时序违例");
        end

        // ---- 7. 空闲刷新检查 ----
        aref_before = mem.aref_cnt;
        #30000; // 空闲 30us
        $display("INFO: 30us 空闲内刷新次数=%0d, 最大间隔=%0d ns",
                 mem.aref_cnt - aref_before, mem.aref_max_gap);
        if (mem.aref_cnt - aref_before < 3) begin
            err = err + 1;
            $display("FAIL: 自动刷新次数不足");
        end
        if (mem.aref_max_gap > 8200) begin
            err = err + 1;
            $display("FAIL: 刷新间隔超标(>8.2us)");
        end

        // ---- 8. busy 时打 req ----
        wait (busy == 1'b0);
        @(negedge sys_clk);
        wr_req = 1'b1; wr_addr = 24'h0; wr_data = 16'h0; wr_be = 2'b11;
        @(negedge sys_clk);
        // 此时 busy 应已拉高,保持 req 再打一拍以触发错误标志
        @(negedge sys_clk);
        wr_req = 1'b0;
        wait (busy == 1'b0);
        if (err_busy_req !== 1'b1) begin
            err = err + 1;
            $display("FAIL: err_busy_req 未置位");
        end else begin
            $display("INFO: err_busy_req 行为正确");
        end

        // ---- 汇总 ----
        #1000;
        if (err == 0 && mem.err_cnt == 0)
            $display("PASS: 全部测试通过");
        else
            $display("FAIL: 共 %0d 处错误(模型 %0d)", err, mem.err_cnt);
        $finish;
    end

    // 看门狗
    initial begin
        #10_000_000;
        $display("FAIL: 仿真超时");
        $finish;
    end

endmodule
