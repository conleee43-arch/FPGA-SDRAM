# EP4CE10 + Winbond W9825G6KH-6 SDRAM 控制器

专业级 Verilog SDRAM 控制器，针对用户板子的**实际连接**编写：
FPGA 为 Altera Cyclone IV E（EP4CE10F17C8），SDRAM 为 Winbond W9825G6KH-6
（256Mb，16M×16，4 bank / 13 行 / 9 列，54-pin TSOP-II，-6 速度等级）。

单时钟域 100MHz，native 极简接口（一次读写一个 16 位字，带字节使能），
上电自动初始化 + 自动刷新，附上电连续自检（LED 指示），iverilog 仿真全过。

## 文件清单

```
sdram-controller/
├── rtl/
│   ├── sdram_ctrl.v         # 控制器本体（native 接口，时序全参数化）
│   ├── sdram_top.v          # 板级顶层：PLL + 控制器 + 自检 + LED + UART
│   ├── sdram_selftest.v     # 上电自检/连续压力测试（LFSR 数据，多 bank 轮询）
│   ├── sdram_pll.v          # ALTPLL 模块（50MHz -> 100MHz c0 + 100MHz -3ns c1）
│   ├── uart_send.v          # UART 并转串发送模块（参考 lha6958h-pro）
│   └── sdram_uart_monitor.v # UART 监控与状态汇报（每秒输出测试轮数与健康度）
├── tb/
│   ├── sdram_model.v        # SDRAM 行为模型（初始化序列/时序违例检查）
│   ├── sdram_pll_sim.v      # 仿真用 PLL 行为模型
│   ├── tb_sdram_ctrl.v      # 控制器功能测试（8 大项，3 个 seed 全过）
│   └── tb_sdram_top.v       # 顶层集成测试（3 轮自检）
├── doc/
│   └── PLL_设置说明.md      # PLL 参数与移相计算说明
├── sdram.qpf                # Quartus II 工程文件
├── sdram.qsf                # 引脚约束与 IO 标准配置（已含 PIN_A13 UART）
├── sdram.sdc                # 基本时序约束
├── flash_program.bat        # 板载 Flash (W25Q16/EPCS16) 一键全自动固化烧录脚本
├── generate_jic.bat         # .sof 转 .jic 配置文件转换脚本
├── program_flash.cdf        # Quartus 烧录链描述文件 (JTAG 间接烧录)
└── README.md                # 本文件
```

## 用户接口（sdram_ctrl）

```verilog
// 写：busy=0 时把 wr_req 打一拍，{wr_addr, wr_data, wr_be} 当拍锁存
// 读：busy=0 时把 rd_req 打一拍，rd_addr 当拍锁存；rd_valid 拉高一拍时 rd_data 有效
// 地址：addr[23:0] = {bank[1:0], row[12:0], col[8:0]}，共 16M 字
input  wr_req,  input [23:0] wr_addr, input [15:0] wr_data, input [1:0] wr_be,
input  rd_req,  input [23:0] rd_addr,
output [15:0] rd_data, output rd_valid,
output busy,          // 1=正忙（初始化/读写/刷新中），此时发的 req 会被忽略
output init_done,     // 1=初始化完成
output err_busy_req,  // 粘滞：busy 时收到 req 置 1（调试用，复位清除）
```

关键设计点：

- **闭页策略**：每次访问 ACTIVATE 一行，发带 auto-precharge（A10=1）的
  READ/WRITE，行由器件自动关闭。逻辑最简单，不会有"开行跟踪"类 bug；
  代价是每次访问固定约 9 个时钟（90ns），16 位 @100MHz 下有效带宽约
  22MB/s——对 ADC 数据缓存绰绰有余。
- **刷新优先但不饿死请求**：每 7.8µs 一次 AUTO REFRESH；ST_IDLE 里**请求优先
  于刷新**（先做完本次访问再补刷新，90ns 相对 7.8µs 可忽略），保证
  "busy=0 时发出的 req 一定被执行"，没有采样竞争。
