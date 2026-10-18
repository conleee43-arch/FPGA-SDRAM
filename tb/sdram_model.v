//=============================================================================
//  sdram_model.v -- W9825G6KH-6 (256Mb, 16Mx16) 行为级模型(用于仿真验证)
//
//  不是时序精确模型,而是"协议检查器 + 功能存储器":
//   * 严格检查上电初始化序列: PRECHARGE ALL -> AUTO REFRESH -> AUTO REFRESH
//     -> LOAD MODE REGISTER(期望值 0x030,BL=1/CL=3),顺序错则报 ERROR.
//   * 检查 tRCD(ACT->READ/WRITE)、tRC(ACT->ACT)、刷新时 bank 必须空闲等.
//   * READ: CL 个 sdram_clk 后驱动 DQ,经 TAC(ns) 后有效,BL=1 只驱动一拍.
//   * WRITE: 数据与 WRITE 命令同拍采样(标准 SDR 行为),DQM 掩码延迟为 0.
//   * READ 的 DQM 掩码延迟 2 拍(实现,以备 DUT 使用;本控制器读时 DQM=0).
//   * 记录每次 AUTO REFRESH 的时刻,供 testbench 检查刷新间隔.
//=============================================================================

`timescale 1ns / 1ps

module sdram_model #(
    parameter ROW_BITS = 13,
    parameter COL_BITS = 9,
    parameter BANKS    = 4,
    parameter CL       = 3,
    parameter TAC      = 5,     // DQ 输出相对发射沿的延迟(ns),取手册最大值附近
    parameter TCK      = 10,    // sdram_clk 周期(ns)
    parameter T_RCD_C  = 2,     // 时序检查用(时钟数)
    parameter T_RC_C   = 6,
    parameter NUM_INIT_AREF = 8, // 初始化阶段期望的 AUTO REFRESH 次数
    parameter MODE_EXPECT = 13'h030
)(
    input  wire        clk,     // sdram_clk(超前相)
    input  wire        cke,
    input  wire        cs_n,
    input  wire        ras_n,
    input  wire        cas_n,
    input  wire        we_n,
    input  wire [12:0] a,
    input  wire [1:0]  ba,
    input  wire [1:0]  dqm,
    inout  wire [15:0] dq
);

    // 命令解码 {ras_n, cas_n, we_n} (cs_n=0 时)
    // {ras_n, cas_n, we_n}: PRECHARGE=010, AUTO REFRESH=001(注意别写反)
    localparam [2:0] CMD_ACT  = 3'b011,
                     CMD_PRE  = 3'b010,
                     CMD_READ = 3'b101,
                     CMD_WRIT = 3'b100,
                     CMD_AREF = 3'b001,
                     CMD_MRS  = 3'b000,
                     CMD_NOP  = 3'b111;

    reg [15:0] mem [0:(1<<24)-1]; // 16M x 16 = 256Mb

    integer active_row [0:BANKS-1];   // -1 = 已预充电
    integer last_act   [0:BANKS-1];   // 上次 ACT 的 edge_cnt
    integer prech_at   [0:BANKS-1];   // auto-precharge 完成时刻(edge_cnt)
    integer i;

    integer edge_cnt;
    integer init_phase; // 0:等PRECH 1:等AREF x N 3:等MRS 4:正常
    integer init_aref_cnt;
    integer err_cnt;
    integer aref_cnt;
    integer aref_last_t;   // 上次刷新时刻(ns)
    integer aref_max_gap;  // 最大刷新间隔(ns)

    // 读流水线:每级 {valid, data, byte_masked}
    reg               rd_vld [0:CL-1];
    reg [15:0]        rd_dat [0:CL-1];
    reg [1:0]         rd_dqm_d [0:1]; // DQM 延迟 2 拍(读掩码用)
    reg [15:0]        dq_drv;
    reg               dq_en;
    reg [1:0]         dq_hold; // 读数据驱动保持计数(BL=1 约保持 2 拍)

    assign dq = dq_en ? dq_drv : 16'hzzzz;

    task protocol_error;
        input [8*128-1:0] msg;
        begin
            err_cnt = err_cnt + 1;
            $display("ERROR @%0t ns [sdram_model]: %0s", $time, msg);
        end
    endtask

    initial begin
        for (i = 0; i < BANKS; i = i + 1) begin
            active_row[i] = -1;
            last_act[i]   = -1000;
            prech_at[i]   = -1;
        end
        for (i = 0; i < CL; i = i + 1) begin
            rd_vld[i] = 1'b0;
            rd_dat[i] = 16'h0000;
        end
        rd_dqm_d[0] = 2'b00; rd_dqm_d[1] = 2'b00;
        edge_cnt = 0; init_phase = 0; init_aref_cnt = 0; err_cnt = 0;
        aref_cnt = 0; aref_last_t = 0; aref_max_gap = 0;
        dq_drv = 16'h0000; dq_en = 1'b0; dq_hold = 0;
    end

    // DQM 读掩码延迟链(每拍采样)
    always @(posedge clk) begin
        rd_dqm_d[0] <= dqm;
        rd_dqm_d[1] <= rd_dqm_d[0];
    end

    always @(posedge clk) begin
        integer b;
        integer full_addr;
        if (!cke) begin
            // CKE=0: 时钟挂起,所有命令视为 NOP
        end else begin
            edge_cnt <= edge_cnt + 1;

            // auto-precharge 到期 -> bank 回到空闲
            for (b = 0; b < BANKS; b = b + 1)
                if (prech_at[b] == edge_cnt)
                    active_row[b] = -1;

            // 读流水线移位
            for (i = CL-1; i > 0; i = i - 1) begin
                rd_vld[i] <= rd_vld[i-1];
                rd_dat[i] <= rd_dat[i-1];
            end
            rd_vld[0] <= 1'b0;

            // 读数据发射(CL 拍后),保持约 2 拍(真芯片 tHZ 行为)
            if (rd_vld[CL-1]) begin
                dq_drv  <= #(TAC) rd_dat_masked(rd_dat[CL-1], rd_dqm_d[1]);
                dq_hold <= 2'd2;
                dq_en   <= #(TAC) 1'b1;
            end else begin
                if (dq_hold != 0) dq_hold <= dq_hold - 1'b1;
                if (dq_hold == 1) dq_en <= #(TAC) 1'b0;
            end

            if (!cs_n) begin
                if ($test$plusargs("TRACE"))
                    $display("TRACE @%0t: cmd=%b ba=%b a=%h dqm=%b dq=%h dq_oe_model=%b",
                             $time, {ras_n, cas_n, we_n}, ba, a, dqm, dq, dq_en);
                case ({ras_n, cas_n, we_n})
                    CMD_ACT: begin
                        b = ba;
                        if (init_phase != 4)
                            protocol_error("INIT: 非预期 ACT");
                        else begin
                            if (active_row[b] != -1)
                                protocol_error("ACT 打到未预充电的 bank");
                            if (edge_cnt - last_act[b] < T_RC_C)
                                protocol_error("tRC 违例");
                            active_row[b] = a[ROW_BITS-1:0];
                            last_act[b]   = edge_cnt;
                        end
                    end
                    CMD_PRE: begin
                        if (init_phase == 0) begin
                            if (a[10] !== 1'b1)
                                protocol_error("INIT: PRECHARGE 不是 ALL(A10=1)");
                            else begin
                                init_phase = 1;
                                init_aref_cnt = 0;
                            end
                        end else if (init_phase != 4)
                            protocol_error("INIT: 非预期 PRECHARGE");
                        else begin
                            // 运行期显式预充电(本控制器不用,仅做检查)
                            if (a[10]) begin
                                for (b = 0; b < BANKS; b = b + 1)
                                    active_row[b] = -1;
                            end else
                                active_row[ba] = -1;
                        end
                    end
                    CMD_AREF: begin
                        if (init_phase == 1) begin
                            init_aref_cnt = init_aref_cnt + 1;
                            if (init_aref_cnt == NUM_INIT_AREF)
                                init_phase = 3;
                        end
                        else if (init_phase != 4)
                            protocol_error("INIT: 非预期 AUTO REFRESH");
                        else begin
                            for (b = 0; b < BANKS; b = b + 1)
                                if (active_row[b] != -1)
                                    protocol_error("AREF 时 bank 未空闲");
                        end
                        // 刷新间隔统计
                        if (aref_last_t != 0) begin
                            if ($time - aref_last_t > aref_max_gap)
                                aref_max_gap = $time - aref_last_t;
                        end
                        aref_last_t = $time;
                        aref_cnt = aref_cnt + 1;
                    end
                    CMD_MRS: begin
                        if (init_phase == 3) begin
                            if (ba !== 2'b00)
                                protocol_error("INIT: MRS 的 BA 不为 0");
                            if (a !== MODE_EXPECT)
                                protocol_error("INIT: MRS 值非 0x030");
                            init_phase = 4;
                            $display("INFO @%0t ns [sdram_model]: 初始化序列正确完成",
                                     $time);
                        end else
                            protocol_error("INIT: 非预期 MRS");
                    end
                    CMD_READ, CMD_WRIT: begin
                        b = ba;
                        if (init_phase != 4)
                            protocol_error("INIT 完成前出现读写");
                        else begin
                            if (active_row[b] == -1)
                                protocol_error("读写打到未激活的 bank");
                            if (edge_cnt - last_act[b] < T_RCD_C)
                                protocol_error("tRCD 违例");
                            full_addr = (b << 22) |
                                        ((active_row[b] & 8191) << 9) |
                                        (a & 511);
                            if ({ras_n, cas_n, we_n} == CMD_READ) begin
                                rd_vld[0] <= 1'b1;
                                rd_dat[0] <= mem[full_addr[23:0]];
                            end else begin
                                // WRITE: 数据与命令同拍,DQM 掩码延迟 0
                                if (!dqm[0]) mem[full_addr[23:0]][7:0]   <= dq[7:0];
                                if (!dqm[1]) mem[full_addr[23:0]][15:8]  <= dq[15:8];
                            end
                            // auto-precharge(A10=1): 本控制器恒用
                            if (a[10])
                                prech_at[b] = edge_cnt +
                                    (({ras_n,cas_n,we_n} == CMD_WRIT) ? 4 : 3);
                        end
                    end
                    CMD_NOP: begin end
                    default: protocol_error("非法命令编码");
                endcase
            end
        end
    end

    // 读 DQM 掩码:被屏蔽的字节驱动为 x(用 0 代替并提示,此处直接清 0)
    function [15:0] rd_dat_masked;
        input [15:0] d;
        input [1:0]  m;
        begin
            rd_dat_masked[7:0]  = m[0] ? 8'h00 : d[7:0];
            rd_dat_masked[15:8] = m[1] ? 8'h00 : d[15:8];
        end
    endfunction

endmodule
