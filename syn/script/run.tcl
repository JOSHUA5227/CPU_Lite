analyze -f verilog ../src/async_fifo/mem.v
analyze -f verilog ../src/async_fifo/sync_multi.v
analyze -f verilog ../src/async_fifo/fifo_read.v
analyze -f verilog ../src/async_fifo/fifo_write.v
analyze -f verilog ../src/async_fifo/async_fifo.v


analyze -f verilog ../src/memory_controller.v
analyze -f verilog ../src/cache.v
analyze -f verilog ../src/cpu_core.v
analyze -f verilog ../src/cpu.v
#analyze -f verilog ../src/program_memory.v
#analyze -f verilog ../src/data_memory.v
analyze -f verilog ../src/cpu_interface.v
elaborate cpu_interface

link
check_design

write -format ddc -hier -output unmapped/unmapped_cpu_interface.ddc
write -format verilog -hier -output unmapped/unmapped_cpu_interface.v
#write -format ddc -hier -output unmapped/unmapped_cpu.ddc
#write -format verilog -hier -output unmapped/unmapped_cpu.v

source ./script/cpu_constraints.sdc

check_timing

compile_ultra

write -format ddc -hier -output mapped/mapped_cpu_interface.ddc
#write -format ddc -hier -output mapped/mapped_cpu.ddc

write -format verilog -hier -output mapped/mapped_cpu_interface.v
#write -format verilog -hier -output mapped/mapped_cpu.v

# Area report
report_area > area_report.rpt

# Clock reports
report_clocks > clocks_report.rpt
report_clock -skew > clock_skew_report.rpt

# Timing reports
report_timing -delay max -max_paths 20 > max_delay_report.rpt
report_timing -delay min -max_paths 20 > min_delay_report.rpt

# Constraint violations
report_constraint -all_violators > constraint_violators.rpt

# Quality of Results
report_qor > qor_report.rpt