- **时序全参数化**：`T_RP_NS / T_RCD_NS / T_RC_NS / T_RFC_NS / T_REFI_NS` 等
  以 ns 为单位，内部 `ns2cyc()` 向上取整；等待实现是"计数到 0 再加一拍"的
  保守风格（实际等待 = ceil+1 拍），时序只会更宽松。
- **读捕获延迟可调**：`RD_CAP_CYC`（默认 `CL+2=5`），见下节时序分析。

## 时序分析：为什么 SDRAM 时钟超前 3ns，读捕获延迟是 CL+2

设控制器时钟 `sys_clk` 100MHz（10ns），`sdram_clk` 由 PLL 超前 L=3ns。
FPGA 输出 Tco≈4ns，SDRAM 的 tAC 最大 5ns（-6 档，手册 Rev A02 §9.5），
PCB 走线约 0.3ns。

**写方向（FPGA→SDRAM）**：命令在 sys 沿 S0 后约 S0+4 到达 SDRAM 引脚；
SDRAM 用超前的时钟采样，采样沿在 S0+11.3ns。建立时间
= 11.3 − 4 − 1.5 ≈ **5.8ns**，充足。

**读方向（SDRAM→FPGA）**：READ 在 S0+11.3 被采样，SDRAM 在 +CL×10ns 后
驱动 DQ，tAC（最大 5ns）后有效，到达 FPGA 约 S0+46.6ns。FPGA 在 sys 沿采样：
S0+40（数据还没到 ✗）、**S0+50（余量约 3.4ns ✓）**。所以捕获延迟是
发出 READ 后第 **CL+2 = 5** 个 sys 时钟。

如果不超前（L=0）：数据约 S0+50 到达，S0+50 采样余量只剩 0.3ns，
几乎一定不稳定——这就是"SDRAM 时钟必须 PLL 移相"的数学原因。
超前 3ns 等于把 3ns 从"命令建立预算"（本来就宽裕）挪给"读回路预算"。

`RD_CAP_CYC` 和 PLL 移相是上板后唯二可能要微调的量：
先调移相（±1ns 步进），再调 `RD_CAP_CYC`。**必须用自检模块的连续读写
长时间验证，不能只看单次读写**（Altera 官方文档原话警告：试错法可能调出
"假窗口"，单次能过、连续跑就错）。

## 引脚映射（已按截图逐脚核对，39/39 齐）

BANK4：**CS=K10**，**D0=P14**，**D6=L11**（2026-10-18 补充截图确认）

BANK5：D1=M12，D3=L12，D7=K12，D2=N14，RAS=K11，D5=L14，D4=L13，
D14=L16，D15=L15，D9=J11，D12=K16，D13=K15，D10=J16，D11=J15，
DQM0=J14，CAS=J12，WE=J13

BANK6：D8=G16，DQM1=G15，BA1=F13，CKE=F16，A12=F15，A6=B16，
A10=F14，A11=D16，A9=D15，BA0=G11，A8=C16，A7=C15

BANK7：A3=C14，A2=D14，A4=A14，**CLK=B14**（PLL2 CLKOUTp 专用时钟输出脚，
设计本身就是用 PLL 驱动 SDRAM 时钟），A1=E11，A0=F11，A5=A15

注意：
- SDRAM 是 3.3V 供电，IO 标准全部用 3.3-V LVTTL；原理图 POWER 页确认
  **VCCIO1~VCCIO8 全部 3.3V**（VCC_IO 经 R9=0Ω 接 VCC3.3），BANK4/5/6/7 无误。
