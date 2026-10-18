//=============================================================================
//  sdram_top.v -- EP4CE10 + W9825G6KH-6 板级顶层
//  ----------------------------------------------------------------------------
//  50MHz 板载晶振(E1) -> PLL -> 100MHz 系统时钟 + 100MHz SDRAM 时钟(超前 3ns).
//  上电后 sdram_ctrl 自动初始化 SDRAM,随后 sdram_selftest 做连续读写自检.
//  LED 指示:LED0(A4)常亮=初始化完成;LED1(B5)亮=粘滞错误.
//
//  注意:
//   * 已包含 rtl/sdram_pll.v (ALTPLL: 50MHz -> 100MHz 系统时钟 + 100MHz -3ns SDRAM 时钟).
//   * 板级引脚已按正点原子 E10 原理图(E10_________V1.1.pdf)确认,见 sdram.qsf.

//-----------------------------------------------------------------------------
//  Revision:
//    2026-10-18  初版.
//=============================================================================

`timescale 1ns / 1ps

module sdram_top (
    input  wire        clk_50m,     // E1:板载 50MHz 晶振(原理图确认)
    input  wire        rst_n,       // M1:RESET 按键,低有效(10K 上拉)

    // ---- SDRAM W9825G6KH-6(网络名与原理图一致,小写) ----
    output wire        sdram_clk,   // B14(PLL2 CLKOUTp 专用脚)
    output wire        sdram_cke,   // F16
    output wire        sdram_cs_n,  // K10(BANK4)
    output wire        sdram_ras_n, // K11
    output wire        sdram_cas_n, // J12
    output wire        sdram_we_n,  // J13
    output wire [1:0]  sdram_dqm,   // {DQM1=G15, DQM0=J14}
    output wire [12:0] sdram_a,    // A12=F15..A0=F11,见 qsf
    output wire [1:0]  sdram_ba,   // {BA1=F13, BA0=G11}
    inout  wire [15:0] sdram_dq,   // D15..D0,见 qsf

    // ---- 状态 LED(板上只有 2 个,高电平亮) ----
    output wire        led_init_done, // A4:LED0,初始化完成常亮
    output wire        led_err,       // B5:LED1,粘滞错误(亮=有问题)

    // ---- UART 串口(与 lha6958h-pro 硬件完全一致) ----
    output wire        uart_txd       // A13:UART 发送端口 (默认 115200bps)
);

    wire sys_clk;
    wire pll_locked;
    wire ctrl_init_done;
    wire ctrl_busy;
    wire ctrl_err;

    // 复位:按键与 PLL locked 相与(同步释放由 sdram_ctrl 内部完成)
    wire rst_n_sync = rst_n & pll_locked;

    sdram_pll u_pll (
        .inclk0    (clk_50m),
        .areset    (~rst_n),
        .c0        (sys_clk),
        .c1        (sdram_clk),
        .locked    (pll_locked)
    );

    // 控制器内部信号
    wire [12:0] c_a;
    wire [1:0]  c_ba;
    wire        c_cs_n;
    wire [15:0] c_dq_out;
    wire        c_dq_oe;
    wire        c_rd_valid;
    wire [15:0] c_rd_data;

    // 自检模块接口
    wire        t_wr_req, t_rd_req;
    wire [23:0] t_wr_addr, t_rd_addr;
    wire [15:0] t_wr_data;
    wire [1:0]  t_wr_be;
    wire        t_run, t_err;
    wire [15:0] t_pass;

    sdram_ctrl #(
        .CLK_MHZ (100)
    ) u_ctrl (
        .clk        (sys_clk),
        .rst_n      (rst_n_sync),
        .wr_req     (t_wr_req),
        .wr_addr    (t_wr_addr),
        .wr_data    (t_wr_data),
        .wr_be      (t_wr_be),
        .rd_req     (t_rd_req),
        .rd_addr    (t_rd_addr),
        .rd_data    (c_rd_data),
        .rd_valid   (c_rd_valid),
        .busy       (ctrl_busy),
        .init_done  (ctrl_init_done),
        .err_busy_req (ctrl_err),
        .s_a        (c_a),
        .s_ba       (c_ba),
        .s_cke      (sdram_cke),
        .s_cs_n     (c_cs_n),
        .s_ras_n    (sdram_ras_n),
        .s_cas_n    (sdram_cas_n),
        .s_we_n     (sdram_we_n),
        .s_dqm      (sdram_dqm),
        .s_dq_out   (c_dq_out),
        .s_dq_oe    (c_dq_oe),
        .s_dq_in    (sdram_dq)
    );

    // DQ 三态
    assign sdram_dq   = c_dq_oe ? c_dq_out : 16'hzzzz;
    assign sdram_a    = c_a;
    assign sdram_ba   = c_ba;
    assign sdram_cs_n = c_cs_n;

    sdram_selftest #(
        .TEST_WORDS (4096)
    ) u_selftest (
        .clk        (sys_clk),
        .rst_n      (rst_n_sync),
        .init_done  (ctrl_init_done),
        .wr_req     (t_wr_req),
        .wr_addr    (t_wr_addr),
        .wr_data    (t_wr_data),
        .wr_be      (t_wr_be),
        .rd_req     (t_rd_req),
        .rd_addr    (t_rd_addr),
        .rd_data    (c_rd_data),
        .rd_valid   (c_rd_valid),
        .busy       (ctrl_busy),
        .test_run   (t_run),
        .err_sticky (t_err),
        .pass_cnt   (t_pass)
    );

    assign led_init_done = ctrl_init_done;
    assign led_err       = t_err | ctrl_err;

    // UART 监控与状态输出 (参考 lha6958h-pro 架构)
    sdram_uart_monitor #(
        .CLK_FREQ (100_000_000),
        .UART_BPS (115_200)
    ) u_uart_monitor (
        .clk        (sys_clk),
        .rst_n      (rst_n_sync),
        .init_done  (ctrl_init_done),
        .test_run   (t_run),
        .err_sticky (t_err | ctrl_err),
        .pass_cnt   (t_pass),
        .uart_txd   (uart_txd)
    );

endmodule
