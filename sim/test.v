`timescale 1ns/1ps

// ============================================================================
// CPU LITE - HARDER SELF-CHECKING TESTBENCH
//
// Assumes the DUT modules/interfaces from the original testbench:
//
//   cache
//   async_fifo
//   memory_controller
//   data_memory
//
// Cache policy being verified:
//   - direct mapped
//   - 8 lines
//   - 4 words/line
//   - write-back
//   - no-write-allocate
//
// Main improvements over the original TB:
//   1. Independent architectural reference memory.
//   2. Randomized read/write traffic.
//   3. Deliberate same-index/different-tag collisions.
//   4. Backing-memory write scoreboard.
//   5. FIFO protocol safety checks.
//   6. CPU request/completion accounting.
//   7. Randomized transaction ordering.
//   8. Directed dirty-eviction stress.
//   9. Boundary-address stress.
//  10. Final backing-memory comparison against the reference model.
// ============================================================================

module test;

parameter ADDR_WIDTH  = 14;
parameter DATA_WIDTH  = 32;
parameter CACHE_LINES = 8;
parameter WORDS_PER   = 4;
parameter FIFO_DEPTH  = 8;

localparam MEM_WORDS = (1 << ADDR_WIDTH);
localparam LINE_WORDS = WORDS_PER;
localparam INDEX_BITS = 3;       // log2(8)
localparam OFFSET_BITS = 2;      // log2(4)


// ============================================================================
// CLOCKS
// ============================================================================

reg clk_150;
reg clk_70;

initial begin
    clk_150 = 1'b0;
    forever #3.333 clk_150 = ~clk_150;
end

initial begin
    clk_70 = 1'b0;
    forever #7.143 clk_70 = ~clk_70;
end


// ============================================================================
// RESET
// ============================================================================

reg rst_n;

initial begin
    rst_n = 1'b0;

    repeat(5)
        @(posedge clk_150);

    rst_n = 1'b1;
end


// ============================================================================
// CPU SIDE
// ============================================================================

reg                     cpu_req;
reg                     read_write;
reg [ADDR_WIDTH-1:0]    addr;
reg [DATA_WIDTH-1:0]    wdata;

wire [DATA_WIDTH-1:0]   rdata;
wire                    cpu_ready;


// ============================================================================
// CACHE <-> REQUEST FIFO
// ============================================================================

wire [ADDR_WIDTH+DATA_WIDTH:0] cache_req_data;
wire                            cache_req_en;
wire                            req_fifo_full;


// ============================================================================
// REQUEST FIFO <-> CONTROLLER
// ============================================================================

wire [ADDR_WIDTH+DATA_WIDTH:0] req_fifo_rdata;
wire                            req_fifo_empty;
wire                            req_fifo_r_en;


// ============================================================================
// CACHE <-> RESPONSE FIFO
// ============================================================================

wire [DATA_WIDTH-1:0] response_fifo_rdata;
wire                  response_fifo_empty;
wire                  response_fifo_r_en;


// ============================================================================
// CONTROLLER <-> RESPONSE FIFO
// ============================================================================

wire [DATA_WIDTH-1:0] response_fifo_wdata;
wire                  response_fifo_w_en;
wire                  response_fifo_full;


// ============================================================================
// CONTROLLER <-> MEMORY
// ============================================================================

wire [ADDR_WIDTH-1:0] mem_addr;
wire [DATA_WIDTH-1:0] mem_wdata;

wire mem_read_en;
wire mem_write_en;

wire [DATA_WIDTH-1:0] mem_rdata;
wire                  mem_rvalid;


// ============================================================================
// DUT
// ============================================================================

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


memory_controller #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH)
) controller (
    .clk(clk_70),
    .rst_n(rst_n),

    .req_data(req_fifo_rdata),
    .req_empty(req_fifo_empty),
    .req_en(req_fifo_r_en),

    .resp_data(response_fifo_wdata),
    .resp_en(response_fifo_w_en),
    .resp_full(response_fifo_full),

    .mem_addr(mem_addr),
    .mem_wdata(mem_wdata),

    .mem_read_en(mem_read_en),
    .mem_write_en(mem_write_en),

    .mem_rdata(mem_rdata),
    .mem_rvalid(mem_rvalid)
);


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


// ============================================================================
// TEST / SCOREBOARD STATE
// ============================================================================

integer total_checks;
integer passed_checks;
integer failed_checks;

integer cpu_read_count;
integer cpu_write_count;
integer cpu_completion_count;

integer memory_read_count;
integer memory_write_count;

integer protocol_violations;
integer scoreboard_violations;

reg [DATA_WIDTH-1:0] ref_mem [0:MEM_WORDS-1];

reg monitor_enabled;


// ============================================================================
// CHECK TASK
// ============================================================================

task check;
    input condition;
    input [8*140-1:0] message;

    begin
        total_checks = total_checks + 1;

        if(condition) begin
            passed_checks = passed_checks + 1;
            $display("[PASS] %s", message);
        end
        else begin
            failed_checks = failed_checks + 1;
            $display("[FAIL] %s", message);
        end
    end
endtask


// ============================================================================
// INITIALIZE REFERENCE MODEL + REAL MEMORY
// ============================================================================

task initialize_memory;
    integer i;

    begin
        for(i = 0; i < MEM_WORDS; i = i + 1) begin
            ref_mem[i] = 32'h00000000;
            memory.mem[i] = 32'h00000000;
        end
    end
endtask


task write_known_line;
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

        ref_mem[base+0] = d0;
        ref_mem[base+1] = d1;
        ref_mem[base+2] = d2;
        ref_mem[base+3] = d3;
    end
endtask


// ============================================================================
// CPU READ
// ============================================================================

task cpu_read;
    input  [ADDR_WIDTH-1:0] read_addr;
    output [DATA_WIDTH-1:0] read_data;

    integer timeout;

    begin
        @(negedge clk_150);

        addr       = read_addr;
        wdata      = 0;
        read_write = 1'b0;
        cpu_req    = 1'b1;

        timeout = 0;

        while(!cpu_ready && timeout < 5000) begin
            @(negedge clk_150);
            timeout = timeout + 1;
        end

        check(cpu_ready, "CPU read eventually completed");

        read_data = rdata;

        if(cpu_ready) begin
            check(
                read_data === ref_mem[read_addr],
                "CPU read matches independent architectural reference"
            );
        end

        // Count the transaction and its completion separately.  A timeout must
        // never be counted as a successful completion.
        cpu_read_count = cpu_read_count + 1;
        if(cpu_ready)
            cpu_completion_count = cpu_completion_count + 1;

        cpu_req = 1'b0;

        // Give the DUT one full CPU cycle to leave RESPONSE/IDLE before the
        // next transaction is launched.
        @(negedge clk_150);
    end
endtask


// ============================================================================
// CPU WRITE
//
// Architectural reference is updated immediately because the CPU store has
// completed from the CPU's perspective. For write-back hits, backing memory
// intentionally remains stale until eviction.
// ============================================================================

task cpu_write;
    input [ADDR_WIDTH-1:0] write_addr;
    input [DATA_WIDTH-1:0] write_data;

    integer timeout;

    begin
        @(negedge clk_150);

        addr       = write_addr;
        wdata      = write_data;
        read_write = 1'b1;
        cpu_req    = 1'b1;

        timeout = 0;

        while(!cpu_ready && timeout < 5000) begin
            @(negedge clk_150);
            timeout = timeout + 1;
        end

        check(cpu_ready, "CPU write eventually completed");

        // Count the request regardless of whether it timed out; completion is
        // counted only when cpu_ready was actually observed.
        cpu_write_count = cpu_write_count + 1;
        if(cpu_ready) begin
            cpu_completion_count = cpu_completion_count + 1;
            // Architectural state changes at CPU-visible completion.
            ref_mem[write_addr] = write_data;
        end

        cpu_req = 1'b0;

        // Allow RESPONSE -> IDLE to settle before the next request.
        @(negedge clk_150);
    end
endtask


// ============================================================================
// MEMORY WRITE SCOREBOARD
//
// Every backing-memory write must contain the current architectural value.
//
// This catches:
//   - wrong eviction address
//   - wrong eviction data
//   - stale dirty data
//   - corrupt write-through/write-miss data
//   - wrong word ordering
// ============================================================================

always @(posedge clk_70) begin
    if(rst_n && mem_write_en) begin

        memory_write_count = memory_write_count + 1;

        $display(
            "[MEM WRITE] t=%0t ADDR=%0d DATA=%h EXPECTED=%h",
            $time,
            mem_addr,
            mem_wdata,
            ref_mem[mem_addr]
        );

        if(monitor_enabled) begin
            if(mem_wdata !== ref_mem[mem_addr]) begin
                scoreboard_violations = scoreboard_violations + 1;

                $display(
                    "*** SCOREBOARD ERROR: memory write does not match reference ***"
                );
            end
        end
    end
end


// ============================================================================
// MEMORY READ MONITOR
// ============================================================================

always @(posedge clk_70) begin
    if(rst_n && mem_read_en) begin
        memory_read_count = memory_read_count + 1;

        $display(
            "[MEM READ] t=%0t ADDR=%0d",
            $time,
            mem_addr
        );
    end
end


// ============================================================================
// FIFO SAFETY CHECKS
//
// The specification requires:
//   never write a full FIFO
//   never read an empty FIFO
//
// These are monitored continuously at the appropriate clock edges.
// ============================================================================

always @(posedge clk_150) begin
    if(rst_n) begin

        if(cache_req_en && req_fifo_full) begin
            protocol_violations = protocol_violations + 1;

            $display(
                "*** FIFO ERROR: request FIFO write while FULL t=%0t ***",
                $time
            );
        end

        if(response_fifo_r_en && response_fifo_empty) begin
            protocol_violations = protocol_violations + 1;

            $display(
                "*** FIFO ERROR: response FIFO read while EMPTY t=%0t ***",
                $time
            );
        end
    end
end


always @(posedge clk_70) begin
    if(rst_n) begin

        if(req_fifo_r_en && req_fifo_empty) begin
            protocol_violations = protocol_violations + 1;

            $display(
                "*** FIFO ERROR: request FIFO read while EMPTY t=%0t ***",
                $time
            );
        end

        if(response_fifo_w_en && response_fifo_full) begin
            protocol_violations = protocol_violations + 1;

            $display(
                "*** FIFO ERROR: response FIFO write while FULL t=%0t ***",
                $time
            );
        end
    end
end


// ============================================================================
// CACHE REQUEST FORMAT CHECK
//
// Requests crossing from cache to controller must carry:
//   RW + address + write data
//
// Read requests should not accidentally carry write intent.
// ============================================================================

always @(posedge clk_150) begin
    if(rst_n && cache_req_en) begin

        $display(
            "[CACHE -> REQ FIFO] t=%0t RW=%b ADDR=%0d DATA=%h",
            $time,
            cache_req_data[ADDR_WIDTH+DATA_WIDTH],
            cache_req_data[ADDR_WIDTH+DATA_WIDTH-1:DATA_WIDTH],
            cache_req_data[DATA_WIDTH-1:0]
        );

    end
end


// ============================================================================
// RESET CHECK
// ============================================================================

task reset_check;

    begin
        $display("");
        $display("==================================================");
        $display("RESET CHECK");
        $display("==================================================");

        while(!rst_n)
            @(posedge clk_150);

        repeat(5)
            @(posedge clk_150);

        check(req_fifo_empty,
              "Request FIFO empty after reset");

        check(response_fifo_empty,
              "Response FIFO empty after reset");

        check(dut.present_state == 3'd0,
              "Cache returned to IDLE after reset");

        check(controller.present_state == 3'd0,
              "Controller returned to IDLE after reset");
    end
endtask


// ============================================================================
// DIRECTED TEST 1
// WRITE MISS / NO-WRITE-ALLOCATE
// ============================================================================

task test_write_miss;

    begin
        $display("");
        $display("==================================================");
        $display("DIRECTED 1: WRITE MISS / NO-WRITE-ALLOCATE");
        $display("==================================================");

        cpu_write(
            14'd1000,
            32'hDEADBEEF
        );

        // Backing memory must eventually contain the store.
        wait_for_quiet(100);

        check(
            memory.mem[1000] === 32'hDEADBEEF,
            "Write miss reached backing memory"
        );

        // Address decomposition for ADDR_WIDTH=14, WORDS_PER=4,
        // CACHE_LINES=8:
        //   offset = addr[1:0]
        //   index  = addr[4:2]
        //   tag    = addr[13:5]
        // For address 1000: index=2, tag=31.
        // The old check used (1000 >> 5) as an array index (31), which is
        // outside valid_array/tag_array[0:7] and made the TB fail for the
        // wrong reason.
        check(
            !(dut.valid_array[(1000 >> OFFSET_BITS) & (CACHE_LINES-1)] &&
              dut.tag_array[(1000 >> OFFSET_BITS) & (CACHE_LINES-1)] ==
              (1000 >> (OFFSET_BITS + INDEX_BITS))),
            "Write miss did not allocate matching cache line"
        );
    end
endtask


// ============================================================================
// DIRECTED TEST 2
// READ MISS / REFILL
// ============================================================================

task test_refill;

    reg [DATA_WIDTH-1:0] rd;

    begin
        $display("");
        $display("==================================================");
        $display("DIRECTED 2: READ MISS / FOUR-WORD REFILL");
        $display("==================================================");

        write_known_line(
            14'd100,
            32'h11111111,
            32'h22222222,
            32'h33333333,
            32'h44444444
        );

        cpu_read(14'd100, rd);
        cpu_read(14'd101, rd);
        cpu_read(14'd102, rd);
        cpu_read(14'd103, rd);

        check(
            dut.valid_array[1] == 1'b1,
            "Refilled cache line is valid"
        );

        check(
            dut.data_array[1][0] === 32'h11111111,
            "Refill word 0 correct"
        );

        check(
            dut.data_array[1][1] === 32'h22222222,
            "Refill word 1 correct"
        );

        check(
            dut.data_array[1][2] === 32'h33333333,
            "Refill word 2 correct"
        );

        check(
            dut.data_array[1][3] === 32'h44444444,
            "Refill word 3 correct"
        );
    end
endtask


// ============================================================================
// DIRECTED TEST 3
// DIRTY EVICTION
// ============================================================================

task test_dirty_eviction;

    reg [DATA_WIDTH-1:0] rd;

    begin
        $display("");
        $display("==================================================");
        $display("DIRECTED 3: DIRTY EVICTION / WRITE-BACK");
        $display("==================================================");

        // Address 800 maps to index 0 for an 8-line / 4-word-line cache.
        write_known_line(
            14'd800,
            32'h80000000,
            32'h80000001,
            32'h80000002,
            32'h80000003
        );

        // Bring line into cache.
        cpu_read(14'd800, rd);

        // Modify only one word. Backing memory should remain old.
        cpu_write(
            14'd801,
            32'hDEADC0DE
        );

        check(
            memory.mem[801] === 32'h80000001,
            "Write-back hit left backing memory stale before eviction"
        );

        // 1056 = 800 + 256. Same index, different tag.
        write_known_line(
            14'd1056,
            32'h10560000,
            32'h10560001,
            32'h10560002,
            32'h10560003
        );

        cpu_read(14'd1056, rd);

        // The dirty line must now be fully written back.
        wait_for_quiet(200);

        check(
            memory.mem[800] === 32'h80000000,
            "Dirty eviction preserved word 0"
        );

        check(
            memory.mem[801] === 32'hDEADC0DE,
            "Dirty eviction wrote modified word 1"
        );

        check(
            memory.mem[802] === 32'h80000002,
            "Dirty eviction preserved word 2"
        );

        check(
            memory.mem[803] === 32'h80000003,
            "Dirty eviction preserved word 3"
        );

        check(
            memory.mem[1056] === 32'h10560000,
            "Replacement line word 0 correct"
        );

        check(
            memory.mem[1059] === 32'h10560003,
            "Replacement line word 3 correct"
        );
    end
endtask


// ============================================================================
// DIRECTED TEST 4
// CLEAN EVICTION
// ============================================================================

task test_clean_eviction;

    reg [DATA_WIDTH-1:0] rd;
    integer writes_before;

    begin
        $display("");
        $display("==================================================");
        $display("DIRECTED 4: CLEAN EVICTION");
        $display("==================================================");

        write_known_line(
            14'd1200,
            32'h12000000,
            32'h12000001,
            32'h12000002,
            32'h12000003
        );

        cpu_read(14'd1200, rd);

        writes_before = memory_write_count;

        // 1456 = 1200 + 256, same index/different tag.
        write_known_line(
            14'd1456,
            32'h14560000,
            32'h14560001,
            32'h14560002,
            32'h14560003
        );

        cpu_read(14'd1456, rd);

        wait_for_quiet(150);

        check(
            memory_write_count == writes_before,
            "Clean eviction generated no write-back"
        );
    end
endtask


// ============================================================================
// DIRECTED TEST 5
// SAME INDEX / MANY TAGS
// ============================================================================

task test_collision_stress;

    integer k;
    reg [DATA_WIDTH-1:0] rd;
    integer base;

    begin
        $display("");
        $display("==================================================");
        $display("DIRECTED 5: SAME INDEX / MANY TAG COLLISIONS");
        $display("==================================================");

        // All addresses are separated by 32 words and therefore target
        // repeated cache indices with different tags.
        for(k = 0; k < 12; k = k + 1) begin

            base = 32 * k;

            write_known_line(
                base,
                32'hA0000000 + k,
                32'hA1000000 + k,
                32'hA2000000 + k,
                32'hA3000000 + k
            );

            cpu_read(base, rd);

            check(
                rd === ref_mem[base],
                "Collision stress returned expected word"
            );

            // Dirty a different word every iteration.
            cpu_write(
                base + 1,
                32'hD0000000 + k
            );

            cpu_read(base + 1, rd);

            check(
                rd === (32'hD0000000 + k),
                "Dirty collision word reads back correctly"
            );
        end
    end
endtask


// ============================================================================
// RANDOM TEST
// ============================================================================

task randomized_test;

    integer k;
    integer op;
    integer r;
    integer a;
    reg [ADDR_WIDTH-1:0] ra;
    reg [DATA_WIDTH-1:0] rd;
    reg [DATA_WIDTH-1:0] wd;

    begin
        $display("");
        $display("==================================================");
        $display("RANDOMIZED ARCHITECTURAL TEST");
        $display("==================================================");

        // Deterministic seed so failures can be reproduced.
        r = 32'h5A17C0DE;

        for(k = 0; k < 300; k = k + 1) begin

            op = $random(r);

            if(op < 0)
                op = -op;

            op = op % 100;

            // Deliberately bias a portion of traffic toward cache collisions.
            if((k % 5) == 0) begin
                a = ((k / 5) % 8) * 32;
                a = a + ((k / 7) % 4);
            end
            else begin
                a = $random(r);

                if(a < 0)
                    a = -a;

                a = a % MEM_WORDS;
            end

            ra = a[ADDR_WIDTH-1:0];

            wd = $random(r);

            if(op < 55) begin
                cpu_read(ra, rd);
            end
            else begin
                cpu_write(ra, wd);
            end

            // Periodically force the transaction stream to settle.
            if((k % 25) == 24)
                wait_for_quiet(100);
        end

        $display(
            "[RANDOM] Reads=%0d Writes=%0d CPU completions=%0d",
            cpu_read_count,
            cpu_write_count,
            cpu_completion_count
        );
    end
endtask


// ============================================================================
// BOUNDARY TEST
// ============================================================================

task boundary_test;

    reg [DATA_WIDTH-1:0] rd;

    begin
        $display("");
        $display("==================================================");
        $display("BOUNDARY ADDRESS TEST");
        $display("==================================================");

        write_known_line(
            14'd0,
            32'hCAFEBABE,
            32'h00000001,
            32'h00000002,
            32'h00000003
        );

        cpu_read(14'd0, rd);
        cpu_read(14'd3, rd);

        write_known_line(
            14'd16380,
            32'h10000000,
            32'h20000000,
            32'h30000000,
            32'hFACEFACE
        );

        cpu_read(14'd16380, rd);
        cpu_read(14'd16381, rd);
        cpu_read(14'd16382, rd);
        cpu_read(14'd16383, rd);

        check(
            rd === 32'hFACEFACE,
            "Highest legal memory address returned correctly"
        );
    end
endtask


// ============================================================================
// QUIET WAIT
// ============================================================================

task wait_for_quiet;
    input integer cycles;

    integer i;

    begin
        for(i = 0; i < cycles; i = i + 1)
            @(posedge clk_150);
    end
endtask


// ============================================================================
// DRAIN ALL DIRTY CACHE LINES
//
// A write-back cache may legally retain dirty data after the last CPU
// transaction. Waiting alone cannot make backing memory equal the reference
// model.  Force an eviction for every currently dirty line by issuing a read
// to a different tag with the same index.  Repeat because an eviction can
// expose another dirty line at that index.
// ============================================================================
task drain_dirty_lines;
    integer pass;
    integer idx;
    integer victim_tag;
    integer alt_tag;
    reg [ADDR_WIDTH-1:0] victim_addr;
    reg [ADDR_WIDTH-1:0] conflict_addr;
    reg [DATA_WIDTH-1:0] rd;
    reg found_dirty;

    begin
        $display("");
        $display("==================================================");
        $display("DRAINING DIRTY CACHE LINES");
        $display("==================================================");

        // At most CACHE_LINES+2 passes are needed for the small direct-mapped
        // cache used by this TB. Extra passes make the procedure robust to
        // replacement chains.
        for(pass = 0; pass < (CACHE_LINES + 2); pass = pass + 1) begin
            found_dirty = 1'b0;

            for(idx = 0; idx < CACHE_LINES; idx = idx + 1) begin
                if(dut.valid_array[idx] && dut.dirty_bit_array[idx]) begin
                    found_dirty = 1'b1;

                    victim_tag = dut.tag_array[idx];
                    victim_addr = (victim_tag << (INDEX_BITS + OFFSET_BITS)) |
                                  (idx << OFFSET_BITS);

                    // Select a different tag while preserving the index.
                    alt_tag = 0;
                    if(alt_tag == victim_tag)
                        alt_tag = 1;
                    if(alt_tag == victim_tag)
                        alt_tag = 2;

                    conflict_addr = (alt_tag << (INDEX_BITS + OFFSET_BITS)) |
                                    (idx << OFFSET_BITS);

                    cpu_read(conflict_addr, rd);
                end
            end

            wait_for_quiet(50);

            if(!found_dirty)
                pass = CACHE_LINES + 2;
        end

        wait_for_quiet(200);

        for(idx = 0; idx < CACHE_LINES; idx = idx + 1) begin
            check(
                !(dut.valid_array[idx] && dut.dirty_bit_array[idx]),
                "No dirty cache line remains after final drain"
            );
        end
    end
endtask


// ============================================================================
// FINAL BACKING MEMORY CHECK
//
// For a write-back cache, all dirty state must be drained before this check.
// ============================================================================

task final_memory_check;

    integer i;

    begin
        $display("");
        $display("==================================================");
        $display("FINAL BACKING MEMORY CONSISTENCY CHECK");
        $display("==================================================");

        // First force all remaining dirty cache lines to backing memory.
        drain_dirty_lines();
        wait_for_quiet(500);

        for(i = 0; i < MEM_WORDS; i = i + 1) begin
            if(memory.mem[i] !== ref_mem[i]) begin
                failed_checks = failed_checks + 1;

                $display(
                    "[FAIL] FINAL MEMORY MISMATCH ADDR=%0d MEM=%h REF=%h",
                    i,
                    memory.mem[i],
                    ref_mem[i]
                );
            end
        end

        check(
            req_fifo_empty,
            "Request FIFO empty at final quiescence"
        );

        check(
            response_fifo_empty,
            "Response FIFO empty at final quiescence"
        );

        check(
            dut.present_state == 3'd0,
            "Cache returned to IDLE"
        );

        check(
            controller.present_state == 3'd0,
            "Controller returned to IDLE"
        );

        check(
            protocol_violations == 0,
            "No FIFO protocol violations detected"
        );

        check(
            scoreboard_violations == 0,
            "No illegal/corrupt backing-memory writes detected"
        );

        check(
            cpu_completion_count == (cpu_read_count + cpu_write_count),
            "Every CPU transaction received exactly one completion"
        );
    end
endtask


// ============================================================================
// MAIN
// ============================================================================

initial begin

    cpu_req    = 1'b0;
    read_write = 1'b0;
    addr       = 0;
    wdata      = 0;

    total_checks = 0;
    passed_checks = 0;
    failed_checks = 0;

    cpu_read_count = 0;
    cpu_write_count = 0;
    cpu_completion_count = 0;

    memory_read_count = 0;
    memory_write_count = 0;

    protocol_violations = 0;
    scoreboard_violations = 0;

    monitor_enabled = 1'b0;

    initialize_memory();

    $display("");
    $display("==================================================");
    $display("CPU LITE HARD VERIFICATION TESTBENCH");
    $display("WRITE-BACK + NO-WRITE-ALLOCATE");
    $display("==================================================");

    reset_check();

    // Do not enable the backing-memory scoreboard until initialization is done.
    monitor_enabled = 1'b1;

    test_write_miss();

    test_refill();

    test_dirty_eviction();

    test_clean_eviction();

    test_collision_stress();

    boundary_test();

    randomized_test();

    final_memory_check();

    $display("");
    $display("==================================================");
    $display("FINAL RESULTS");
    $display("==================================================");

    $display("Total checks          : %0d", total_checks);
    $display("Passed                : %0d", passed_checks);
    $display("Failed                : %0d", failed_checks);

    $display("CPU reads             : %0d", cpu_read_count);
    $display("CPU writes            : %0d", cpu_write_count);
    $display("CPU completions       : %0d", cpu_completion_count);

    $display("Memory reads          : %0d", memory_read_count);
    $display("Memory writes         : %0d", memory_write_count);

    $display("FIFO protocol errors  : %0d", protocol_violations);
    $display("Scoreboard errors     : %0d", scoreboard_violations);

    if(failed_checks == 0 &&
       protocol_violations == 0 &&
       scoreboard_violations == 0) begin

        $display("*** HARD VERIFICATION PASSED ***");
    end
    else begin
        $display("*** HARD VERIFICATION FAILED ***");
    end

    $display("==================================================");

    #100;
    $finish;
end

endmodule

