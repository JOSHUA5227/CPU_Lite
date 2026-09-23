TOPLEVEL_LANG = verilog

SIM = icarus

TOPLEVEL = cpu
MODULE = test_cpu

COMPILE_ARGS += -g2012

VERILOG_SOURCES = \
    $(PWD)/../src/cpu.v \
    $(PWD)/../src/cpu_core.v \
    $(PWD)/../src/program_memory.v \
    $(PWD)/../src/cache.v \
    $(PWD)/../src/async_fifo/async_fifo.v \
    $(PWD)/../src/async_fifo/fifo_read.v \
    $(PWD)/../src/async_fifo/fifo_write.v \
    $(PWD)/../src/async_fifo/mem.v \
    $(PWD)/../src/async_fifo/sync_multi.v \
    $(PWD)/../src/memory_controller.v \
    $(PWD)/../src/data_memory.v

WAVES = 1

include $(shell cocotb-config --makefiles)/Makefile.sim
