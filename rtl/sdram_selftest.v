//=============================================================================
//  sdram_selftest.v
//  ----------------------------------------------------------------------------
//  SDRAM 上电自检 / 连续压力测试.
//
//  init_done 拉高后开始:每轮向 TEST_WORDS 个地址写 LFSR-16 伪随机数,再读回
//  比较;LFSR 种子固定,读写两遍序列一致.地址每轮基址递增 64K,轮询覆盖
//  4 个 bank.测试无限循环,相当于连续 DMA 压力测试(Altera 官方 PLL Tuning
//  文档要求必须用连续读写验证,不能只看单次访问).
//
//  输出:
//    test_run  -- 每完成一轮翻转一次(接 LED 做"心跳",证明测试在跑)
//    err_sticky-- 发现任何数据 mismatch 置 1,保持到复位(接 LED)
//    pass_cnt  -- 完成的轮数(可接 SignalTap 观察)
//-----------------------------------------------------------------------------
//  Revision:
//    2026-10-18  初版.
//=============================================================================

`timescale 1ns / 1ps

module sdram_selftest #(
    parameter integer TEST_WORDS = 4096,  // 每轮测试字数
    parameter [15:0] LFSR_SEED  = 16'hACE1
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        init_done,

    // -> sdram_ctrl 用户接口
    output reg         wr_req,
    output reg  [23:0] wr_addr,
    output reg  [15:0] wr_data,
    output reg  [1:0]  wr_be,
    output reg         rd_req,
    output reg  [23:0] rd_addr,
    input  wire [15:0] rd_data,
    input  wire        rd_valid,
    input  wire        busy,

    output reg         test_run,   // 每轮翻转
    output reg         err_sticky, // 粘滞错误
    output reg  [15:0] pass_cnt
);

    localparam S_WAIT  = 2'd0,
               S_WRITE = 2'd1,
               S_READ  = 2'd2;

    reg [1:0]  state;
    reg [11:0] idx;          // 字计数(最大 4095)
    reg [15:0] lfsr;         // 写数据 LFSR
    reg [15:0] lfsr_exp;     // 读期望 LFSR
    reg [11:0] rd_issued;
    reg [11:0] rd_done;
    reg [7:0]  pass_base;    // 每轮基址(<<16),轮询 bank
    reg        req_outstanding; // 已发 req,等 DUT 用 busy 应答后才允许再发
                               // (消除 busy 信号 1 拍延迟导致的重复发送)

    // LFSR-16: x^16 + x^14 + x^13 + x^11 + 1
    function [15:0] lfsr_next;
        input [15:0] v;
        begin
            lfsr_next = {v[14:0], v[15] ^ v[13] ^ v[12] ^ v[10]};
        end
    endfunction

    wire [23:0] waddr = {pass_base, 4'h0, idx}; // {8位基址, 4'b0, 12位索引}
    // bank = waddr[23:22] = pass_base[7:6],随轮次轮询

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_WAIT;
            wr_req     <= 1'b0;
            rd_req     <= 1'b0;
            wr_be      <= 2'b11;
            idx        <= 12'd0;
            lfsr       <= LFSR_SEED;
            lfsr_exp   <= LFSR_SEED;
            rd_issued  <= 12'd0;
            rd_done    <= 12'd0;
            pass_base       <= 8'd0;
            test_run        <= 1'b0;
            err_sticky      <= 1'b0;
            pass_cnt        <= 16'd0;
            req_outstanding <= 1'b0;
        end else begin
            wr_req <= 1'b0;
            rd_req <= 1'b0;

            // DUT 接受 req 后 busy 拉高,见到 busy 高才清除,防止连发
            if (busy)
                req_outstanding <= 1'b0;

            case (state)
                S_WAIT: begin
                    if (init_done) begin
                        state <= S_WRITE;
                    end
                end

                S_WRITE: begin
                    if (!busy && !req_outstanding) begin
                        wr_req          <= 1'b1;
                        wr_addr         <= waddr;
                        wr_data         <= lfsr;
                        lfsr            <= lfsr_next(lfsr);
                        req_outstanding <= 1'b1;
                        if (idx == TEST_WORDS - 1) begin
                            idx       <= 12'd0;
                            lfsr_exp  <= LFSR_SEED;
                            rd_issued <= 12'd0;
                            rd_done   <= 12'd0;
                            state     <= S_READ;
                        end else begin
                            idx <= idx + 1'b1;
                        end
                    end
                end

                S_READ: begin
                    if (!busy && !req_outstanding && (rd_issued < TEST_WORDS)) begin
                        rd_req          <= 1'b1;
                        rd_addr         <= {pass_base, 4'h0, rd_issued};
                        rd_issued       <= rd_issued + 1'b1;
                        req_outstanding <= 1'b1;
                    end
                    if (rd_valid) begin
                        if (rd_data !== lfsr_exp)
                            err_sticky <= 1'b1;
                        lfsr_exp <= lfsr_next(lfsr_exp);
                        rd_done  <= rd_done + 1'b1;
                        if (rd_done == TEST_WORDS - 1) begin
                            // 本轮完成
                            pass_cnt  <= pass_cnt + 1'b1;
                            test_run  <= ~test_run;
                            pass_base <= pass_base + 8'd1;
                            lfsr      <= LFSR_SEED;
                            idx       <= 12'd0;
                            state     <= S_WRITE;
                        end
                    end
                end

                default: state <= S_WAIT;
            endcase
        end
    end

endmodule
