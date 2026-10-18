//==============================================================================
// Module Name:  sdram_uart_monitor
// Description:  SDRAM 控制器 UART 串口监控与状态汇报模块
//               参考自 https://github.com/conleee43-arch/lha6958h-pro 串口架构
//               1. 上电约 10ms 自动打印开机 Banner 信息
//               2. 捕获 SDRAM 初始化成功信号并打印提示
//               3. 每 1 秒定时上报一次读写测试轮数 (pass_cnt) 与错误状态 (err_sticky)
//               4. 标准 115200bps (100MHz 时钟下 868 分频，误差仅 0.006%)
// Standard:     Verilog-2001
//==============================================================================

`timescale 1ns / 1ps

module sdram_uart_monitor #(
    parameter integer CLK_FREQ = 100_000_000, // 控制器时钟 100MHz
    parameter integer UART_BPS = 115_200      // 默认波特率 115200
)(
    input  wire        clk,            // 100MHz 系统时钟 (sys_clk)
    input  wire        rst_n,          // 同步复位 (低有效)

    // SDRAM 控制器与自检状态信号
    input  wire        init_done,      // SDRAM 初始化完成
    input  wire        test_run,       // 每完成一轮读写自检翻转一次
    input  wire        err_sticky,     // 粘滞错误指示 (1=有错误)
    input  wire [15:0] pass_cnt,       // 完成的测试轮数 (每轮 4096 字)

    // 物理 UART 发送引脚
    output wire        uart_txd
);

    // 16 进制数转 ASCII
    function [7:0] hex2ascii;
        input [3:0] nibble;
        begin
            if (nibble < 4'd10)
                hex2ascii = 8'h30 + {4'd0, nibble};
            else
                hex2ascii = 8'h41 + {4'd0, nibble - 4'd10};
        end
    endfunction

    //--------------------------------------------------------------------------
    // 例化底层 uart_send 模块
    //--------------------------------------------------------------------------
    reg        uart_en;
    reg  [7:0] uart_din;
    wire       uart_tx_busy;

    uart_send #(
        .CLK_FREQ (CLK_FREQ),
        .UART_BPS (UART_BPS)
    ) u_uart_send (
        .sys_clk      (clk),
        .sys_rst_n    (rst_n),
        .uart_en      (uart_en),
        .uart_din     (uart_din),
        .uart_tx_busy (uart_tx_busy),
        .uart_txd     (uart_txd)
    );

    // 检测单字节发送完成 (uart_tx_busy 下降沿)
    reg uart_busy_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            uart_busy_d <= 1'b0;
        else
            uart_busy_d <= uart_tx_busy;
    end
    wire uart_byte_done = uart_busy_d & (~uart_tx_busy);

    //--------------------------------------------------------------------------
    // 定时器与触发信号生成
    //--------------------------------------------------------------------------
    // 1. 上电 10ms 延时定时器 (100MHz 下 1,000,000 拍)
    localparam POR_CYCLES = CLK_FREQ / 100; // 10ms
    reg [23:0] por_cnt;
    reg        pulse_banner;

    // 2. 1 秒定时心跳定时器 (100MHz 下 100,000,000 拍)
    reg [27:0] sec_cnt;
    reg        pulse_report;

    // 3. init_done 边沿检测
    reg        init_done_d;
    reg        pulse_init;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            por_cnt      <= 24'd0;
            pulse_banner <= 1'b0;
            sec_cnt      <= 28'd0;
            pulse_report <= 1'b0;
            init_done_d  <= 1'b0;
            pulse_init   <= 1'b0;
        end else begin
            init_done_d  <= init_done;
            pulse_banner <= 1'b0;
            pulse_init   <= 1'b0;
            pulse_report <= 1'b0;

            // 开机 10ms 触发 Banner 脉冲
            if (por_cnt < POR_CYCLES) begin
                por_cnt <= por_cnt + 1'b1;
                if (por_cnt == POR_CYCLES - 1)
                    pulse_banner <= 1'b1;
            end

            // 捕获 init_done 上升沿脉冲
            if (init_done && !init_done_d) begin
                pulse_init <= 1'b1;
            end

            // 1 秒心跳脉冲产生
            if (init_done) begin
                if (sec_cnt < CLK_FREQ - 1) begin
                    sec_cnt <= sec_cnt + 1'b1;
                end else begin
                    sec_cnt      <= 28'd0;
                    pulse_report <= 1'b1;
                end
            end else begin
                sec_cnt <= 28'd0;
            end
        end
    end

    //--------------------------------------------------------------------------
    // 字符串数据源定义
    //--------------------------------------------------------------------------
    // Banner: 共 148 字符
    localparam BANNER_LEN = 8'd148;
    function [7:0] get_banner_char;
        input [7:0] idx;
        case (idx)
            8'd0:   get_banner_char = 8'h0D; // \r
            8'd1:   get_banner_char = 8'h0A; // \n
            8'd2:   get_banner_char = "=";
            8'd3:   get_banner_char = "=";
            8'd4:   get_banner_char = "=";
            8'd5:   get_banner_char = "=";
            8'd6:   get_banner_char = "=";
            8'd7:   get_banner_char = "=";
            8'd8:   get_banner_char = "=";
            8'd9:   get_banner_char = "=";
            8'd10:  get_banner_char = "=";
            8'd11:  get_banner_char = "=";
            8'd12:  get_banner_char = "=";
            8'd13:  get_banner_char = "=";
            8'd14:  get_banner_char = "=";
            8'd15:  get_banner_char = "=";
            8'd16:  get_banner_char = "=";
            8'd17:  get_banner_char = "=";
            8'd18:  get_banner_char = "=";
            8'd19:  get_banner_char = "=";
            8'd20:  get_banner_char = "=";
            8'd21:  get_banner_char = "=";
            8'd22:  get_banner_char = "=";
            8'd23:  get_banner_char = "=";
            8'd24:  get_banner_char = "=";
            8'd25:  get_banner_char = "=";
            8'd26:  get_banner_char = "=";
            8'd27:  get_banner_char = "=";
            8'd28:  get_banner_char = "=";
            8'd29:  get_banner_char = "=";
            8'd30:  get_banner_char = "=";
            8'd31:  get_banner_char = "=";
            8'd32:  get_banner_char = "=";
            8'd33:  get_banner_char = "=";
            8'd34:  get_banner_char = "=";
            8'd35:  get_banner_char = "=";
            8'd36:  get_banner_char = "=";
            8'd37:  get_banner_char = "=";
            8'd38:  get_banner_char = "=";
            8'd39:  get_banner_char = "=";
            8'd40:  get_banner_char = "=";
            8'd41:  get_banner_char = "=";
            8'd42:  get_banner_char = 8'h0D;
            8'd43:  get_banner_char = 8'h0A;
            // * EP4CE10 SDRAM Controller (100MHz)\r\n
            8'd44:  get_banner_char = "*";
            8'd45:  get_banner_char = " ";
            8'd46:  get_banner_char = "E";
            8'd47:  get_banner_char = "P";
            8'd48:  get_banner_char = "4";
            8'd49:  get_banner_char = "C";
            8'd50:  get_banner_char = "E";
            8'd51:  get_banner_char = "1";
            8'd52:  get_banner_char = "0";
            8'd53:  get_banner_char = " ";
            8'd54:  get_banner_char = "S";
            8'd55:  get_banner_char = "D";
            8'd56:  get_banner_char = "R";
            8'd57:  get_banner_char = "A";
            8'd58:  get_banner_char = "M";
            8'd59:  get_banner_char = " ";
            8'd60:  get_banner_char = "C";
            8'd61:  get_banner_char = "o";
            8'd62:  get_banner_char = "n";
            8'd63:  get_banner_char = "t";
            8'd64:  get_banner_char = "r";
            8'd65:  get_banner_char = "o";
            8'd66:  get_banner_char = "l";
            8'd67:  get_banner_char = "l";
            8'd68:  get_banner_char = "e";
            8'd69:  get_banner_char = "r";
            8'd70:  get_banner_char = " ";
            8'd71:  get_banner_char = "(";
            8'd72:  get_banner_char = "1";
            8'd73:  get_banner_char = "0";
            8'd74:  get_banner_char = "0";
            8'd75:  get_banner_char = "M";
            8'd76:  get_banner_char = "H";
            8'd77:  get_banner_char = "z";
            8'd78:  get_banner_char = ")";
            8'd79:  get_banner_char = 8'h0D;
            8'd80:  get_banner_char = 8'h0A;
            // * Winbond W9825G6KH-6 (256Mb)\r\n
            8'd81:  get_banner_char = "*";
            8'd82:  get_banner_char = " ";
            8'd83:  get_banner_char = "W";
            8'd84:  get_banner_char = "i";
            8'd85:  get_banner_char = "n";
            8'd86:  get_banner_char = "b";
            8'd87:  get_banner_char = "o";
            8'd88:  get_banner_char = "n";
            8'd89:  get_banner_char = "d";
            8'd90:  get_banner_char = " ";
            8'd91:  get_banner_char = "W";
            8'd92:  get_banner_char = "9";
            8'd93:  get_banner_char = "8";
            8'd94:  get_banner_char = "2";
            8'd95:  get_banner_char = "5";
            8'd96:  get_banner_char = "G";
            8'd97:  get_banner_char = "6";
            8'd98:  get_banner_char = "K";
            8'd99:  get_banner_char = "H";
            8'd100: get_banner_char = "-";
            8'd101: get_banner_char = "6";
            8'd102: get_banner_char = " ";
            8'd103: get_banner_char = "(";
            8'd104: get_banner_char = "2";
            8'd105: get_banner_char = "5";
            8'd106: get_banner_char = "6";
            8'd107: get_banner_char = "M";
            8'd108: get_banner_char = "b";
            8'd109: get_banner_char = ")";
            8'd110: get_banner_char = 8'h0D;
            8'd111: get_banner_char = 8'h0A;
            // =========================================\r\n
            8'd112: get_banner_char = "=";
            8'd113: get_banner_char = "=";
            8'd114: get_banner_char = "=";
            8'd115: get_banner_char = "=";
            8'd116: get_banner_char = "=";
            8'd117: get_banner_char = "=";
            8'd118: get_banner_char = "=";
            8'd119: get_banner_char = "=";
            8'd120: get_banner_char = "=";
            8'd121: get_banner_char = "=";
            8'd122: get_banner_char = "=";
            8'd123: get_banner_char = "=";
            8'd124: get_banner_char = "=";
            8'd125: get_banner_char = "=";
            8'd126: get_banner_char = "=";
            8'd127: get_banner_char = "=";
            8'd128: get_banner_char = "=";
            8'd129: get_banner_char = "=";
            8'd130: get_banner_char = "=";
            8'd131: get_banner_char = "=";
            8'd132: get_banner_char = "=";
            8'd133: get_banner_char = "=";
            8'd134: get_banner_char = "=";
            8'd135: get_banner_char = "=";
            8'd136: get_banner_char = "=";
            8'd137: get_banner_char = "=";
            8'd138: get_banner_char = "=";
            8'd139: get_banner_char = "=";
            8'd140: get_banner_char = "=";
            8'd141: get_banner_char = "=";
            8'd142: get_banner_char = "=";
            8'd143: get_banner_char = "=";
            8'd144: get_banner_char = "=";
            8'd145: get_banner_char = "=";
            8'd146: get_banner_char = 8'h0D;
            8'd147: get_banner_char = 8'h0A;
            default: get_banner_char = 8'h00;
        endcase
    endfunction

    // Init Done: 46 字符
    // "[INFO] SDRAM Init Done! Starting Self-Test...\r\n"
    localparam INIT_LEN = 8'd46;
    function [7:0] get_init_char;
        input [7:0] idx;
        case (idx)
            8'd0:  get_init_char = "[";
            8'd1:  get_init_char = "I";
            8'd2:  get_init_char = "N";
            8'd3:  get_init_char = "F";
            8'd4:  get_init_char = "O";
            8'd5:  get_init_char = "]";
            8'd6:  get_init_char = " ";
            8'd7:  get_init_char = "S";
            8'd8:  get_init_char = "D";
            8'd9:  get_init_char = "R";
            8'd10: get_init_char = "A";
            8'd11: get_init_char = "M";
            8'd12: get_init_char = " ";
            8'd13: get_init_char = "I";
            8'd14: get_init_char = "n";
            8'd15: get_init_char = "i";
            8'd16: get_init_char = "t";
            8'd17: get_init_char = " ";
            8'd18: get_init_char = "D";
            8'd19: get_init_char = "o";
            8'd20: get_init_char = "n";
            8'd21: get_init_char = "e";
            8'd22: get_init_char = "!";
            8'd23: get_init_char = " ";
            8'd24: get_init_char = "S";
            8'd25: get_init_char = "t";
            8'd26: get_init_char = "a";
            8'd27: get_init_char = "r";
            8'd28: get_init_char = "t";
            8'd29: get_init_char = "i";
            8'd30: get_init_char = "n";
            8'd31: get_init_char = "g";
            8'd32: get_init_char = " ";
            8'd33: get_init_char = "S";
            8'd34: get_init_char = "e";
            8'd35: get_init_char = "l";
            8'd36: get_init_char = "f";
            8'd37: get_init_char = "-";
            8'd38: get_init_char = "T";
            8'd39: get_init_char = "e";
            8'd40: get_init_char = "s";
            8'd41: get_init_char = "t";
            8'd42: get_init_char = ".";
            8'd43: get_init_char = ".";
            8'd44: get_init_char = 8'h0D;
            8'd45: get_init_char = 8'h0A;
            default: get_init_char = 8'h00;
        endcase
    endfunction

    // 报告信息:
    // 成功格式: "[PASS] Rounds: 0xXXXX | Errors: 0 | SDRAM OK!\r\n" (48 字符)
    // 错误格式: "[FAIL] Rounds: 0xXXXX | Errors: 1 | MISMATCH!\r\n" (48 字符)
    localparam REPORT_LEN = 8'd48;
    reg [15:0] lat_pass;
    reg        lat_err;

    function [7:0] get_report_char;
        input [7:0]  idx;
        input [15:0] pass;
        input        err;
        case (idx)
            8'd0:  get_report_char = "[";
            8'd1:  get_report_char = err ? "F" : "P";
            8'd2:  get_report_char = err ? "A" : "A";
            8'd3:  get_report_char = err ? "I" : "S";
            8'd4:  get_report_char = err ? "L" : "S";
            8'd5:  get_report_char = "]";
            8'd6:  get_report_char = " ";
            8'd7:  get_report_char = "R";
            8'd8:  get_report_char = "o";
            8'd9:  get_report_char = "u";
            8'd10: get_report_char = "n";
            8'd11: get_report_char = "d";
            8'd12: get_report_char = "s";
            8'd13: get_report_char = ":";
            8'd14: get_report_char = " ";
            8'd15: get_report_char = "0";
            8'd16: get_report_char = "x";
            // 4 位十六进制轮数 pass_cnt
            8'd17: get_report_char = hex2ascii(pass[15:12]);
            8'd18: get_report_char = hex2ascii(pass[11:8]);
            8'd19: get_report_char = hex2ascii(pass[7:4]);
            8'd20: get_report_char = hex2ascii(pass[3:0]);
            8'd21: get_report_char = " ";
            8'd22: get_report_char = "|";
            8'd23: get_report_char = " ";
            8'd24: get_report_char = "E";
            8'd25: get_report_char = "r";
            8'd26: get_report_char = "r";
            8'd27: get_report_char = "o";
            8'd28: get_report_char = "r";
            8'd29: get_report_char = "s";
            8'd30: get_report_char = ":";
            8'd31: get_report_char = " ";
            8'd32: get_report_char = err ? "1" : "0";
            8'd33: get_report_char = " ";
            8'd34: get_report_char = "|";
            8'd35: get_report_char = " ";
            // 后缀
            8'd36: get_report_char = err ? "M" : "S";
            8'd37: get_report_char = err ? "I" : "D";
            8'd38: get_report_char = err ? "S" : "R";
            8'd39: get_report_char = err ? "M" : "A";
            8'd40: get_report_char = err ? "A" : "M";
            8'd41: get_report_char = err ? "T" : " ";
            8'd42: get_report_char = err ? "C" : "O";
            8'd43: get_report_char = err ? "H" : "K";
            8'd44: get_report_char = "!";
            8'd45: get_report_char = " ";
            8'd46: get_report_char = 8'h0D;
            8'd47: get_report_char = 8'h0A;
            default: get_report_char = 8'h00;
        endcase
    endfunction

    //--------------------------------------------------------------------------
    // 发送调度主状态机
    //--------------------------------------------------------------------------
    localparam [2:0]
        S_IDLE   = 3'd0,
        S_BANNER = 3'd1,
        S_INIT   = 3'd2,
        S_REPORT = 3'd3,
        S_WAIT   = 3'd4;

    reg [2:0] state;
    reg [2:0] return_state;
    reg [7:0] char_idx;
    reg [7:0] char_max;
    reg       req_banner;
    reg       req_init;
    reg       req_report;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            return_state <= S_IDLE;
            char_idx     <= 8'd0;
            char_max     <= 8'd0;
            uart_en      <= 1'b0;
            uart_din     <= 8'd0;
            lat_pass     <= 16'd0;
            lat_err      <= 1'b0;
            req_banner   <= 1'b0;
            req_init     <= 1'b0;
            req_report   <= 1'b0;
        end else begin
            uart_en <= 1'b0;

            // 锁存外部脉冲请求
            if (pulse_banner) req_banner <= 1'b1;
            if (pulse_init)   req_init   <= 1'b1;
            if (pulse_report) req_report <= 1'b1;

            case (state)
                S_IDLE: begin
                    char_idx <= 8'd0;
                    if (req_banner) begin
                        req_banner   <= 1'b0;
                        char_max     <= BANNER_LEN;
                        state        <= S_BANNER;
                    end else if (req_init) begin
                        req_init     <= 1'b0;
                        char_max     <= INIT_LEN;
                        state        <= S_INIT;
                    end else if (req_report) begin
                        req_report   <= 1'b0;
                        char_max     <= REPORT_LEN;
                        lat_pass     <= pass_cnt;
                        lat_err      <= err_sticky;
                        state        <= S_REPORT;
                    end
                end

                S_BANNER: begin
                    if (!uart_tx_busy) begin
                        uart_en      <= 1'b1;
                        uart_din     <= get_banner_char(char_idx);
                        return_state <= S_BANNER;
                        state        <= S_WAIT;
                    end
                end

                S_INIT: begin
                    if (!uart_tx_busy) begin
                        uart_en      <= 1'b1;
                        uart_din     <= get_init_char(char_idx);
                        return_state <= S_INIT;
                        state        <= S_WAIT;
                    end
                end

                S_REPORT: begin
                    if (!uart_tx_busy) begin
                        uart_en      <= 1'b1;
                        uart_din     <= get_report_char(char_idx, lat_pass, lat_err);
                        return_state <= S_REPORT;
                        state        <= S_WAIT;
                    end
                end

                S_WAIT: begin
                    if (uart_byte_done) begin
                        if (char_idx < char_max - 1) begin
                            char_idx <= char_idx + 1'b1;
                            state    <= return_state;
                        end else begin
                            state    <= S_IDLE;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
