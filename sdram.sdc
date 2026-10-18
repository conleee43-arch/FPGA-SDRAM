#=============================================================================
# sdram.sdc -- 基本时序约束(起点,上板后按 TimeQuest 报告微调)
#=============================================================================

# 板载晶振(按实际频率改)
create_clock -name clk_50m -period 20.000 [get_ports {clk_50m}]

# PLL 派生时钟由 Quartus 自动推导
derive_pll_clocks -create_base_clocks

# SDRAM 时钟是源同步输出,不按普通同步时序分析,设为 false path
# (命令/数据的建立保持靠 PLL 移相保证,见 README 时序分析)
set_false_path -from [get_clocks {sdram_pll|altpll_component|auto_generated|pll1|clk[1]}] \
               -to   [get_ports {sdram_a[*] sdram_ba[*] sdram_dq[*] sdram_dqm[*] \
                                 sdram_ras_n sdram_cas_n sdram_we_n sdram_cke sdram_cs_n}]

# 异步复位不做时序分析
set_false_path -from [get_ports {rst_n}]

# DQ 输入:按源同步约束(供参考,先用 false path 跑通,再收紧)
# set_input_delay -clock {sdram_clk} -max 6.0 [get_ports {sdram_dq[*]}]
# set_input_delay -clock {sdram_clk} -min 1.0 [get_ports {sdram_dq[*]}]
