`timescale 1ns/1ps

module test;

parameter ADDR_WIDTH = 14;
parameter DATA_WIDTH = 32;

parameter CACHE_LINES = 8;
parameter WORDS_PER = 4;

parameter FIFO_DEPTH = 8;


// ============================================================
// CLOCKS
// ============================================================

reg clk_150;
reg clk_70;

initial
begin
    clk_150 = 1'b0;
    forever #3.333 clk_150 = ~clk_150;
end

initial
begin
    clk_70 = 1'b0;
    forever #7.143 clk_70 = ~clk_70;
end


// ============================================================
// RESET
// ============================================================

reg rst_n;

initial
begin
    rst_n = 1'b0;

    repeat(5)
        @(posedge clk_150);

    rst_n = 1'b1;
end


// ============================================================
// CPU SIDE
// ============================================================

reg                     cpu_req;
reg                     read_write;
reg [ADDR_WIDTH-1:0]    addr;
reg [DATA_WIDTH-1:0]    wdata;

wire [DATA_WIDTH-1:0]   rdata;
wire                    cpu_ready;


// ============================================================
// CACHE <-> REQUEST FIFO
// ============================================================

wire [ADDR_WIDTH+DATA_WIDTH:0] cache_req_data;
wire                            cache_req_en;
wire                            req_fifo_full;


// ============================================================
// REQUEST FIFO <-> CONTROLLER
// ============================================================

wire [ADDR_WIDTH+DATA_WIDTH:0] req_fifo_rdata;
wire                            req_fifo_empty;
wire                            req_fifo_r_en;


// ============================================================
// CACHE <-> RESPONSE FIFO
// ============================================================

wire [DATA_WIDTH-1:0] response_fifo_rdata;
wire                  response_fifo_empty;
wire                  response_fifo_r_en;


// ============================================================
// CONTROLLER <-> RESPONSE FIFO
// ============================================================

wire [DATA_WIDTH-1:0] response_fifo_wdata;
wire                  response_fifo_w_en;
wire                  response_fifo_full;


// ============================================================
// CONTROLLER <-> MEMORY
// ============================================================

wire [ADDR_WIDTH-1:0] mem_addr;
wire [DATA_WIDTH-1:0] mem_wdata;

wire mem_read_en;
wire mem_write_en;

wire [DATA_WIDTH-1:0] mem_rdata;
wire                  mem_rvalid;


// ============================================================
// DUT: CACHE
// ============================================================

cache #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH),
    .CACHE_LINES(CACHE_LINES),
    .WORDS_PER(WORDS_PER)
) dut (
    .clk(clk_150),
    .rst_n(rst_n),

    .cpu_req(cpu_req),
    .read_write(read_write),
    .addr(addr),
    .wdata(wdata),

    .rdata(rdata),
    .cpu_ready(cpu_ready),

    .fifo_req_full(req_fifo_full),
    .fifo_req_data(cache_req_data),
    .fifo_req_en(cache_req_en),

    .fifo_resp_en(response_fifo_r_en),
    .fifo_resp_data(response_fifo_rdata),
    .fifo_resp_empty(response_fifo_empty)
);


// ============================================================
// REQUEST ASYNC FIFO
//
// WRITE SIDE  = CACHE / 150 MHz
// READ SIDE   = CONTROLLER / 70 MHz
// ============================================================

async_fifo #(
    .WIDTH(ADDR_WIDTH + DATA_WIDTH + 1),
    .DEPTH(FIFO_DEPTH)
) request_fifo (
    .rclk(clk_70),
    .wclk(clk_150),

    .w_rst_n(rst_n),
    .r_rst_n(rst_n),

    .r_data(req_fifo_rdata),
    .w_data(cache_req_data),

    .r_en(req_fifo_r_en),
    .w_en(cache_req_en),

    .full(req_fifo_full),
    .empty(req_fifo_empty)
);


// ============================================================
// RESPONSE ASYNC FIFO
//
// WRITE SIDE = CONTROLLER / 70 MHz
// READ SIDE  = CACHE / 150 MHz
// ============================================================

async_fifo #(
    .WIDTH(DATA_WIDTH),
    .DEPTH(FIFO_DEPTH)
) response_fifo (
    .rclk(clk_150),
    .wclk(clk_70),

    .w_rst_n(rst_n),
    .r_rst_n(rst_n),

    .r_data(response_fifo_rdata),
    .w_data(response_fifo_wdata),

    .r_en(response_fifo_r_en),
    .w_en(response_fifo_w_en),

    .full(response_fifo_full),
    .empty(response_fifo_empty)
);


// ============================================================
// MEMORY CONTROLLER
// ============================================================

memory_controller #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH)
) controller (
    .clk(clk_70),
    .rst_n(rst_n),

    // request FIFO
    .req_data(req_fifo_rdata),
    .req_empty(req_fifo_empty),
    .req_en(req_fifo_r_en),

    // response FIFO
    .resp_data(response_fifo_wdata),
    .resp_en(response_fifo_w_en),
    .resp_full(response_fifo_full),

    // memory
    .mem_addr(mem_addr),
    .mem_wdata(mem_wdata),

    .mem_read_en(mem_read_en),
    .mem_write_en(mem_write_en),

    .mem_rdata(mem_rdata),
    .mem_rvalid(mem_rvalid)
);


// ============================================================
// 16 KB MEMORY
// ============================================================

data_memory #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH)
) memory (
    .clk(clk_70),
    .rst_n(rst_n),

    .read_en(mem_read_en),
    .write_en(mem_write_en),

    .addr(mem_addr),
    .wdata(mem_wdata),

    .rdata(mem_rdata),
    .rvalid(mem_rvalid)
);


// ============================================================
// TEST VARIABLES
// ============================================================

integer total_checks;
integer passed_checks;
integer failed_checks;

integer memory_write_count;

reg memory_write_seen;
reg [ADDR_WIDTH-1:0] memory_write_addr_seen;
reg [DATA_WIDTH-1:0] memory_write_data_seen;


// ============================================================
// MEMORY WRITE MONITOR
//
// This is important:
// DO NOT check writes using an arbitrary #delay.
//
// We observe the actual memory write event.
// ============================================================

always @(posedge clk_70)
begin
    if(rst_n && mem_write_en)
    begin
        memory_write_count = memory_write_count + 1;

        memory_write_seen      = 1'b1;
        memory_write_addr_seen = mem_addr;
        memory_write_data_seen = mem_wdata;

        $display("[MEM WRITE] t=%0t ADDR=%0d DATA=%h",
                 $time,
                 mem_addr,
                 mem_wdata);
    end
end


// ============================================================
// MEMORY READ MONITOR
// ============================================================

always @(posedge clk_70)
begin
    if(rst_n && mem_read_en)
    begin
        $display("[MEM READ] t=%0t ADDR=%0d",
                 $time,
                 mem_addr);
    end
end


// ============================================================
// RESPONSE FIFO WRITE MONITOR
// ============================================================

always @(posedge clk_70)
begin
    if(rst_n && response_fifo_w_en)
    begin
        $display("[MEM -> RESP FIFO] t=%0t DATA=%h",
                 $time,
                 response_fifo_wdata);
    end
end


// ============================================================
// CACHE REQUEST MONITOR
// ============================================================

always @(posedge clk_150)
begin
    if(rst_n && cache_req_en)
    begin
        $display("[CACHE -> REQ FIFO] t=%0t DATA=%h RW=%b ADDR=%0d",
                 $time,
                 cache_req_data,
                 cache_req_data[ADDR_WIDTH+DATA_WIDTH],
                 cache_req_data[ADDR_WIDTH+DATA_WIDTH-1:DATA_WIDTH]);
    end
end


// ============================================================
// RESPONSE FIFO READ MONITOR
// ============================================================

always @(posedge clk_150)
begin
    if(rst_n && response_fifo_r_en)
    begin
        $display("[CACHE -> RESP FIFO READ] t=%0t EMPTY=%b DATA=%h",
                 $time,
                 response_fifo_empty,
                 response_fifo_rdata);
    end
end


// ============================================================
// CACHE RESPONSE MONITOR
// ============================================================

always @(posedge clk_150)
begin
    if(rst_n && cpu_ready)
    begin
        $display("[CPU READY] t=%0t ADDR=%0d RDATA=%h",
                 $time,
                 addr,
                 rdata);
    end
end


// ============================================================
// CHECK TASK
// ============================================================

task check;
    input condition;
    input [8*100-1:0] message;

    begin
        total_checks = total_checks + 1;

        if(condition)
        begin
            passed_checks = passed_checks + 1;

            $display("[PASS] %s", message);
        end
        else
        begin
            failed_checks = failed_checks + 1;

            $display("[FAIL] %s", message);
        end
    end
endtask


// ============================================================
// CPU READ REQUEST
//
// Waits for actual cpu_ready.
// No arbitrary fixed delay.
// ============================================================
task cpu_read;
    input [ADDR_WIDTH-1:0] read_addr;
    output [DATA_WIDTH-1:0] read_data;

    begin

        @(negedge clk_150);

        addr       = read_addr;
        wdata      = 0;
        read_write = 1'b0;
        cpu_req    = 1'b1;

        // Wait until cache reaches RESPONSE.
        // Check on the falling edge so the outputs are stable.
        @(negedge clk_150);

        while(!cpu_ready)
            @(negedge clk_150);

        // cpu_ready and rdata are stable here.
        read_data = rdata;

        $display("[TB READ] t=%0t ADDR=%0d DATA=%h",
                 $time,
                 read_addr,
                 read_data);

        // Remove request after observing the response.
        cpu_req = 1'b0;

        @(negedge clk_150);

    end
endtask

// ============================================================
// CPU WRITE REQUEST
//
// Waits for cache cpu_ready.
// Write completion means request FIFO accepted it,
// according to the cache architecture.
// ============================================================

task cpu_write;
    input [ADDR_WIDTH-1:0] write_addr;
    input [DATA_WIDTH-1:0] write_data;

    begin

        @(negedge clk_150);

        addr       = write_addr;
        wdata      = write_data;
        read_write = 1'b1;
        cpu_req    = 1'b1;

        @(posedge clk_150);

        @(negedge clk_150);

        cpu_req = 1'b0;

        while(!cpu_ready)
            @(posedge clk_150);

        @(negedge clk_150);

        cpu_req = 1'b0;

    end
endtask


// ============================================================
// WAIT FOR MEMORY WRITE
// ============================================================

task wait_for_memory_write;
    input [ADDR_WIDTH-1:0] expected_addr;
    input [DATA_WIDTH-1:0] expected_data;

    integer timeout;

    begin

        timeout = 0;

        while(!memory_write_seen && timeout < 1000)
        begin
            @(posedge clk_70);
            timeout = timeout + 1;
        end

        check(
            memory_write_seen &&
            memory_write_addr_seen == expected_addr &&
            memory_write_data_seen == expected_data,
            "Memory write reached expected address/data"
        );

        memory_write_seen = 1'b0;

    end
endtask


// ============================================================
// INITIALIZE MEMORY
//
// Only initialize locations that are used by tests.
// ============================================================

task write_mem_direct;
    input [ADDR_WIDTH-1:0] maddr;
    input [DATA_WIDTH-1:0] mdata;

    begin
        memory.mem[maddr] = mdata;
    end
endtask


// ============================================================
// INITIALIZE FOUR-WORD CACHE LINE IN MEMORY
// ============================================================

task init_line;
    input [ADDR_WIDTH-1:0] base;
    input [DATA_WIDTH-1:0] d0;
    input [DATA_WIDTH-1:0] d1;
    input [DATA_WIDTH-1:0] d2;
    input [DATA_WIDTH-1:0] d3;

    begin
        memory.mem[base+0] = d0;
        memory.mem[base+1] = d1;
        memory.mem[base+2] = d2;
        memory.mem[base+3] = d3;
    end
endtask


// ============================================================
// RESET CHECK
// ============================================================

task reset_check;

    begin

        $display("");
        $display("==================================================");
        $display("RESET");
        $display("==================================================");

        while(!rst_n)
            @(posedge clk_150);

        repeat(3)
            @(posedge clk_150);

        check(req_fifo_empty,
              "Request FIFO empty after reset");

        check(response_fifo_empty,
              "Response FIFO empty after reset");

        check(dut.present_state == 3'd0,
              "Cache returned to IDLE after reset");

    end

endtask


// ============================================================
// TEST 1
// WRITE MISS / WRITE THROUGH
// ============================================================

task test_write_miss;

    begin

        $display("");
        $display("==================================================");
        $display("TEST 1: WRITE MISS / WRITE-THROUGH");
        $display("==================================================");

        memory_write_seen = 1'b0;

        cpu_write(
            14'd100,
            32'hDEADBEEF
        );

        wait_for_memory_write(
            14'd100,
            32'hDEADBEEF
        );

        check(response_fifo_empty,
              "Write produced no response");

    end

endtask


// ============================================================
// TEST 2
// READ MISS / FOUR WORD REFILL
// ============================================================

task test_read_miss;

    reg [DATA_WIDTH-1:0] rd;

    begin

        $display("");
        $display("==================================================");
        $display("TEST 2: READ MISS / FOUR-WORD REFILL");
        $display("==================================================");

        init_line(
            14'd100,
            32'hDEADBEEF,
            32'h22222222,
            32'h33333333,
            32'h44444444
        );

        cpu_read(14'd100, rd);

        check(
            rd == 32'hDEADBEEF,
            "Read miss returned correct requested word"
        );

        check(
            dut.valid_array[1] == 1'b1,
            "Cache line became valid after refill"
        );

        check(
            dut.data_array[1][0] == 32'hDEADBEEF,
            "Refill word 0 correct"
        );

        check(
            dut.data_array[1][1] == 32'h22222222,
            "Refill word 1 correct"
        );

        check(
            dut.data_array[1][2] == 32'h33333333,
            "Refill word 2 correct"
        );

        check(
            dut.data_array[1][3] == 32'h44444444,
            "Refill word 3 correct"
        );

    end

endtask


// ============================================================
// TEST 3
// CACHE HIT
// ============================================================

task test_cache_hit;

    reg [DATA_WIDTH-1:0] rd;

    begin

        $display("");
        $display("==================================================");
        $display("TEST 3: CACHE HIT");
        $display("==================================================");

        cpu_read(14'd100, rd);

        check(
            rd == 32'hDEADBEEF,
            "Cache hit returned correct data"
        );

    end

endtask


// ============================================================
// TEST 4
// CACHE WORD OFFSETS
// ============================================================

task test_offsets;

    reg [DATA_WIDTH-1:0] rd;

    begin

        $display("");
        $display("==================================================");
        $display("TEST 4: CACHE WORD OFFSETS");
        $display("==================================================");

        cpu_read(14'd101, rd);

        check(
            rd == 32'h22222222,
            "Offset 1 returned correct data"
        );

        cpu_read(14'd102, rd);

        check(
            rd == 32'h33333333,
            "Offset 2 returned correct data"
        );

        cpu_read(14'd103, rd);

        check(
            rd == 32'h44444444,
            "Offset 3 returned correct data"
        );

    end

endtask


// ============================================================
// TEST 5
// WRITE HIT / WRITE THROUGH
// ============================================================

task test_write_hit;

    reg [DATA_WIDTH-1:0] rd;

    begin

        $display("");
        $display("==================================================");
        $display("TEST 5: WRITE HIT / WRITE-THROUGH");
        $display("==================================================");

        memory_write_seen = 1'b0;

        cpu_write(
            14'd101,
            32'hABCDEF01
        );

        check(
            dut.data_array[1][1] == 32'hABCDEF01,
            "Cache updated on write hit"
        );

        wait_for_memory_write(
            14'd101,
            32'hABCDEF01
        );

        cpu_read(14'd101, rd);

        check(
            rd == 32'hABCDEF01,
            "Updated cache word read correctly"
        );

    end

endtask


// ============================================================
// TEST 6
// DIFFERENT CACHE INDEX
// ============================================================

task test_different_index;

    reg [DATA_WIDTH-1:0] rd;

    begin

        $display("");
        $display("==================================================");
        $display("TEST 6: DIFFERENT CACHE INDEX");
        $display("==================================================");

        init_line(
            14'd200,
            32'hAAAAAAAA,
            32'hBBBBBBBB,
            32'hCCCCCCCC,
            32'hDDDDDDDD
        );

        cpu_read(14'd200, rd);

        check(
            rd == 32'hAAAAAAAA,
            "Different cache index returned correct data"
        );

    end

endtask


// ============================================================
// TEST 7
// SAME INDEX / DIFFERENT TAG
// ============================================================

task test_same_index_different_tag;

    reg [DATA_WIDTH-1:0] rd;

    begin

        $display("");
        $display("==================================================");
        $display("TEST 7: SAME INDEX / DIFFERENT TAG");
        $display("==================================================");

        init_line(
            14'd300,
            32'h12345678,
            32'h00000001,
            32'h00000002,
            32'h00000003
        );

        cpu_read(14'd300, rd);

        check(
            rd == 32'h12345678,
            "First tag returned correct data"
        );

        check(
            dut.tag_array[3] == 300 >> 5,
            "First tag stored correctly"
        );

        init_line(
            14'd332,
            32'h87654321,
            32'h00000004,
            32'h00000005,
            32'h00000006
        );

        cpu_read(14'd332, rd);

        check(
            rd == 32'h87654321,
            "Second tag returned correct data"
        );

        check(
            dut.tag_array[3] == 332 >> 5,
            "Second tag replaced cache line"
        );

    end

endtask


// ============================================================
// TEST 8
// ADDRESS ZERO
// ============================================================

task test_address_zero;

    reg [DATA_WIDTH-1:0] rd;

    begin

        $display("");
        $display("==================================================");
        $display("TEST 8: ADDRESS ZERO");
        $display("==================================================");

        init_line(
            14'd0,
            32'hCAFEBABE,
            32'h11110001,
            32'h11110002,
            32'h11110003
        );

        cpu_read(14'd0, rd);

        check(
            rd == 32'hCAFEBABE,
            "Address zero returned correct data"
        );

    end

endtask


// ============================================================
// TEST 9
// HIGHEST MEMORY ADDRESS
// ============================================================

task test_highest_address;

    reg [DATA_WIDTH-1:0] rd;

    begin

        $display("");
        $display("==================================================");
        $display("TEST 9: HIGHEST MEMORY ADDRESS");
        $display("==================================================");

        init_line(
            14'd16380,
            32'h10000000,
            32'h20000000,
            32'h30000000,
            32'hFACEFACE
        );

        cpu_read(14'd16383, rd);

        check(
            rd == 32'hFACEFACE,
            "Highest address returned correct data"
        );

        check(
            dut.data_array[7][3] == 32'hFACEFACE,
            "Highest address stored at offset 3"
        );

    end

endtask


// ============================================================
// TEST 10
// MULTIPLE CACHE LINES
// ============================================================
// ============================================================
// TEST 10
// MULTIPLE CACHE LINES
// ============================================================

task test_multiple_lines;

    integer k;
    reg [DATA_WIDTH-1:0] rd;

    begin

        $display("");
        $display("==================================================");
        $display("TEST 10: MULTIPLE CACHE LINES");
        $display("==================================================");

        for(k = 1; k <= 8; k = k + 1)
        begin

            init_line(
                k * 14'd16,
                32'h10000000 + k*4,
                32'h10000001 + k*4,
                32'h10000002 + k*4,
                32'h10000003 + k*4
            );

            cpu_read(k * 14'd16, rd);

            check(
                rd == (32'h10000000 + k*4),
                "Multiple cache line read correct"
            );

        end

    end

endtask


// ============================================================
// TEST 11
// REPEATED CACHE HITS
// ============================================================

task test_repeated_hits;

    integer k;
    reg [DATA_WIDTH-1:0] rd;

    begin

        $display("");
        $display("==================================================");
        $display("TEST 11: REPEATED CACHE HITS");
        $display("==================================================");

        init_line(
            14'd500,
            32'h5555AAAA,
            32'h55550001,
            32'h55550002,
            32'h55550003
        );

        cpu_read(14'd500, rd);

        check(
            rd == 32'h5555AAAA,
            "Initial read correct"
        );

        for(k = 0; k < 10; k = k + 1)
        begin

            cpu_read(14'd500, rd);

            check(
                rd == 32'h5555AAAA,
                "Repeated cache hit correct"
            );

        end

    end

endtask


// ============================================================
// TEST 12
// WRITE MISS / NO WRITE ALLOCATE
// ============================================================

task test_write_miss_no_allocate;

    reg [DATA_WIDTH-1:0] rd;

    begin

        $display("");
        $display("==================================================");
        $display("TEST 12: WRITE MISS / NO-WRITE-ALLOCATE");
        $display("==================================================");

        memory_write_seen = 1'b0;

        cpu_write(
            14'd700,
            32'hABC12345
        );

        wait_for_memory_write(
            14'd700,
            32'hABC12345
        );

        // Address 700 should not become a valid cache line
check(
    !(dut.valid_array[7] && dut.tag_array[7] == 9'd21),
    "Write miss did not allocate cache line"
);
    end

endtask


// ============================================================
// FINAL IDLE CHECK
// ============================================================

task final_check;

    begin

        $display("");
        $display("==================================================");
        $display("FINAL IDLE / EMPTY CONDITIONS");
        $display("==================================================");

        repeat(10)
            @(posedge clk_150);

        check(req_fifo_empty,
              "Request FIFO empty at end");

        check(response_fifo_empty,
              "Response FIFO empty at end");

        check(dut.present_state == 3'd0,
              "Cache returned to IDLE");

        check(controller.present_state == 3'd0,
              "Controller returned to IDLE");

    end

endtask


// ============================================================
// MAIN TEST
// ============================================================

initial
begin

    cpu_req    = 1'b0;
    read_write = 1'b0;
    addr       = 0;
    wdata      = 0;

    total_checks       = 0;
    passed_checks      = 0;
    failed_checks      = 0;

    memory_write_count = 0;

    memory_write_seen      = 1'b0;
    memory_write_addr_seen = 0;
    memory_write_data_seen = 0;

    $display("");
    $display("==================================================");
    $display("CPU LITE CACHE + CDC + MEMORY TEST");
    $display("==================================================");

    reset_check();

    test_write_miss();

    test_read_miss();

    test_cache_hit();

    test_offsets();

    test_write_hit();

    test_different_index();

    test_same_index_different_tag();

    test_address_zero();

    test_highest_address();

    test_multiple_lines();

    test_repeated_hits();

    test_write_miss_no_allocate();

    final_check();

    $display("");
    $display("==================================================");
    $display("FINAL RESULTS");
    $display("==================================================");

    $display("Total checks : %0d", total_checks);
    $display("Passed       : %0d", passed_checks);
    $display("Failed       : %0d", failed_checks);

    if(failed_checks == 0)
        $display("*** ALL TESTS PASSED ***");
    else
        $display("*** SOME TESTS FAILED ***");

    $display("==================================================");

    #100;

    $finish;

end

endmodule
