# PLL 设置说明（Quartus MegaWizard）

`sdram_top` 里实例化的 `sdram_pll` 需要用 Quartus 的 MegaWizard 生成，
本目录不附带该文件（仿真时用 `tb/sdram_pll_sim.v` 同名行为模型替代，
**综合前必须删除 `tb/sdram_pll_sim.v`，只保留 MegaWizard 生成的版本**）。

## 生成步骤

1. Quartus 菜单：Tools → MegaWizard Plug-In Manager → Create a new custom megafunction variation
2. 左侧选 **ALTPLL**，输出文件命名为 `sdram_pll.v`，放在 `rtl/` 目录，语言选 Verilog
3. 第 1 页：器件选 **Cyclone IV E**，输入时钟频率按板载晶振填
   （本工程默认 **50MHz**；如果你的板子晶振不是 50MHz，下面 c0/c1 的倍频分频跟着改，
   目标都是 100MHz）
4. 第 3 页（clk0）：勾选 c0，频率 **100MHz**，相位 **0 deg**
5. 第 4 页（clk1）：勾选 c1，频率 **100MHz**，相位 **-108 deg**
   （= 超前 3ns。MegaWizard 里填的是角度：-3ns / 10ns × 360° = -108°）
6. 第 5 页：勾选 **areset**（异步复位输入）
7. 第 6 页：勾选 **locked**（锁定指示）
8. 生成，把 `sdram_pll.v` 和 `sdram_pll.qip` 加入工程

## 端口对应（`sdram_top.v` 里已经按这个接）

| sdram_pll 端口 | 接到 | 说明 |
|---|---|---|
| inclk0 | clk_50m | 板载晶振 |
| areset | ~rst_n | 高有效复位 |
| c0 | sys_clk | 100MHz，控制器时钟 |
| c1 | sdram_clk | 100MHz，超前 3ns，接 SDRAM_CLK（B14） |
| locked | pll_locked | 参与复位释放 |

## 为什么 SDRAM 时钟要超前约 3ns

FPGA 输出命令/数据到引脚有 Tco 延迟（约 4ns），SDRAM 的输出数据回到 FPGA
又要经过 tAC（最大 5.4ns）+ PCB 走线。把 SDRAM 时钟相对控制器时钟**超前约
3ns**，等于从"命令建立时间预算"里匀 3ns 给"读数据回路预算"——命令建立
本来很宽裕（约 5.5ns），读回路则从"几乎不够"变成"有约 2.5ns 余量"。
详见 `README.md` 的时序分析章节。

取值参考：
- 本工程默认 **-3ns（-108° @100MHz）**：最通用的经验值（Terasic DE2 系列同款），
  已在仿真中用 tAC=5ns 的模型验证（读捕获延迟 RD_CAP_CYC=CL+2=5）。
- Altera 官方《SDRAM PLL Tuning》文档指出 100MHz 下有效窗口大约是
  超前 0.75ns 附近（文档存于 `research_notes/sdram-refs/ahb_lite_sdram/doc/`）。
- 上板后如果读不稳定，优先调这个移相（±1ns 步进），次选调控制器的
  `RD_CAP_CYC` 参数。**必须用自检模块的连续读写（或长时间跑）验证，
  不能只看单次读写**——Altera 原话警告试错法可能调出"假窗口"。
