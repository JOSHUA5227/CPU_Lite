`timescale 1ns/1ps

// Integrated SystemVerilog regression for the CPU Lite pipelined CPU.
// Top-level DUT: cpu
// Uses the real program memory, cache, async FIFOs, memory controller,
// and data memory. No Cocotb is required.
//
// Run with Icarus Verilog from the project root using run_tests.sh.
//
// Notes:
// - The pipelined core does not expose a top-level HALT/done output, so
//   each test runs for a bounded number of cycles and then checks state.
// - Internal arrays are inspected hierarchically for debug/checking.
// - A FAIL is reported rather than stopping at the first mismatch.

module tb_cpu_pipelined;

    reg fast_clk   = 1'b0;
    reg slow_clk   = 1'b0;
    reg fast_rst_n = 1'b0;
    reg slow_rst_n = 1'b0;

    cpu dut (
        .fast_clk   (fast_clk),
        .slow_clk   (slow_clk),
        .fast_rst_n (fast_rst_n),
        .slow_rst_n (slow_rst_n)
    );

    // Approximate the periods used by the previous reference test:
    // fast clock = 6.666 ns, slow clock = 14.286 ns.
    always #3.333 fast_clk = ~fast_clk;
    always #7.143 slow_clk = ~slow_clk;

    localparam [7:0] OP_NOP       = 8'h00;
    localparam [7:0] OP_LOAD      = 8'h01;
    localparam [7:0] OP_LOAD_IND  = 8'h02;
    localparam [7:0] OP_LOAD_IMM  = 8'h03;
    localparam [7:0] OP_STORE     = 8'h04;
    localparam [7:0] OP_STORE_IND = 8'h05;
    localparam [7:0] OP_ADD       = 8'h06;
    localparam [7:0] OP_SUB       = 8'h07;
    localparam [7:0] OP_MUL       = 8'h08;
    localparam [7:0] OP_XOR       = 8'h10;
    localparam [7:0] OP_ADDI      = 8'h16;
    localparam [7:0] OP_HALT      = 8'hFF;

    integer checks = 0;
    integer failures = 0;
    integer i;

    function [31:0] rtype;
        input [7:0] op;
        input [3:0] rd;
        input [3:0] rs1;
        input [3:0] rs2;
        begin
            rtype = {op, rd, rs1, rs2, 12'h000};
        end
    endfunction

    function [31:0] itype;
        input [7:0] op;
        input [3:0] rd;
        input [3:0] rs1;
        input [11:0] imm;
        begin
            itype = {op, rd, rs1, 4'h0, imm};
        end
    endfunction

    function [31:0] load_imm;
        input [3:0] rd;
        input [11:0] imm;
        begin
            load_imm = itype(OP_LOAD_IMM, rd, 4'h0, imm);
        end
    endfunction

    function [31:0] load_direct;
        input [3:0] rd;
        input [11:0] addr;
        begin
            load_direct = itype(OP_LOAD, rd, 4'h0, addr);
        end
    endfunction

    function [31:0] store_direct;
        input [3:0] data_reg;
        input [11:0] addr;
        begin
            store_direct = itype(OP_STORE, data_reg, 4'h0, addr);
        end
    endfunction

    function [31:0] load_indirect;
        input [3:0] rd;
        input [3:0] addr_reg;
        begin
            load_indirect = {OP_LOAD_IND, rd, addr_reg, 16'h0000};
        end
    endfunction

    function [31:0] store_indirect;
        input [3:0] data_reg;
        input [3:0] addr_reg;
        begin
            store_indirect = {OP_STORE_IND, data_reg, 4'h0, addr_reg, 12'h000};
        end
    endfunction

    task automatic check_reg;
        input integer reg_index;
        input [31:0] expected;
        input [255:0] label_text;
        reg [31:0] actual;
        begin
            actual = dut.u_cpu_core.R[reg_index];
            checks = checks + 1;
            if (actual !== expected) begin
                failures = failures + 1;
                $display("FAIL %-24s R%0d actual=%08h expected=%08h",
                         label_text, reg_index, actual, expected);
            end else begin
                $display("PASS %-24s R%0d = %08h",
                         label_text, reg_index, actual);
            end
        end
    endtask

    task automatic check_mem;
        input integer address;
        input [31:0] expected;
        input [255:0] label_text;
        reg [31:0] actual;
        begin
            actual = dut.u_data_memory.mem[address];
            checks = checks + 1;
            if (actual !== expected) begin
                failures = failures + 1;
                $display("FAIL %-24s MEM[%04h] actual=%08h expected=%08h",
                         label_text, address, actual, expected);
            end else begin
                $display("PASS %-24s MEM[%04h] = %08h",
                         label_text, address, actual);
            end
        end
    endtask

    // Assert both resets, clear program/data memory for deterministic tests,
    // and leave resets asserted so the caller can load its program.
    task automatic reset_and_clear;
        integer k;
        begin
            @(negedge fast_clk);
            fast_rst_n = 1'b0;
            slow_rst_n = 1'b0;

            repeat (8) @(posedge fast_clk);
            repeat (5) @(posedge slow_clk);

            // Fill the part of program memory used by tests with NOPs.
            // The core has no externally visible HALT signal, so NOPs keep
            // execution harmless after the instructions under test.
            for (k = 0; k < 512; k = k + 1)
                dut.u_program_memory.mem[k] = 32'h00000000;

            // Initialize the memory range used by this regression.
            // Data memory itself is not cleared by its reset input.
            for (k = 0; k < 1024; k = k + 1)
                dut.u_data_memory.mem[k] = 32'h00000000;

            // Give reset state machines several edges in both domains.
            repeat (2) @(posedge fast_clk);
            repeat (2) @(posedge slow_clk);
        end
    endtask

    task automatic put_instr;
        input integer address;
        input [31:0] instruction_word;
        begin
            dut.u_program_memory.mem[address] = instruction_word;
        end
    endtask

    task automatic release_reset;
        begin
            @(negedge fast_clk);
            fast_rst_n = 1'b1;
            slow_rst_n = 1'b1;
        end
    endtask

    task automatic run_fast_cycles;
        input integer count;
        integer k;
        begin
            for (k = 0; k < count; k = k + 1)
                @(posedge fast_clk);
            @(negedge fast_clk);
        end
    endtask

    task automatic test_alu_and_forwarding;
        begin
            $display("\n=== TEST 1: ALU + back-to-back dependencies ===");
            reset_and_clear();

            put_instr(0, load_imm(1, 12'h00F));
            put_instr(1, load_imm(2, 12'h003));
            put_instr(2, rtype(OP_ADD, 3, 1, 2));  // 18
            put_instr(3, rtype(OP_SUB, 4, 1, 2));  // 12
            put_instr(4, rtype(OP_MUL, 5, 1, 2));  // 45
            put_instr(5, rtype(OP_XOR, 6, 1, 2));  // 12
            put_instr(6, itype(OP_ADDI, 7, 3, 12'h005)); // 23
            put_instr(7, rtype(OP_ADD, 8, 7, 1));  // 38, dependency
            put_instr(8, {OP_HALT, 24'h000000});

            release_reset();
            run_fast_cycles(100);

            check_reg(1, 32'h0000000F, "ALU input A");
            check_reg(2, 32'h00000003, "ALU input B");
            check_reg(3, 32'h00000012, "ADD");
            check_reg(4, 32'h0000000C, "SUB");
            check_reg(5, 32'h0000002D, "MUL");
            check_reg(6, 32'h0000000C, "XOR");
            check_reg(7, 32'h00000017, "ADDI");
            check_reg(8, 32'h00000026, "Forwarded ADD");
        end
    endtask

    task automatic test_direct_store_load;
        begin
            $display("\n=== TEST 2: direct store/load through cache and memory ===");
            reset_and_clear();

            put_instr(0, load_imm(1, 12'h555));
            put_instr(1, store_direct(1, 12'h100));
            put_instr(2, load_direct(2, 12'h100));
            put_instr(3, rtype(OP_ADD, 3, 1, 2));
            put_instr(4, {OP_HALT, 24'h000000});

            release_reset();
            run_fast_cycles(1800);

            check_reg(1, 32'h00000555, "Direct store source");
            check_reg(2, 32'h00000555, "Direct load result");
            check_reg(3, 32'h00000AAA, "Load-use dependent ADD");
            check_mem(16'h0100, 32'h00000555, "Direct backing memory");
        end
    endtask

    task automatic test_indirect_store_load;
        begin
            $display("\n=== TEST 3: indirect store/load ===");
            reset_and_clear();

            put_instr(0, load_imm(1, 12'h220)); // address
            put_instr(1, load_imm(2, 12'h123)); // value
            put_instr(2, store_indirect(2, 1));
            put_instr(3, load_indirect(3, 1));
            put_instr(4, {OP_HALT, 24'h000000});

            release_reset();
            run_fast_cycles(1800);

            check_reg(1, 32'h00000220, "Indirect address");
            check_reg(2, 32'h00000123, "Indirect store source");
            check_reg(3, 32'h00000123, "Indirect load result");
            check_mem(16'h0220, 32'h00000123, "Indirect backing memory");
        end
    endtask

    task automatic test_cache_line_refill;
        begin
            $display("\n=== TEST 4: four-word cache-line refill ===");
            reset_and_clear();

            dut.u_data_memory.mem[16'h0300] = 32'h11111111;
            dut.u_data_memory.mem[16'h0301] = 32'h22222222;
            dut.u_data_memory.mem[16'h0302] = 32'h33333333;
            dut.u_data_memory.mem[16'h0303] = 32'h44444444;

            put_instr(0, load_direct(1, 12'h300));
            put_instr(1, load_direct(2, 12'h301));
            put_instr(2, load_direct(3, 12'h302));
            put_instr(3, load_direct(4, 12'h303));
            put_instr(4, {OP_HALT, 24'h000000});

            release_reset();
            run_fast_cycles(2400);

            check_reg(1, 32'h11111111, "Cache line word 0");
            check_reg(2, 32'h22222222, "Cache line word 1");
            check_reg(3, 32'h33333333, "Cache line word 2");
            check_reg(4, 32'h44444444, "Cache line word 3");
        end
    endtask

    task automatic test_dirty_line_writeback;
        begin
            $display("\n=== TEST 5: dirty cache-line eviction/write-back ===");
            reset_and_clear();

            // A and B differ in tag but map to the same direct-mapped line.
            dut.u_data_memory.mem[16'h0100] = 32'hAAAAAAAA;
            dut.u_data_memory.mem[16'h0101] = 32'hBBBBBBBB;
            dut.u_data_memory.mem[16'h0102] = 32'hCCCCCCCC;
            dut.u_data_memory.mem[16'h0103] = 32'hDDDDDDDD;
            dut.u_data_memory.mem[16'h0120] = 32'h12345678;
            dut.u_data_memory.mem[16'h0121] = 32'h22222222;
            dut.u_data_memory.mem[16'h0122] = 32'h33333333;
            dut.u_data_memory.mem[16'h0123] = 32'h44444444;

            put_instr(0, load_direct(1, 12'h100)); // allocate A
            put_instr(1, load_imm(2, 12'h123));
            put_instr(2, store_direct(2, 12'h100)); // dirty A
            put_instr(3, load_direct(3, 12'h120)); // evict A
            put_instr(4, {OP_HALT, 24'h000000});

            release_reset();
            run_fast_cycles(3600);

            check_reg(2, 32'h00000123, "Dirty store value");
            check_reg(3, 32'h12345678, "Conflicting line load");
            check_mem(16'h0100, 32'h00000123, "Write-back word 0");
            check_mem(16'h0101, 32'hBBBBBBBB, "Write-back preserves word 1");
            check_mem(16'h0102, 32'hCCCCCCCC, "Write-back preserves word 2");
            check_mem(16'h0103, 32'hDDDDDDDD, "Write-back preserves word 3");
        end
    endtask

    initial begin
        $dumpfile("tb_cpu_pipelined.vcd");
        $dumpvars(0, tb_cpu_pipelined);

        // Initial reset values.
        fast_rst_n = 1'b0;
        slow_rst_n = 1'b0;

        test_alu_and_forwarding();
        test_direct_store_load();
        test_indirect_store_load();
        test_cache_line_refill();
        test_dirty_line_writeback();

        $display("\n==============================================");
        $display("CPU PIPELINED REGRESSION SUMMARY");
        $display("Checks : %0d", checks);
        $display("Passed : %0d", checks - failures);
        $display("Failed : %0d", failures);
        $display("==============================================");

        if (failures != 0)
            $fatal(1, "CPU regression FAILED: %0d check(s)", failures);
        else
            $display("CPU regression PASSED");

        $finish;
    end

    // Global watchdog prevents a broken testbench from hanging forever.
    initial begin
        #2000000;
        $fatal(1, "Global simulation timeout");
    end

endmodule

