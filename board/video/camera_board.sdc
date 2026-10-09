create_clock -name csi_rxc_i -period 5.347594 [get_ports {csi_rxc_i}]
create_clock -name bscan_TCK -period 166.666667 [get_ports {bscan_TCK}]
source outflow/camera_board.pt.sdc
set_clock_groups -asynchronous -group {clk_compute} -group {clk_sys core_clk tdqss_clk tac_clk twd_clk} -group {bscan_TCK}
# DDR IP CDC constraints from the supplied Ti60 camera reference.
set_max_delay -from [get_clocks {core_clk}] -to [get_clocks {clk_sys}] 5
set_max_delay -from [get_clocks {clk_sys}] -to [get_clocks {core_clk}] 5
set_false_path -from [get_clocks {tac_clk}] -to [get_clocks {clk_sys}]
set_false_path -from [get_clocks {twd_clk}] -to [get_clocks {clk_sys}]
set_false_path -from [get_clocks {clk_sys}] -to [get_clocks {tac_clk}]
set_false_path -from [get_clocks {clk_sys}] -to [get_clocks {twd_clk}]
set_false_path -from [get_clocks {twd_clk}] -to [get_clocks {core_clk}]

set_clock_groups -asynchronous -group {clk_video clk_video_5x} -group {clk_sys core_clk tdqss_clk tac_clk twd_clk clk_compute bscan_TCK}
set_clock_groups -asynchronous -group {csi_rxc_i} -group {clk_sys clk_compute core_clk tdqss_clk tac_clk twd_clk clk_video clk_video_5x bscan_TCK}
set_clock_groups -asynchronous -group {clk_27m} -group {clk_sys clk_compute core_clk tdqss_clk tac_clk twd_clk clk_video clk_video_5x csi_rxc_i bscan_TCK}
set_false_path -from [get_ports {key_data[0]}]
