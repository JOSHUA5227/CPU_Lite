analyze -f verilog ../src/async_fifo/mem.v
analyze -f verilog ../src/async_fifo/sync_multi.v
analyze -f verilog ../src/async_fifo/fifo_read.v
analyze -f verilog ../src/async_fifo/fifo_write.v
analyze -f verilog ../src/async_fifo/async_fifo.v


analyze -f verilog ../src/memory_controller.v
analyze -f verilog ../src/cache.v
analyze -f verilog ../src/cpu_core.v
analyze -f verilog ../src/cpu_interface.v
elaborate cpu_interface

link
check_design

write -format ddc -hier -output unmapped/unmapped_cpu_interface.ddc

source ./script/cpu_constraints.sdc

check_timing

compile_ultra

write -format ddc -hier -output mapped/mapped_cpu_interface.ddc

write -format verilog -hier -output mapped/mapped_cpu_interface.v
