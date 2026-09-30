`timescale 1ns/1ps

module test;

    // ============================================================
    // PARAMETERS
    // ============================================================

    parameter PROG_ADDR_WIDTH = 12;
    parameter DATA_ADDR_WIDTH = 14;
    parameter DATA_WIDTH      = 32;

    parameter STACK_START = 14'h3FFF;
    parameter STACK_LIMIT = 14'h3F00;

    // ============================================================
    // DUT SIGNALS
    // ============================================================

    reg clk;
    reg rst_n;

    reg  [DATA_WIDTH-1:0] instruction;
    wire [PROG_ADDR_WIDTH-1:0] pc;

    reg  [DATA_WIDTH-1:0] rdata;
    reg                   cpu_ready;

    wire                   cpu_req;
    wire                   read_write;
    wire [DATA_ADDR_WIDTH-1:0] addr;
    wire [DATA_WIDTH-1:0] wdata;

    // ============================================================
    // DUT
    // ============================================================

    cpu_core #(
        .PROG_ADDR_WIDTH(PROG_ADDR_WIDTH),
        .DATA_ADDR_WIDTH(DATA_ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .STACK_LIMIT(STACK_LIMIT)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),

        .instruction(instruction),
        .pc         (pc),

        .rdata      (rdata),
        .cpu_ready  (cpu_ready),

        .cpu_req    (cpu_req),
        .read_write (read_write),
        .addr       (addr),
        .wdata      (wdata)
    );

    // ============================================================
    // PROGRAM MEMORY
    // ============================================================

    reg [31:0] prog_mem [0:4095];

    // ============================================================
    // DATA MEMORY
    // ============================================================

    reg [31:0] data_mem [0:16383];

    // ============================================================
    // VARIABLES
    // ============================================================

    integer i;
    integer failures;
    integer passed;

    reg [31:0] saved_stack_data;

    // ============================================================
    // CLOCK
    // ============================================================

    initial begin
        clk = 1'b0;

        forever #5 clk = ~clk;
    end

    // ============================================================
    // INSTRUCTION MEMORY
    //
    // Combinational read.
    // PC is a WORD address.
    // ============================================================

    always @(*) begin
        instruction = prog_mem[pc];
    end

    // ============================================================
    // DATA MEMORY MODEL
    //
    // Supports programmable wait states.
    // ============================================================

    integer wait_counter;
    integer wait_cycles;

    always @(posedge clk) begin

        if (!rst_n) begin
            cpu_ready <= 1'b0;
            rdata     <= 32'b0;
            wait_counter <= 0;
        end

        else begin

            // --------------------------------------------
            // No request
            // --------------------------------------------

            if (!cpu_req) begin
                cpu_ready <= 1'b0;
                rdata     <= 32'b0;
                wait_counter <= 0;
            end

            // --------------------------------------------
            // Request
            // --------------------------------------------

            else begin

                if (wait_counter < wait_cycles) begin
                    wait_counter <= wait_counter + 1;
                    cpu_ready <= 1'b0;
                end

                else begin

                    cpu_ready <= 1'b1;

                    if (read_write) begin

                        data_mem[addr] <= wdata;

                        $display(
                            "[MEM WRITE] t=%0t addr=0x%04h data=0x%08h",
                            $time,
                            addr,
                            wdata
                        );

                    end

                    else begin

                        rdata <= data_mem[addr];

                        $display(
                            "[MEM READ ] t=%0t addr=0x%04h data=0x%08h",
                            $time,
                            addr,
                            data_mem[addr]
                        );

                    end

                end
            end
        end
    end

    // ============================================================
    // DEBUG MONITOR
    // ============================================================

    always @(posedge clk) begin

        if (rst_n) begin

            $display(
                "[CPU] t=%0t PC=%0d instr=0x%08h req=%b wr=%b addr=0x%04h wdata=0x%08h ready=%b",
                $time,
                pc,
                instruction,
                cpu_req,
                read_write,
                addr,
                wdata,
                cpu_ready
            );

        end

    end

    // ============================================================
    // RESET TASK
    // ============================================================

    task reset_cpu;
    begin

        rst_n = 1'b0;

        cpu_ready = 1'b0;
        rdata = 32'b0;

        wait_cycles = 0;
        wait_counter = 0;

        repeat (3)
            @(posedge clk);

        rst_n = 1'b1;

        @(posedge clk);

        $display("");
        $display("====================================================");
        $display(" RESET RELEASED");
        $display("====================================================");
        $display("");

    end
    endtask

    // ============================================================
    // CLEAR MEMORIES
    // ============================================================

    task clear_memories;
        integer j;
    begin

        for (j = 0; j < 4096; j = j + 1)
            prog_mem[j] = 32'h00000000;

        for (j = 0; j < 16384; j = j + 1)
            data_mem[j] = 32'h00000000;

    end
    endtask

    // ============================================================
    // ENCODING TASKS
    //
    // We intentionally use TASKS rather than zero-port functions.
    // This keeps the TB compatible with Icarus.
    // ============================================================

    task set_nop;
    begin
        prog_mem[0] = 32'h00000000;
    end
    endtask

    task put_call;
        input integer address;
        input integer target;
    begin
        prog_mem[address] =
            {8'h27, 4'h0, 4'h0, 4'h0, target[11:0]};
    end
    endtask

    task put_ret;
        input integer address;
    begin
        prog_mem[address] =
            {8'h28, 24'h000000};
    end
    endtask

    task put_halt;
        input integer address;
    begin
        prog_mem[address] =
            {8'hFF, 24'h000000};
    end
    endtask

    task put_load_imm;
        input integer address;
        input integer rd_num;
        input integer immediate;
    begin
        prog_mem[address] =
            {8'h03, rd_num[3:0], 4'h0, 4'h0, immediate[11:0]};
    end
    endtask

    // ============================================================
    // WAIT UNTIL CALL WRITE OCCURS
    // ============================================================

    task wait_for_call_write;
        input [11:0] expected_call_pc;
        input [11:0] expected_return_pc;

        integer timeout;
    begin

        timeout = 0;

        while (timeout < 1000) begin

            @(posedge clk);

            if (cpu_req &&
                read_write &&
                (addr == STACK_START)) begin

                $display("");
                $display("----------------------------------------------------");
                $display(" CALL TRANSACTION");
                $display("----------------------------------------------------");
                $display("CALL PC              = %0d", expected_call_pc);
                $display("Current CPU PC       = %0d", pc);
                $display("Expected return PC   = %0d", expected_return_pc);
                $display("Stack address        = 0x%04h", addr);
                $display("CALL wdata            = 0x%08h", wdata);
                $display("CPU ready             = %b", cpu_ready);

                if (wdata !== expected_return_pc) begin

                    $display("*** FAIL: CALL did not save PC + 1 ***");
                    $display("Expected: 0x%08h", expected_return_pc);
                    $display("Actual  : 0x%08h", wdata);

                    failures = failures + 1;

                end
                else begin

                    $display("*** PASS: CALL saved PC + 1 ***");

                    passed = passed + 1;

                end

                $display("----------------------------------------------------");
                $display("");

                disable wait_for_call_write;

            end

            timeout = timeout + 1;

        end

        $display("*** ERROR: CALL transaction timeout ***");

        failures = failures + 1;

    end
    endtask

    // ============================================================
    // TEST 1
    //
    // BASIC CALL / RET
    //
    // PC 1: CALL 4
    // PC 2: instruction after CALL
    // PC 3: HALT
    //
    // PC 4: RET
    //
    // Expected:
    //
    // CALL at 1
    // saved return address = 2
    // target = 4
    //
    // RET:
    // returns to 2
    // ============================================================

    task test_basic_call_ret;

        integer timeout;

    begin

        $display("");
        $display("====================================================");
        $display(" TEST 1: BASIC CALL / RET");
        $display("====================================================");

        clear_memories;

        // PC 0
        prog_mem[0] = 32'h00000000;

        // PC 1
        put_call(1, 4);

        // PC 2
        put_load_imm(2, 1, 12'h123);

        // PC 3
        put_halt(3);

        // PC 4
        put_ret(4);

        reset_cpu;

        // Wait for CALL write
        wait_for_call_write(1, 2);

        // Wait until CALL reaches target 4
        timeout = 0;

        while ((pc !== 12'd4) && (timeout < 1000)) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        if (pc !== 12'd4) begin

            $display("*** FAIL: CALL target incorrect ***");
            $display("Expected PC = 4");
            $display("Actual PC   = %0d", pc);

            failures = failures + 1;

        end
        else begin

            $display("*** PASS: CALL target = 4 ***");

            passed = passed + 1;

        end

        // Wait until RET has requested the saved address
        timeout = 0;

        while (!((cpu_req === 1'b1) &&
                  (read_write === 1'b0) &&
                  (addr === STACK_START)) &&
               timeout < 1000) begin

            @(posedge clk);
            timeout = timeout + 1;

        end

        if (timeout >= 1000) begin

            $display("*** FAIL: RET memory request timeout ***");

            failures = failures + 1;

        end

        // Wait for returned PC = 2
        timeout = 0;

        while ((pc !== 12'd2) && (timeout < 1000)) begin

            @(posedge clk);
            timeout = timeout + 1;

        end

        if (pc !== 12'd2) begin

            $display("*** FAIL: RET returned to wrong PC ***");
            $display("Expected PC = 2");
            $display("Actual PC   = %0d", pc);

            failures = failures + 1;

        end
        else begin

            $display("*** PASS: RET returned to PC 2 ***");

            passed = passed + 1;

        end

        $display("*** TEST 1 COMPLETE ***");

    end
    endtask

    // ============================================================
    // TEST 2
    //
    // MULTIPLE CALL TARGETS
    //
    // Ensures CALL target is independent from return address.
    // ============================================================

    task test_multiple_targets;

        integer target;
        integer timeout;

    begin

        $display("");
        $display("====================================================");
        $display(" TEST 2: MULTIPLE CALL TARGETS");
        $display("====================================================");

        for (target = 16; target <= 256; target = target * 2) begin

            clear_memories;

            // CALL from PC 1
            put_call(1, target);

            // instruction after CALL
            put_load_imm(2, 1, target);

            // halt
            put_halt(3);

            // target
            put_ret(target);

            reset_cpu;

            // Wait for stack write
            timeout = 0;

            while (!((cpu_req === 1'b1) &&
                      (read_write === 1'b1) &&
                      (addr === STACK_START)) &&
                   timeout < 1000) begin

                @(posedge clk);
                timeout = timeout + 1;

            end

            if (timeout >= 1000) begin

                $display("*** FAIL: CALL timeout target %0d ***", target);

                failures = failures + 1;

            end

            else if (wdata !== 32'd2) begin

                $display("*** FAIL: Target %0d saved return %0d instead of 2 ***",
                         target,
                         wdata);

                failures = failures + 1;

            end

            else begin

                $display(
                    "*** PASS: target=%0d return_address=%0d ***",
                    target,
                    wdata
                );

                passed = passed + 1;

            end

            // Wait for target
            timeout = 0;

            while ((pc !== target[11:0]) && (timeout < 1000)) begin

                @(posedge clk);
                timeout = timeout + 1;

            end

            if (pc !== target[11:0]) begin

                $display(
                    "*** FAIL: CALL target expected %0d got %0d ***",
                    target,
                    pc
                );

                failures = failures + 1;

            end

        end

        $display("*** TEST 2 COMPLETE ***");

    end
    endtask

    // ============================================================
    // TEST 3
    //
    // NESTED CALLS
    //
    // PC 1  : CALL 8
    // PC 2  : after outer CALL
    //
    // PC 8  : CALL 12
    // PC 9  : after inner CALL
    //
    // PC 12 : RET
    //
    // Expected stack:
    //
    // 0x3FFF = 2
    // 0x3FFE = 9
    //
    // Inner RET -> 9
    // Outer RET -> 2
    // ============================================================

    task test_nested_calls;

        integer timeout;

    begin

        $display("");
        $display("====================================================");
        $display(" TEST 3: NESTED CALLS");
        $display("====================================================");

        clear_memories;

        put_call(1, 8);
        put_halt(2);

        put_call(8, 12);
        put_halt(9);

        put_ret(12);

        reset_cpu;

        // --------------------------------------------------------
        // Outer CALL
        // --------------------------------------------------------

        timeout = 0;

        while (!((cpu_req === 1'b1) &&
                  (read_write === 1'b1) &&
                  (addr === STACK_START)) &&
               timeout < 1000) begin

            @(posedge clk);
            timeout = timeout + 1;

        end

        if (wdata !== 32'd2) begin

            $display("*** FAIL: Outer CALL saved %0d, expected 2 ***",
                     wdata);

            failures = failures + 1;

        end
        else begin

            $display("*** PASS: Outer CALL saved 2 ***");

            passed = passed + 1;

        end

        // --------------------------------------------------------
        // Wait for inner CALL transaction
        // --------------------------------------------------------

        timeout = 0;

        while (!((cpu_req === 1'b1) &&
                  (read_write === 1'b1) &&
                  (addr === STACK_START - 1)) &&
               timeout < 1000) begin

            @(posedge clk);
            timeout = timeout + 1;

        end

        if (wdata !== 32'd9) begin

            $display("*** FAIL: Inner CALL saved %0d, expected 9 ***",
                     wdata);

            failures = failures + 1;

        end
        else begin

            $display("*** PASS: Inner CALL saved 9 ***");

            passed = passed + 1;

        end

        // --------------------------------------------------------
        // Wait for inner RET
        // --------------------------------------------------------

        timeout = 0;

        while ((pc !== 12'd9) && (timeout < 1000)) begin

            @(posedge clk);
            timeout = timeout + 1;

        end

        if (pc !== 12'd9) begin

            $display("*** FAIL: Inner RET returned to %0d, expected 9 ***",
                     pc);

            failures = failures + 1;

        end
        else begin

            $display("*** PASS: Inner RET returned to 9 ***");

            passed = passed + 1;

        end

        // --------------------------------------------------------
        // After inner RET, execute another RET
        // --------------------------------------------------------

        prog_mem[9] = {8'h28, 24'h000000};

        timeout = 0;

        while ((pc !== 12'd2) && (timeout < 1000)) begin

            @(posedge clk);
            timeout = timeout + 1;

        end

        if (pc !== 12'd2) begin

            $display("*** FAIL: Outer RET returned to %0d, expected 2 ***",
                     pc);

            failures = failures + 1;

        end
        else begin

            $display("*** PASS: Outer RET returned to 2 ***");

            passed = passed + 1;

        end

        $display("*** TEST 3 COMPLETE ***");

    end
    endtask

    // ============================================================
    // TEST 4
    //
    // DEEP NESTING
    //
    // 16 nested CALLs.
    //
    // This verifies:
    //   SP decrement
    //   correct stack address
    //   correct return PC
    //   LIFO ordering
    // ============================================================

    task test_deep_nesting;

        integer depth;
        integer base;
        integer target;
        integer expected_return;
        integer timeout;
        integer expected_addr;

    begin

        $display("");
        $display("====================================================");
        $display(" TEST 4: DEEP NESTING");
        $display("====================================================");

        clear_memories;

        base = 10;

        // --------------------------------------------------------
        // Create chain:
        //
        // 1 -> 10
        // 10 -> 20
        // 20 -> 30
        // ...
        //
        // Each CALL's return address is target_location + 1
        // --------------------------------------------------------

        put_call(1, base);

        for (depth = 0; depth < 15; depth = depth + 1) begin

            target = base + depth * 10;

            put_call(
                target,
                target + 10
            );

        end

        // Final target returns
        put_ret(base + 150);

        reset_cpu;

        // --------------------------------------------------------
        // Verify every CALL stack write
        // --------------------------------------------------------

        for (depth = 0; depth < 16; depth = depth + 1) begin

            expected_addr = STACK_START - depth;

            timeout = 0;

            while (!((cpu_req === 1'b1) &&
                      (read_write === 1'b1) &&
                      (addr === expected_addr[13:0])) &&
                   timeout < 1000) begin

                @(posedge clk);
                timeout = timeout + 1;

            end

            if (timeout >= 1000) begin

                $display(
                    "*** FAIL: Missing CALL at depth %0d ***",
                    depth
                );

                failures = failures + 1;

            end
            else begin

                $display(
                    "Depth %0d: stack=0x%04h saved=0x%08h",
                    depth,
                    addr,
                    wdata
                );

                expected_return = 2;

                if (depth > 0)
                    expected_return =
                        base + (depth - 1) * 10 + 1;

                if (wdata !== expected_return) begin

                    $display(
                        "*** FAIL: depth %0d expected return %0d got %0d ***",
                        depth,
                        expected_return,
                        wdata
                    );

                    failures = failures + 1;

                end
                else begin

                    passed = passed + 1;

                end

            end

            @(posedge clk);

        end

        $display("*** TEST 4 COMPLETE ***");

    end
    endtask

    // ============================================================
    // TEST 5
    //
    // REPEATED CALL / RET
    //
    // Repeatedly exercises the same stack location.
    // ============================================================

    task test_repeated_call_ret;

        integer iteration;
        integer timeout;

    begin

        $display("");
        $display("====================================================");
        $display(" TEST 5: REPEATED CALL / RET");
        $display("====================================================");

        for (iteration = 0; iteration < 20; iteration = iteration + 1) begin

            clear_memories;

            put_call(1, 4);
            put_halt(2);

            put_ret(4);

            reset_cpu;

            // CALL
            timeout = 0;

            while (!((cpu_req === 1'b1) &&
                      (read_write === 1'b1) &&
                      (addr === STACK_START)) &&
                   timeout < 1000) begin

                @(posedge clk);
                timeout = timeout + 1;

            end

            if (wdata !== 32'd2) begin

                $display(
                    "Iteration %0d FAIL: saved %0d expected 2",
                    iteration,
                    wdata
                );

                failures = failures + 1;

            end

            // Wait for RET result
            timeout = 0;

            while ((pc !== 12'd2) && (timeout < 1000)) begin

                @(posedge clk);
                timeout = timeout + 1;

            end

            if (pc !== 12'd2) begin

                $display(
                    "Iteration %0d FAIL: returned PC=%0d",
                    iteration,
                    pc
                );

                failures = failures + 1;

            end
            else begin

                $display(
                    "Iteration %0d PASS",
                    iteration
                );

                passed = passed + 1;

            end

        end

        $display("*** TEST 5 COMPLETE ***");

    end
    endtask

    // ============================================================
    // TEST 6
    //
    // STACK ADDRESS MOVEMENT
    //
    // Two CALLs:
    //
    // first:
    //   0x3FFF -> return 2
    //
    // second:
    //   0x3FFE -> return 11
    //
    // RET:
    //   0x3FFE -> 11
    //   0x3FFF -> 2
    // ============================================================

    task test_stack_movement;

        integer timeout;

    begin

        $display("");
        $display("====================================================");
        $display(" TEST 6: STACK ADDRESS MOVEMENT");
        $display("====================================================");

        clear_memories;

        put_call(1, 10);
        put_halt(2);

        put_call(10, 20);
        put_halt(11);

        put_ret(20);

        reset_cpu;

        // First CALL
        timeout = 0;

        while (!((cpu_req === 1'b1) &&
                  (read_write === 1'b1) &&
                  (addr === STACK_START)) &&
               timeout < 1000) begin

            @(posedge clk);
            timeout = timeout + 1;

        end

        if (wdata !== 32'd2) begin

            $display("*** FAIL: First CALL return address ***");

            failures = failures + 1;

        end
        else begin

            $display(
                "First CALL: addr=0x%04h return=%0d",
                addr,
                wdata
            );

            passed = passed + 1;

        end

        // Second CALL
        timeout = 0;

        while (!((cpu_req === 1'b1) &&
                  (read_write === 1'b1) &&
                  (addr === STACK_START - 1)) &&
               timeout < 1000) begin

            @(posedge clk);
            timeout = timeout + 1;

        end

        if (wdata !== 32'd11) begin

            $display("*** FAIL: Second CALL return address ***");

            failures = failures + 1;

        end
        else begin

            $display(
                "Second CALL: addr=0x%04h return=%0d",
                addr,
                wdata
            );

            passed = passed + 1;

        end

        // Inner RET -> 11
        timeout = 0;

        while ((pc !== 12'd11) && (timeout < 1000)) begin

            @(posedge clk);
            timeout = timeout + 1;

        end

        if (pc !== 12'd11) begin

            $display("*** FAIL: Inner RET ***");

            failures = failures + 1;

        end
        else begin

            $display("*** PASS: Inner RET -> 11 ***");

            passed = passed + 1;

        end

        // Put RET at 11
        put_ret(11);

        // Outer RET -> 2
        timeout = 0;

        while ((pc !== 12'd2) && (timeout < 1000)) begin

            @(posedge clk);
            timeout = timeout + 1;

        end

        if (pc !== 12'd2) begin

            $display("*** FAIL: Outer RET ***");

            failures = failures + 1;

        end
        else begin

            $display("*** PASS: Outer RET -> 2 ***");

            passed = passed + 1;

        end

        $display("*** TEST 6 COMPLETE ***");

    end
    endtask

    // ============================================================
    // TEST 7
    //
    // WAIT STATE STRESS
    //
    // CALL and RET must hold their memory transaction until
    // cpu_ready becomes active.
    // ============================================================

    task test_wait_states;

        integer timeout;

    begin

        $display("");
        $display("====================================================");
        $display(" TEST 7: MEMORY WAIT-STATE STRESS");
        $display("====================================================");

        clear_memories;

        put_call(1, 4);
        put_halt(2);
        put_ret(4);

        reset_cpu;

        // --------------------------------------------------------
        // CALL with 5 wait cycles
        // --------------------------------------------------------

        wait_cycles = 5;
        wait_counter = 0;

        timeout = 0;

        while (!((cpu_req === 1'b1) &&
                  (read_write === 1'b1) &&
                  (addr === STACK_START)) &&
               timeout < 1000) begin

            @(posedge clk);
            timeout = timeout + 1;

        end

        if (timeout >= 1000) begin

            $display("*** FAIL: CALL request timeout ***");

            failures = failures + 1;

        end
        else begin

            saved_stack_data = wdata;

            $display(
                "*** CALL request detected: return=%0d ***",
                saved_stack_data
            );

            // Request must remain asserted while waiting.
            repeat (3) begin

                @(posedge clk);

                if (!cpu_req) begin

                    $display(
                        "*** FAIL: CALL request disappeared during wait ***"
                    );

                    failures = failures + 1;

                end

                if (wdata !== saved_stack_data) begin

                    $display(
                        "*** FAIL: CALL wdata changed during wait ***"
                    );

                    failures = failures + 1;

                end

            end

            if (saved_stack_data !== 32'd2) begin

                $display("*** FAIL: CALL saved wrong return address ***");

                failures = failures + 1;

            end
            else begin

                $display("*** PASS: CALL survived wait states ***");

                passed = passed + 1;

            end

        end

        // --------------------------------------------------------
        // Wait for target
        // --------------------------------------------------------

        timeout = 0;

        while ((pc !== 12'd4) && (timeout < 1000)) begin

            @(posedge clk);
            timeout = timeout + 1;

        end

        if (pc !== 12'd4) begin

            $display("*** FAIL: CALL target after wait ***");

            failures = failures + 1;

        end
        else begin

            $display("*** PASS: CALL target after wait = 4 ***");

            passed = passed + 1;

        end

        // --------------------------------------------------------
        // RET with 5 wait cycles
        // --------------------------------------------------------

        wait_counter = 0;

        timeout = 0;

        while (!((cpu_req === 1'b1) &&
                  (read_write === 1'b0) &&
                  (addr === STACK_START)) &&
               timeout < 1000) begin

            @(posedge clk);
            timeout = timeout + 1;

        end

        if (timeout >= 1000) begin

            $display("*** FAIL: RET request timeout ***");

            failures = failures + 1;

        end
        else begin

            $display("*** RET request detected ***");

            repeat (3) begin

                @(posedge clk);

                if (!cpu_req) begin

                    $display(
                        "*** FAIL: RET request disappeared during wait ***"
                    );

                    failures = failures + 1;

                end

            end

        end

        // --------------------------------------------------------
        // Wait for returned PC
        // --------------------------------------------------------

        timeout = 0;

        while ((pc !== 12'd2) && (timeout < 1000)) begin

            @(posedge clk);
            timeout = timeout + 1;

        end

        if (pc !== 12'd2) begin

            $display(
                "*** FAIL: RET returned to PC %0d instead of 2 ***",
                pc
            );

            failures = failures + 1;

        end
        else begin

            $display("*** PASS: RET survived wait states ***");

            passed = passed + 1;

        end

        wait_cycles = 0;

        $display("*** TEST 7 COMPLETE ***");

    end
    endtask

    // ============================================================
    // TEST 8
    //
    // MIXED RANDOMIZED CALL TARGETS
    //
    // Uses several independent CALL locations and verifies:
    //
    //   saved return address = CALL PC + 1
    //   target PC = encoded target
    //
    // This does not depend on zero-port functions.
    // ============================================================

    task test_mixed_targets;

        integer k;
        integer call_pc;
        integer target_pc;
        integer timeout;

    begin

        $display("");
        $display("====================================================");
        $display(" TEST 8: MIXED CALL TARGET STRESS");
        $display("====================================================");

        for (k = 0; k < 10; k = k + 1) begin

            clear_memories;

            call_pc = 1 + k;
            target_pc = 100 + (k * 37);

            put_call(call_pc, target_pc);

            // Return instruction at target.
            put_ret(target_pc);

            reset_cpu;

            // Wait for CALL
            timeout = 0;

            while (!((cpu_req === 1'b1) &&
                      (read_write === 1'b1) &&
                      (addr === STACK_START)) &&
                   timeout < 1000) begin

                @(posedge clk);
                timeout = timeout + 1;

            end

            if (timeout >= 1000) begin

                $display(
                    "*** FAIL: iteration %0d CALL timeout ***",
                    k
                );

                failures = failures + 1;

            end
            else begin

                if (wdata !== (call_pc + 1)) begin

                    $display(
                        "*** FAIL: iteration %0d return=%0d expected=%0d ***",
                        k,
                        wdata,
                        call_pc + 1
                    );

                    failures = failures + 1;

                end
                else begin

                    $display(
                        "Iteration %0d: CALL PC=%0d target=%0d return=%0d PASS",
                        k,
                        call_pc,
                        target_pc,
                        wdata
                    );

                    passed = passed + 1;

                end

            end

            // Wait for target
            timeout = 0;

            while ((pc !== target_pc[11:0]) &&
                   (timeout < 1000)) begin

                @(posedge clk);
                timeout = timeout + 1;

            end

            if (pc !== target_pc[11:0]) begin

                $display(
                    "*** FAIL: iteration %0d target PC=%0d expected=%0d ***",
                    k,
                    pc,
                    target_pc
                );

                failures = failures + 1;

            end
            else begin

                $display(
                    "*** Target %0d reached ***",
                    target_pc
                );

            end

        end

        $display("*** TEST 8 COMPLETE ***");

    end
    endtask

    // ============================================================
    // FINAL TEST SEQUENCE
    // ============================================================

    initial begin

        failures = 0;
        passed   = 0;

        rst_n = 1'b0;

        instruction = 32'b0;
        rdata       = 32'b0;
        cpu_ready   = 1'b0;

        wait_cycles  = 0;
        wait_counter = 0;

        clear_memories;

        // --------------------------------------------------------
        // Run tests
        // --------------------------------------------------------

        test_basic_call_ret;

        test_multiple_targets;

        test_nested_calls;

        test_deep_nesting;

        test_repeated_call_ret;

        test_stack_movement;

        test_wait_states;

        test_mixed_targets;

        // --------------------------------------------------------
        // Final result
        // --------------------------------------------------------

        #20;

        $display("");
        $display("====================================================");
        $display("             CALL / RET STRESS COMPLETE");
        $display("====================================================");

        $display("Passed checks : %0d", passed);
        $display("Failed checks : %0d", failures);

        if (failures == 0) begin

            $display("");
            $display("*** ALL CALL / RET TESTS PASSED ***");
            $display("");

        end
        else begin

            $display("");
            $display("*** CALL / RET TESTS FAILED ***");
            $display("");

        end

        $display("====================================================");

        $finish;

    end

endmodule