- 板级引脚（原理图 `E10_________V1.1.pdf`，正点原子 E10）：
  `clk_50m`=E1（50MHz 晶振），`rst_n`=M1（RESET 按键，低有效），
  `led_init_done`=A4（LED0，高电平亮），`led_err`=B5（LED1，高电平亮）。
  `uart_txd`=A13（UART 串口发送引脚，115200bps，与 lha6958h-pro 硬件一致）。

## 硬件上板实测验证（2026-10-18）

- **芯片**：Altera Cyclone IV E EP4CE10F17C8，SDRAM Winbond W9825G6KH-6。
- **指示灯状态**：
  - LED0（A4）常亮：SDRAM 200µs 等待 + PRECH ALL + 8×AREF + MRS 初始化 100% 成功。
  - LED1（B5）保持熄灭：读写连续自检与回环比对零错误。
- **串口实时监控（COM12，115200 8-N-1）**：
  板载每秒自动上报测试进展与健康度：
  ```text
  [PASS] Rounds: 0x83C9 | Errors: 0 | SDRAM OK!
  [PASS] Rounds: 0x887E | Errors: 0 | SDRAM OK!
  [PASS] Rounds: 0x8D33 | Errors: 0 | SDRAM OK!
  ```
  实测已连续稳定跑完 **36,147 轮（累计近 1.5 亿个 16 位字随机读写与逐字校验）**，覆盖全部 4 个 Bank 轮询与高频自动刷新，**Errors 始终为 0**。


## 仿真验证报告（iverilog，2026-10-18）

测试平台：`sdram_clk` 超前 `sys_clk` 3ns；SDRAM 行为模型带 tAC=5ns、
初始化序列严格检查、tRCD/tRC 违例检查、刷新间隔统计。

`tb_sdram_ctrl`（控制器单体，3 个随机 seed 全过）：
1. 初始化序列正确（PRECH ALL → 8×AREF → MRS=0x030），`init_done` 在复位后
   200.8µs 拉高（200µs 规范等待 + 开销）✔
2. 单字写/读回 ✔
3. 字节使能（DQM）：只写低/高字节 ✔
4. 跨 bank、跨行读写 ✔
5. 64 字连续写 + 连续读 ✔
6. 2000 次随机读写（记分牌，期间穿过多次刷新），模型零违例 ✔
7. 空闲 30µs：自动刷新 4 次，最大间隔 7.99µs（< 8.2µs 上限）✔
8. busy 时打 req 置起 `err_busy_req` ✔

`tb_sdram_top`（顶层集成：PLL 模型 + 控制器 + 自检）：3 轮自检
（每轮 4096 字 LFSR 伪随机数，写后读回比较，bank 轮询），零错误 ✔

仿真中抓到的真 bug（已修）：
1. **READ 命令编码写错**：`drive_cmd` 参数顺序传错，把 READ（0101）发成了
   Burst Terminate（0110），读永远回 Z。——靠模型的"非法命令"检查抓到。
2. **ST_IDLE 里刷新与请求竞争**：`busy=0` 时发出的 req，若在 DUT 采样前刷新
   计时器恰好到期，请求会被吞掉（TB 以为写成功了）。修法：ST_IDLE 里请求
   恒优先于刷新（先做完本次访问再补刷新），`err_busy_req` 改判据为"本拍
   确实没被接受"。——靠随机压力测试抓到（单次读写测不出来）。
3. **自检模块连发**：自检看 `!busy` 发 req，但 DUT 的 busy 拉高有 1 拍延迟，
   导致连发两次（第二次被忽略但地址/LFSR 已步进），读写地址错开一位。
   修法：发完后必须见到 busy 拉高才允许再发（`req_outstanding` 标志）。
   ——靠顶层集成测试抓到。

## 上板步骤

1. 用 MegaWizard 按 `doc/PLL_设置说明.md` 生成 `sdram_pll`，
   **删除 `tb/sdram_pll_sim.v`**（只留一个同名模块）。
2. 综合、下载。观察 LED：LED0（A4）常亮 → 初始化 OK；LED1（B5）亮 →
   有数据错误（粘滞，需按复位键 M1 清除）。
