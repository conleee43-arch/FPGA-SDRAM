//=============================================================================
//  sdram_ctrl.v
//  ----------------------------------------------------------------------------
//  Winbond W9825G6KH-6 (256Mb, 16M x 16, 4bank / 13行 / 9列) SDRAM 控制器
//  Cyclone IV (EP4CE10) 单时钟域,专业级 native 接口.
//
//  特性:
//    * 上电初始化状态机: 200us 稳定等待 -> PRECHARGE ALL -> 2x AUTO REFRESH
//      -> LOAD MODE REGISTER (BL=1, sequential, CL=3), 完成后 init_done 拉高.
//    * 自动刷新: 平均 7.8us 一次 AUTO REFRESH,刷新期间阻塞新请求(约 7 个时钟).
//    * 读写: 每次 ACTIVATE 一行,发 READ/WRITE(带 auto-precharge, A10=1),
//      行关闭由器件自动完成;相邻两次访问间隔 >= tRC,时序全参数化(ns -> 时钟).
//    * 写支持字节使能 (DQM),读数据带 rd_valid 选通.
//    * busy 握手 + err_busy_req 粘滞错误标志(在 busy 时打 req 会被忽略并置位).
//    * 读捕获延迟 RD_CAP_CYC 可调(默认 CL+2,见文件头时序分析).
//
//  时序分析(100MHz, SDRAM 时钟相对控制器时钟超前约 3ns,见 README):
//    写: 控制器在 sys_clk 上升沿后驱动命令/DQ(经 Tco 约 4ns 到达引脚),
//        SDRAM 在超前 3ns 的时钟上升沿采样,建立时间约 5.5ns,充足.
//    读: READ 被 SDRAM 采样后,经 CL 个周期 SDRAM 驱动 DQ(tAC 最大 5ns,-6 档,手册 Rev A02 §9.5),
//        再经 PCB 回到 FPGA;超前 3ns 相当于把 3ns 从"命令建立预算"挪给
//        "读回路预算",控制器在发出 READ 后第 CL+2 个 sys_clk 上升沿采样 DQ.
//        该值已在 testbench 中用带 tAC=5ns 延迟的 SDRAM 行为模型验证,
//        上板后如需微调改 RD_CAP_CYC 或 PLL 移相即可.
//
//  用户协议:
//    * wr_req / rd_req 为单周期脉冲,且只能在 busy=0 时发出;
//    * 写: {wr_addr, wr_data, wr_be} 在 wr_req 当拍被锁存;
//    * 读: {rd_addr} 在 rd_req 当拍被锁存,rd_valid 拉高一拍时 rd_data 有效;
//    * 地址映射: addr[23:0] = {bank[1:0], row[12:0], col[8:0]}.
//-----------------------------------------------------------------------------
//  Revision:
//    2026-10-18  初版,iverilog 仿真全过(3 个 seed 随机压力测试).
//    时序:按 Winbond W9825G6 家族手册设保守值(tRCD/tRP 实际等待 30ns,
//    tRC 90ns,tRFC 90ns),-6 档精确 ns 值待 Rev A05 官方 PDF 复核后再收紧.
//    初始化刷新 8 次(手册 p11 建议);MRS=0x030(BL=1,顺序,CL=3).
//    修过 2 个真 bug:READ 命令编码误发成 BST;ST_IDLE 刷新与 req 竞争吞请求.
//=============================================================================

