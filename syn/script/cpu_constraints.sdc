create_clock -period 6.6667 [get_ports fast_clk]
create_clock -period 14.2857 [get_ports slow_clk]

set_clock_groups -asynchronous -group [get_clocks fast_clk] -group [get_clocks slow_clk]

set_false_path -from [get_ports fast_rst_n]
set_false_path -from [get_ports slow_rst_n]

set_input_delay 3.33335 -clock [get_clocks fast_clk] [get_ports instruction] 
set_input_delay 7.14285 -clock [get_clocks slow_clk] [get_ports {mem_rvalid mem_rdata}] 

set_clock_uncertainty 0.133334 [get_clocks fast_clk]
set_clock_uncertainty 0.285714 [get_clocks slow_clk]

set_output_delay 3.33335 -clock [get_clocks fast_clk] [get_ports cpu_pc] 
set_output_delay 7.14285 -clock [get_clocks slow_clk] [get_ports {mem_addr mem_wdata mem_read_en mem_write_en}] 