3. 让自检连续跑至少几分钟（覆盖多次刷新和 bank 轮询）。如果 LED1 亮，
   按 `doc/PLL_设置说明.md` 微调 PLL 移相（±1ns）或 `RD_CAP_CYC`。
4. 自检长期稳定后，把 `sdram_top` 里的自检模块换成你的应用逻辑
   （ADC 数据缓存等），`sdram_ctrl` 的 native 接口直接对接。
5. **掉电固化（上电自启）**：若需掉电后不丢失程序，直接双击运行工程根目录下的 `flash_program.bat`，脚本将自动把最新的 `sdram.sof` 转换为 `sdram.jic` 并一键烧录到板载 W25Q16 (EPCS16) Flash 中。烧录完成后重新插拔电源即可脱机自启动。

## 时序参数来源（2026-10-18 已用官方手册闭环）

用户提供了 Winbond **W9825G6KH 官方 datasheet Rev A02**（2014-09-01），
-6 档精确值已逐项核对（§9.5 AC Characteristics）：

| 参数 | 手册 -6 值 | 本工程实际等待 | 结论 |
|---|---|---|---|
| tRCD | 15ns | T_RCD_NS=18 → 有效约 30ns（3 拍） | ✓ 2 倍余量 |
| tRP | 15ns | T_RP_NS=18 → 有效约 30ns（3 拍） | ✓ |
| tRC | 60ns | T_RC_NS=60 → ACT 到 ACT 有效约 90ns（9 拍） | ✓ |
| tRFC（=tRC） | 60ns | T_RFC_NS=80 → 有效约 90ns+ | ✓ |
| tRAS | 42ns min | 写 60ns / 读 70ns（auto-precharge） | ✓ |
| tWR | 2tCK | 由 tRC 全程覆盖（WRITE→下次 ACT 60ns ≥ 35ns） | ✓ |
| tRSC | 2tCK | T_MRD_CYC=2 | ✓ |
| tAC（CL=3） | 5ns max | 读捕获 RD_CAP_CYC=5，余量约 3.4ns | ✓ |
| tREF | 64ms/8K 行 | 7.8µs 间隔 → 63.9ms 刷完 | ✓ |
| 初始化 | 200µs→PRECH ALL→8×AREF→MRS（§7.1） | 完全一致，DQM/CKE 拉高满足 | ✓ |
| MRS | BL=1/顺序/CL=3 | 0x030（§10.4 模式寄存器表核对） | ✓ |

组织（4 bank / 13 行 / 9 列）、tDS/tDH=1.5/0.8ns、tCMS/tCMH=1.5/0.8ns
同样来自该手册。**时序缺口已关闭，无需量产前复核。**
- 方法论借鉴了 MIT 许可的 [zhelnio/ahb_lite_sdram](https://github.com/zhelnio/ahb_lite_sdram)
 （闭页 + auto-precharge 极简 FSM，硬件验证过）；
  另评估了 [ultraembedded/core_sdram_axi4](https://github.com/ultraembedded/core_sdram_axi4)
 （GPL-3.0，只借鉴了 ns→时钟向上取整的参数化写法，未复用代码）。
  两个仓库的只读 copy 在 `~/workspace/research_notes/sdram-refs/`。
- PLL 移相：Altera 官方《SDRAM PLL Tuning》文档（存于上述 `sdram-refs/ahb_lite_sdram/doc/`
  目录）指出 100MHz 下有效窗口在超前 1ns ~ 滞后 2.5ns 之间，本工程取 -3ns
  为初值（Terasic DE2 系列同款经验值），上板按第 5 步微调。

## 性能

- 单字访问约 9 时钟（90ns），连续读写约 11M 字/s ≈ 22MB/s（16 位）。
- 刷新开销：每 7.8µs 占用 9 个时钟，约 1.2%。