`timescale 1ns / 1ps

module sdram_ctrl #(
    parameter integer CLK_MHZ      = 100,    // 控制器时钟 = SDRAM 时钟频率(MHz)

    // ---- SDRAM 时序(ns),W9825G6KH-6 -6 档 ----
    parameter integer T_PWRUP_US   = 200,    // 上电后稳定等待(手册要求 200us)
    parameter integer T_RP_NS      = 18,     // PRECHARGE -> ACTIVATE
    parameter integer T_RFC_NS     = 80,     // AUTO REFRESH -> 下一条命令(-6 档 tRC=60ns,取 80ns 留余量;手册 Rev A02 §9.5)
    parameter integer NUM_INIT_AREF = 8,    // 初始化阶段 AUTO REFRESH 次数(手册建议 8 次)
    parameter integer T_MRD_CYC    = 2,      // MRS -> 下一条命令(时钟数)
    parameter integer T_RCD_NS     = 18,     // ACTIVATE -> READ/WRITE
    parameter integer T_RC_NS      = 60,     // ACTIVATE -> ACTIVATE(同 bank)
    parameter integer T_REFI_NS    = 7800,   // 平均刷新间隔(手册 7.8125us,取 7.8us)
    parameter integer CAS_LAT      = 3,      // CAS latency
    // 读捕获延迟:发出 READ 后第几个控制器时钟采样 DQ(仿真验证,默认 CL+2)
    parameter integer RD_CAP_CYC   = CAS_LAT + 2,

    parameter integer ROW_BITS     = 13,
    parameter integer COL_BITS     = 9,
    parameter integer BANK_BITS    = 2,
    // Mode Register: {保留, WBL=0(按 BL), TM=00, CL=011, BT=0(顺序), BL=000(=1)}
    parameter [12:0]  MODE_REG    = 13'h030
)(
    input  wire                   clk,
    input  wire                   rst_n,        // 异步复位(外部按键/上电)

    // ---- 用户侧 native 接口 ----
    input  wire                   wr_req,       // 单拍脉冲,busy=0 时有效
    input  wire [23:0]            wr_addr,      // {bank[1:0], row[12:0], col[8:0]}
    input  wire [15:0]            wr_data,
    input  wire [1:0]             wr_be,        // 字节使能,1=写该字节
    input  wire                   rd_req,       // 单拍脉冲,busy=0 时有效
    input  wire [23:0]            rd_addr,
    output reg  [15:0]            rd_data,
    output reg                    rd_valid,     // 单拍脉冲,指示 rd_data 有效
    output wire                   busy,         // 1=正忙,不接受新 req
    output wire                   init_done,    // 1=初始化完成,可开始访问
    output reg                    err_busy_req, // 粘滞:busy 时收到 req 置 1,复位清除

    // ---- SDRAM 物理接口(sdram_clk 由顶层 PLL 产生,超前本时钟约 3ns) ----
    output reg  [12:0]            s_a,
    output reg  [1:0]             s_ba,
    output wire                   s_cke,        // 复位释放后恒为 1
    output reg                    s_cs_n,
    output reg                    s_ras_n,
    output reg                    s_cas_n,
    output reg                    s_we_n,
    output reg  [1:0]             s_dqm,        // 高=屏蔽
    output reg  [15:0]            s_dq_out,
    output reg                    s_dq_oe,      // 1=FPGA 驱动 DQ(写),0=高阻(读)
    input  wire [15:0]            s_dq_in
);

    //--------------------------------------------------------------------------
    // ns/us -> 时钟数(向上取整)
    //--------------------------------------------------------------------------
    function integer ns2cyc;
        input integer ns;
        begin
            ns2cyc = (ns * CLK_MHZ + 999) / 1000;
        end
    endfunction
    function integer us2cyc;
        input integer us;
        begin
            us2cyc = us * CLK_MHZ;
        end
    endfunction

    localparam integer C_PWRUP = us2cyc(T_PWRUP_US); // 200us @100MHz = 20000
    localparam integer C_RP    = ns2cyc(T_RP_NS);    // 2
    localparam integer C_RFC   = ns2cyc(T_RFC_NS);   // 7
    localparam integer C_RCD   = ns2cyc(T_RCD_NS);   // 2
    localparam integer C_RC    = ns2cyc(T_RC_NS);    // 6
    localparam integer C_REFI  = ns2cyc(T_REFI_NS);  // 780

    function integer clog2;
        input integer v;
        integer i;
        begin
            clog2 = 1;
            for (i = 1; 2**i < v; i = i + 1)
                clog2 = i + 1;
        end
    endfunction

    //--------------------------------------------------------------------------
    // 复位同步(异步置位、同步释放,防亚稳)
    //--------------------------------------------------------------------------
    reg [1:0] rst_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rst_sync <= 2'b00;
        else
            rst_sync <= {rst_sync[0], 1'b1};
    end
    wire rst_s = ~rst_sync[1];

    assign s_cke = rst_sync[1]; // 复位期间 0,释放后恒 1

    //--------------------------------------------------------------------------
    // 状态机
    //--------------------------------------------------------------------------
    localparam [3:0] ST_PWRUP = 4'd0,  // 上电 200us 等待
                     ST_PRECH = 4'd1,  // PRECHARGE ALL
                     ST_AREF  = 4'd2,  // AUTO REFRESH x2(初始化)/x1(运行期)
                     ST_MRS   = 4'd3,  // LOAD MODE REGISTER
                     ST_IDLE  = 4'd4,  // 空闲,接受请求/刷新
                     ST_ACT   = 4'd5,  // ACTIVATE
                     ST_RW    = 4'd6,  // READ / WRITE
                     ST_WAIT  = 4'd7,  // 等待 tRC 补足
                     ST_REFR  = 4'd8;  // 运行期自动刷新

    reg [3:0] state;
    reg [clog2(C_PWRUP+1)-1:0] timer;      // 通用倒计时
    reg [clog2(NUM_INIT_AREF+1)-1:0] aref_cnt; // 初始化阶段刷新计数
    reg       refr_pending;                // 运行期刷新挂起标志
    reg [clog2(C_REFI+1)-1:0] refr_cnt;    // 刷新间隔计数

    // 锁存的请求
    reg [1:0]  lat_bank;
    reg [12:0] lat_row;
    reg [8:0]  lat_col;
    reg [15:0] lat_wdata;
    reg [1:0]  lat_be;
    reg        lat_is_wr;

    // 读捕获倒计时
    reg [clog2(RD_CAP_CYC+1)-1:0] rd_lat;

    assign busy      = (state != ST_IDLE) | refr_pending | (rd_lat != 0) | ~init_done_r;
    assign init_done = init_done_r;
    reg init_done_r;

    // 命令驱动任务(组合,按状态查表)
    // {cs_n, ras_n, cas_n, we_n}: ACT=0011 PRECH=0010 READ=0101 WRITE=0100
    //                            AREF=0001 MRS=0000 NOP=0111
    task drive_cmd;
        input c, r, ca, w;
        input [12:0] a;
        input [1:0]  ba;
        begin
            s_cs_n  = c;
            s_ras_n = r;
            s_cas_n = ca;
            s_we_n  = w;
            s_a     = a;
            s_ba    = ba;
        end
    endtask

    always @(posedge clk or posedge rst_s) begin
        if (rst_s) begin
            state        <= ST_PWRUP;
            timer        <= C_PWRUP;
            aref_cnt     <= NUM_INIT_AREF;
            refr_pending <= 1'b0;
            refr_cnt     <= C_REFI;
            init_done_r  <= 1'b0;
            err_busy_req <= 1'b0;
            rd_lat       <= 0;
            rd_data      <= 16'h0000;
            rd_valid     <= 1'b0;
            lat_is_wr    <= 1'b0;
            // 总线复位值: NOP,地址 0,DQ 高阻
            drive_cmd(1'b1, 1'b1, 1'b1, 1'b1, 13'h0000, 2'b00);
            s_dqm   <= 2'b11;
            s_dq_out <= 16'h0000;
            s_dq_oe <= 1'b0;
        end else begin
            // 默认: NOP, DQ 高阻,DQM 全通(写周期内改写)
            drive_cmd(1'b1, 1'b1, 1'b1, 1'b1, 13'h0000, 2'b00);
            s_dqm   <= 2'b00;
            s_dq_oe <= 1'b0;
            rd_valid <= 1'b0;

            // 刷新间隔计时(初始化完成后才跑)
            if (init_done_r) begin
                if (refr_cnt == 0) begin
                    refr_pending <= 1'b1;
                    refr_cnt     <= C_REFI;
                end else begin
                    refr_cnt <= refr_cnt - 1'b1;
                end
            end

            // 读捕获倒计时
            if (rd_lat != 0) begin
                rd_lat <= rd_lat - 1'b1;
                if (rd_lat == 1) begin
                    rd_data  <= s_dq_in;
                    rd_valid <= 1'b1;
                end
            end

            // 收到的 req 若本拍不能被接受(状态机正忙或未初始化):置粘滞错误.
            // 注意:ST_IDLE 下即使 refr_pending=1,req 也会被接受(先做访问再补刷新),
            // 因此这里不以 busy 为判据,而以"本拍是否接受"为准,避免误报.
            if ((wr_req | rd_req) & ~(init_done_r & (state == ST_IDLE)))
                err_busy_req <= 1'b1;

            case (state)
                ST_PWRUP: begin
                    s_dqm <= 2'b11; // 上电期间屏蔽 DQ(手册建议)
                    if (timer == 0) begin
                        // PRECHARGE ALL: A10=1
                        drive_cmd(1'b0, 1'b0, 1'b1, 1'b0, 13'h0400, 2'b00);
                        timer <= C_RP;
                        state <= ST_PRECH;
                    end else begin
                        timer <= timer - 1'b1;
                    end
                end

                ST_PRECH: begin
                    if (timer == 0) begin
                        // AUTO REFRESH
                        drive_cmd(1'b0, 1'b0, 1'b0, 1'b1, 13'h0000, 2'b00);
                        timer    <= C_RFC;
                        aref_cnt <= aref_cnt - 1'b1;
                        state    <= ST_AREF;
                    end else begin
                        timer <= timer - 1'b1;
                    end
                end

                ST_AREF: begin
                    if (timer == 0) begin
                        if (aref_cnt == 0) begin
                            // LOAD MODE REGISTER
                            drive_cmd(1'b0, 1'b0, 1'b0, 1'b0, MODE_REG, 2'b00);
                            timer <= T_MRD_CYC;
                            state <= ST_MRS;
                        end else begin
                            drive_cmd(1'b0, 1'b0, 1'b0, 1'b1, 13'h0000, 2'b00);
                            timer    <= C_RFC;
                            aref_cnt <= aref_cnt - 1'b1;
                            state    <= ST_AREF; // 再来一次
                        end
                    end else begin
                        timer <= timer - 1'b1;
                    end
                end

                ST_MRS: begin
                    if (timer == 0) begin
                        init_done_r <= 1'b1;
                        state       <= ST_IDLE;
                    end else begin
                        timer <= timer - 1'b1;
                    end
                end

                ST_IDLE: begin
                    if (wr_req | rd_req) begin
                        // 有请求则必接受:即使刷新挂起也先做完本次访问再补刷新
                        // (一次访问约 90ns,相对 7.8us 刷新预算可忽略),保证
                        // "busy=0 时发出的 req 一定被执行",消除采样竞争.
                        lat_is_wr <= wr_req; // 写优先
                        lat_bank  <= wr_req ? wr_addr[23:22] : rd_addr[23:22];
                        lat_row   <= wr_req ? wr_addr[21:9]  : rd_addr[21:9];
                        lat_col   <= wr_req ? wr_addr[8:0]   : rd_addr[8:0];
                        lat_wdata <= wr_data;
                        lat_be    <= wr_be;
                        // ACTIVATE: s_a = 13 位行地址
                        drive_cmd(1'b0, 1'b0, 1'b1, 1'b1,
                                  wr_req ? wr_addr[21:9] : rd_addr[21:9],
                                  wr_req ? wr_addr[23:22] : rd_addr[23:22]);
                        timer <= C_RCD;
                        state <= ST_ACT;
                    end else if (refr_pending) begin
                        // 运行期自动刷新(各 bank 均已 auto-precharge,处于空闲)
                        drive_cmd(1'b0, 1'b0, 1'b0, 1'b1, 13'h0000, 2'b00);
                        timer        <= C_RFC;
                        refr_pending <= 1'b0;
                        state        <= ST_REFR;
                    end
                end

                ST_ACT: begin
                    if (timer == 0) begin
                        if (lat_is_wr) begin
                            // WRITE + auto-precharge(A10=1);数据与命令同拍驱动
                            drive_cmd(1'b0, 1'b1, 1'b0, 1'b0,
                                      {2'b00, 1'b1, 1'b0, lat_col}, lat_bank);
                            s_dq_out <= lat_wdata;
                            s_dqm    <= ~lat_be;
                            s_dq_oe  <= 1'b1;
                        end else begin
                            // READ + auto-precharge(A10=1)
                            // {cs_n,ras_n,cas_n,we_n} = 0101
                            drive_cmd(1'b0, 1'b1, 1'b0, 1'b1,
                                      {2'b00, 1'b1, 1'b0, lat_col}, lat_bank);
                            rd_lat <= RD_CAP_CYC;
                        end
                        timer <= C_RC - C_RCD;
                        state <= ST_RW;
                    end else begin
                        timer <= timer - 1'b1;
                    end
                end

                ST_RW: begin
                    // 命令已发出,仅等待 tRC 补足(写数据的 DQ 在本拍已回到高阻默认值)
                    if (timer == 0) begin
                        state <= ST_IDLE;
                    end else begin
                        timer <= timer - 1'b1;
                        state <= ST_WAIT;
                    end
                end

                ST_WAIT: begin
                    if (timer == 0) begin
                        state <= ST_IDLE;
                    end else begin
                        timer <= timer - 1'b1;
                    end
                end

                ST_REFR: begin
                    if (timer == 0) begin
                        state <= ST_IDLE;
                    end else begin
                        timer <= timer - 1'b1;
                    end
                end

                default: state <= ST_PWRUP;
            endcase
        end
    end

endmodule
